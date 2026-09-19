/**
 * Corpus sanitisation — offline, no network.
 *
 * `corpus/` is committed; `sidecar/fixtures/` is not. The corpus is derived
 * from the captures by `bun run export-contract-corpus`, and the captures are
 * one logged-in session's home feed: real video ids, real channel ids, chip
 * labels that are a taste profile, and continuation tokens that are base64
 * protobuf carrying session context. None of that may reach a public repo.
 *
 * The export path is the thing under test. A field added to a DTO without a
 * matching branch in the exporter ships real data silently, which is exactly
 * the failure this file exists to make loud.
 *
 * Two layers:
 *
 *   1. Closed world. Every string in `corpus/` must *match* the synthetic shape
 *      its field is supposed to have. An unknown field fails rather than
 *      passing by default — that is what catches a new DTO field nobody
 *      sanitised. Needs no captures, so it runs on a clean clone.
 *
 *   2. Cross-check against the captures, when they are present: no corpus value
 *      occurs verbatim in a capture, and no real id — nor any prefix of one —
 *      survives anywhere.
 *
 * Plus a negative control, because an auditor that cannot fail is worse than no
 * auditor: it converts an unchecked property into a checked-looking one.
 */

import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { logger } from '../src/log.ts';

/** stderr, like everything else — hard invariant 3 applies to the suite too. */
const log = logger('corpus-test');

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const CORPUS = join(ROOT, 'corpus');
const FIXTURES = join(ROOT, 'sidecar', 'fixtures');

// ---------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------

/**
 * Fields allowed to carry a value straight from the capture.
 *
 * Widening this set is a deliberate act and should show up in review as one.
 * Each entry needs a reason that survives the question "what does this tell an
 * attacker about whose account was captured?".
 *
 * - `viewCountText`  Public video metadata ("1.4M views"). Identical for every
 *                    viewer of that video; says nothing about the session. Kept
 *                    real because it is a display string the contract requires
 *                    be passed through unparsed, and a synthetic one would stop
 *                    exercising that rule.
 * - `publishedText`  Same: public, relative, viewer-independent ("4 years ago").
 * - `badges`         A closed vocabulary from YouTube ("4K", "Members only"),
 *                    not free text and not user-derived. The parser maps these
 *                    to a fixed set, so pinning the real strings is the point.
 * - `commentCount`   Same reasoning as `viewCountText`: a public, per-video
 *                    display string ("86,800 Comments"), identical for every
 *                    viewer, carrying nothing about the captured session.
 *
 * Deliberately NOT here: titles, channel names, mix subtitles, chip labels
 * (taste profile); ids and continuation tokens (identity and session context).
 */
const KEEP_REAL = new Set([
  'viewCountText',
  'publishedText',
  'publishedDateText',
  'badges',
  'weightLabel',
  'commentCount',
]);

/**
 * The shape each sanitised field must have, keyed by field name.
 *
 * A field absent from this map is a failure, not a pass — that is the whole
 * point of a closed world. When a DTO grows a field, this map and the exporter
 * change together or the suite goes red.
 */
const SANITISED_SHAPE: Record<string, RegExp> = {
  // Discriminator and contract vocabulary — not capture-derived.
  kind: /^(video|mix|playlist|channel)$/,
  scope: /^(feed|shelf)$/,
  // Task 25 §3 — a closed set the sidecar itself defines, not free text off
  // the watch page. Same treatment as `kind`/`scope` above.
  myRating: /^(like|dislike|none)$/,
  // PlaylistMembership (the save dialog): `privacy` is the sidecar's closed set,
  // and a `removeToken` names a real video and playlist, so it is a placeholder.
  privacy: /^(public|unlisted|private)$/,
  removeToken: /^REMOVE_TOKEN$/,

  // Ids are replaced outright, never truncated, and indexed to the item.
  // `WL` is Watch Later's fixed, public playlist id (the save dialog's row) — a
  // constant every account shares, so it identifies nobody. Every other id is
  // replaced.
  id: /^((vid|mix|list|chan|item|cmt)_\d{3,}|WL)$/,
  channelId: /^chan_\d{3,}$/,

  // Indexed so a mapper that gives every item the same value cannot pass.
  title: /^Sanitised Title \d+$/,
  channelName: /^Sanitised Channel \d+$/,
  name: /^Sanitised Channel \d+$/,
  subtitle: /^Sanitised Subtitle \d+$/,
  // Free text from an arbitrary uploader, same reasoning as `title`.
  descriptionSnippet: /^Sanitised Snippet \d+$/,
  thumbnailUrl: /^https:\/\/fake\.url\/img\d+\.jpg$/,
  avatarUrl: /^https:\/\/fake\.url\/avatar\d+\.jpg$/,
  channelAvatarUrl: /^https:\/\/fake\.url\/avatar\d+\.jpg$/,
  // ArtistPanel (Task 21 §3) — its own `channelId`/`mixPlaylistId` reuse
  // `chan_`/`mix_` id shapes; `handle` and `videoCountText` are new.
  handle: /^@sanitised_handle_\d+$/,
  // Task 23. The panel's `backgroundColor`/`baseBackgroundColor` are not here
  // and do not need to be: they are numbers, which this auditor does not walk,
  // and they are YouTube's own palette for a public channel — they identify
  // nobody, and replacing them would cost the corpus the only field a colour
  // regression could ever be caught by. The exporter says the same at the
  // point it lets them through.
  backdropUrl: /^https:\/\/fake\.url\/backdrop\d+\.jpg$/,
  videoCountText: /^Sanitised Videos \d+$/,
  mixPlaylistId: /^mix_\d{3,}$/,
  // MixItem's start target (2026-09-14) — the exporter replaces both.
  seedVideoId: /^vid_\d{3,}$/,
  startParams: /^START_PARAMS$/,

  // "All" survives verbatim: the app keys its unfiltered state off that label,
  // and an empty token is the contract's "no filter" rather than session data.
  label: /^(All|Category \d+)$/,
  token: /^(|CHIP_TOKEN_(ALL|\d+))$/,
  continuation: /^CONTINUATION_TOKEN_\d+$/,
  // Task 27's own continuation, sanitised the same way but never added here —
  // exactly the export/test-in-different-files gap CLAUDE.md already warns
  // about, caught the same way: running the exporter, not `bun run check`.
  repliesContinuation: /^CONTINUATION_TOKEN_\d+$/,

  // Channel subscriber counts are public, but no channel tile has reached the
  // corpus yet; require a synthetic value rather than guessing a policy.
  subscriberText: /^Sanitised Subscribers \d+$/,

  // VideoDetail. A description is free text from an arbitrary uploader and a
  // like count is public, but both are replaced rather than kept: the corpus is
  // a shape reference, and neither adds a shape a synthetic value would not.
  description: /^Sanitised Description \d+$/,
  likeText: /^Sanitised Likes \d+$/,
  relatedContinuation: /^CONTINUATION_TOKEN_\d+$/,
  commentsContinuation: /^CONTINUATION_TOKEN_\d+$/,

  // Comment (Task 27)
  authorName: /^Sanitised Author \d+$/,
  authorAvatarUrl: /^https:\/\/fake\.url\/avatar\d+\.jpg$/,
  authorChannelId: /^chan_\d{3,}$/,
  content: /^Sanitised Comment Text \d+$/,
  likeCount: /^Sanitised Likes \d+$/,
  url: /^https:\/\/fake\.url$/,
  videoId: /^vid_\d{3,}$/,
  // Reply/delete tokens (2026-09-18) — opaque, server-issued, same treatment
  // as `startParams`.
  replyParams: /^REPLY_PARAMS$/,
  deleteParams: /^DELETE_PARAMS$/,
  // The comment box's own submit token. Real ones encode the video id in
  // base64, which layer 1's forbidden-shape list would flag on its own.
  createParams: /^CREATE_PARAMS$/,

  // Caption tracks. `languageCode` is a BCP-47-ish tag from a closed-ish
  // vocabulary and identifies nobody, so it survives verbatim — but it is
  // pinned to a tag shape rather than exempted, because "en" passing and an
  // arbitrary string passing are different properties.
  languageCode: /^[a-zA-Z]{2,3}(-[A-Za-z0-9]{2,8})*$/,
};

/** Shapes that must never occur in the corpus, whatever field they sit in. */
const FORBIDDEN_SHAPES: { name: string; test: (value: string) => boolean }[] = [
  { name: 'video-id shape', test: (v) => /^[A-Za-z0-9_-]{11}$/.test(v) },
  { name: 'channel-id shape', test: (v) => /^UC[A-Za-z0-9_-]{20,}$/.test(v) },
  { name: 'playlist-id shape', test: (v) => /^(RD|PL|UU|LL|OLAK)[A-Za-z0-9_-]{10,}$/.test(v) },
  { name: 'base64 blob', test: (v) => v.length > 40 && /^[A-Za-z0-9+/=_%-]+$/.test(v) },
];

// ---------------------------------------------------------------------------
// Auditors — pure, so the negative control can drive them with poisoned input
// ---------------------------------------------------------------------------

type Doc = { name: string; value: unknown };

function walkStrings(node: unknown, path: string, field: string | null, visit: (value: string, path: string, field: string | null) => void): void {
  if (typeof node === 'string') return visit(node, path, field);
  if (Array.isArray(node)) {
    node.forEach((entry, i) => walkStrings(entry, `${path}[${i}]`, field, visit));
    return;
  }
  if (node && typeof node === 'object') {
    for (const [key, entry] of Object.entries(node)) walkStrings(entry, `${path}.${key}`, key, visit);
  }
}

/** Layer 1: every string matches the synthetic shape its field must have. */
export function auditShapes(docs: Doc[]): string[] {
  const findings: string[] = [];
  for (const doc of docs) {
    walkStrings(doc.value, doc.name, null, (value, path, field) => {
      if (field !== null && KEEP_REAL.has(field)) return;
      for (const forbidden of FORBIDDEN_SHAPES) {
        if (forbidden.test(value)) findings.push(`${path}: ${forbidden.name} — ${JSON.stringify(value.slice(0, 60))}`);
      }
      if (field === null) return;
      const shape = SANITISED_SHAPE[field];
      if (!shape) {
        findings.push(`${path}: field "${field}" has no sanitised shape — add one to SANITISED_SHAPE or KEEP_REAL`);
        return;
      }
      if (!shape.test(value)) findings.push(`${path}: ${JSON.stringify(value.slice(0, 60))} does not match ${shape}`);
    });
  }
  return findings;
}

/**
 * Values that necessarily occur in a capture and carry nothing when they do.
 *
 * `kind` and `scope` are the contract's own vocabulary, and the exporter keeps
 * the "All" label and the empty token verbatim on purpose. "playlist" appears
 * in every user's response, so co-occurrence proves nothing about whose session
 * was captured. Layer 1 still pins each of these to a closed set of literals,
 * so exempting them here opens no hole.
 */
function isContractVocabulary(value: string, field: string | null): boolean {
  if (field === 'kind' || field === 'scope') return true;
  if (field === 'label' && value === 'All') return true;
  if (field === 'token' && value === '') return true;
  return false;
}

export interface CaptureIndex {
  /** Every string value appearing anywhere in the captures. */
  values: Set<string>;
  /** Every prefix, 5 chars and longer, of every real id in the captures. */
  idPrefixes: Set<string>;
}

/** Layer 2: nothing in the corpus is traceable to a capture. */
export function auditAgainstCaptures(docs: Doc[], capture: CaptureIndex): string[] {
  const findings: string[] = [];
  for (const doc of docs) {
    walkStrings(doc.value, doc.name, null, (value, path, field) => {
      if (field !== null && KEEP_REAL.has(field)) return;
      if (isContractVocabulary(value, field)) return;
      if (value.length >= 3 && capture.values.has(value)) {
        findings.push(`${path}: ${JSON.stringify(value.slice(0, 60))} occurs verbatim in a capture`);
      }
      // Split on anything an id cannot contain, so an id embedded in a URL is
      // still seen as its own token.
      for (const token of value.split(/[^A-Za-z0-9_-]+/)) {
        if (token.length >= 5 && capture.idPrefixes.has(token)) {
          findings.push(`${path}: ${JSON.stringify(token)} is a real id, or a prefix of one`);
        }
      }
    });
  }
  return findings;
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

function loadCorpus(): Doc[] {
  if (!existsSync(CORPUS)) return [];
  return readdirSync(CORPUS)
    .filter((file) => file.endsWith('.json'))
    .map((file) => ({ name: file, value: JSON.parse(readFileSync(join(CORPUS, file), 'utf8')) }));
}

const ID_KEYS = /^(videoId|channelId|playlistId|browseId|content_id|external_id)$/i;
const MIN_PREFIX = 5;

function loadCaptureIndex(): CaptureIndex {
  const values = new Set<string>();
  const ids = new Set<string>();

  const collect = (node: unknown): void => {
    if (typeof node === 'string') {
      values.add(node);
      if (/^UC[A-Za-z0-9_-]{22}$/.test(node)) ids.add(node);
      return;
    }
    if (Array.isArray(node)) return node.forEach(collect);
    if (node && typeof node === 'object') {
      for (const [key, entry] of Object.entries(node)) {
        if (typeof entry === 'string' && ID_KEYS.test(key)) ids.add(entry);
        collect(entry);
      }
    }
  };

  // `viewer-state/` holds real comment text, playlist titles and ids too — a
  // capture family of its own that the top-level listing never reaches.
  for (const dir of [FIXTURES, join(FIXTURES, 'viewer-state')]) {
    if (!existsSync(dir)) continue;
    for (const file of readdirSync(dir).filter((f) => f.endsWith('.json'))) {
      collect(JSON.parse(readFileSync(join(dir, file), 'utf8')));
    }
  }

  const idPrefixes = new Set<string>();
  for (const id of ids) {
    for (let length = id.length; length >= MIN_PREFIX; length--) idPrefixes.add(id.slice(0, length));
  }
  return { values, idPrefixes };
}

const corpus = loadCorpus();
const hasFixtures = existsSync(FIXTURES) && readdirSync(FIXTURES).some((f) => f.endsWith('.json'));

if (!hasFixtures) {
  // Skipping is correct here: fixtures are gitignored, so a clean clone has no
  // captures to compare against. Failing would make every fresh checkout red.
  log.warn(
    '[corpus] sidecar/fixtures/ is absent — skipping the capture cross-check. ' +
      'Shape checks still run. Run `bun run capture` (needs YT_COOKIE) to enable it.',
  );
}

// ---------------------------------------------------------------------------

describe('corpus sanitisation', () => {
  test('the corpus is present and non-trivial', () => {
    expect(corpus.length).toBeGreaterThan(0);
    const items = corpus.reduce((n, d) => n + ((d.value as { items?: unknown[] }).items?.length ?? 0), 0);
    expect(items).toBeGreaterThan(100);
  });

  test('every string matches the sanitised shape its field must have', () => {
    expect(auditShapes(corpus)).toEqual([]);
  });

  test.skipIf(!hasFixtures)('no corpus value is traceable to a capture', () => {
    expect(auditAgainstCaptures(corpus, loadCaptureIndex())).toEqual([]);
  });

  // An auditor that cannot fail is worse than no auditor. Each planted value is
  // a leak that actually shipped, or nearly did: a real title, a full id, the
  // truncated id the exporter used to emit, an id hidden inside a URL, and a
  // slice of a session token.
  describe('negative control — the auditor detects planted leaks', () => {
    const poisoned = (item: Record<string, unknown>, extra: Record<string, unknown> = {}): Doc[] => [
      { name: 'poisoned.json', value: { chips: [], items: [{ kind: 'video', ...item }], continuation: null, ...extra } },
    ];

    test('a real title is caught', () => {
      const capture: CaptureIndex = { values: new Set(['Got it. We will tune your recommendations.']), idPrefixes: new Set() };
      const docs = poisoned({ id: 'vid_001', title: 'Got it. We will tune your recommendations.' });
      expect(auditShapes(docs).length).toBeGreaterThan(0);
      expect(auditAgainstCaptures(docs, capture).length).toBeGreaterThan(0);
    });

    test('a full video id is caught', () => {
      const docs = poisoned({ id: 'LpNC5hpN_lg', title: 'Sanitised Title 1' });
      expect(auditShapes(docs).join()).toContain('video-id shape');
    });

    test('a truncated id is caught — the scheme this exporter used to use', () => {
      const capture: CaptureIndex = { values: new Set(), idPrefixes: new Set(['UC7_YxT-K', 'UC7_YxT-KID8kRbqZo7MyscQ']) };
      const docs = poisoned({ id: 'vid_001', title: 'Sanitised Title 1', channelId: 'UC7_YxT-K' });
      expect(auditShapes(docs).length).toBeGreaterThan(0);
      expect(auditAgainstCaptures(docs, capture).join()).toContain('prefix of one');
    });

    test('an id hidden inside a URL is caught', () => {
      const capture: CaptureIndex = { values: new Set(), idPrefixes: new Set(['LpNC5hpN_lg']) };
      const docs = poisoned({ id: 'vid_001', title: 'Sanitised Title 1', thumbnailUrl: 'https://i.ytimg.com/vi/LpNC5hpN_lg/hq.jpg' });
      expect(auditAgainstCaptures(docs, capture).join()).toContain('LpNC5hpN_lg');
    });

    test('a session token is caught', () => {
      const docs = poisoned({ id: 'vid_001', title: 'Sanitised Title 1' }, { continuation: 'cgDaAt6VAaIB2ZUBcicKJSAZKAIwBjgEShMI9Nal6Pn_lQMVSZiDBx39wSY3UgIIBGgBcCm6AZiVAQrBKHKYKDJAmgER' });
      expect(auditShapes(docs).join()).toContain('base64 blob');
    });

    test('an unsanitised new field is caught even though nothing matches it', () => {
      // `descriptionSnippet` used to be this test's example — it was itself an
      // unsanitised field until Task 21's re-export caught it for real (see
      // `export-contract-corpus.ts`). Now that it has a shape, this needs a
      // field name that will never be a real one, so the control keeps testing
      // "a brand-new field is caught" rather than quietly re-testing the fixed bug.
      const docs = poisoned({ id: 'vid_001', title: 'Sanitised Title 1', someUnsanitisedField: 'anything at all' });
      expect(auditShapes(docs).join()).toContain('no sanitised shape');
    });

    test('the control does not fire on the real corpus', () => {
      expect(auditShapes(corpus)).toEqual([]);
    });
  });

  // A privacy check that silently does not look is worse than none. `viewer-state/`
  // is a capture family of its own — real comment text, real playlist titles, the
  // account's real ids — and the top-level listing that used to build the index
  // never reached it, so nothing in it could have been caught.
  //
  // It asserts on values that exist *only* there. The capture's video and channel id
  // do not qualify: the standard capture uses the same video, so they are in the
  // top-level fixtures too, and a first version of this test built on them passed with
  // the fix reverted.
  const viewerStateManifest = (() => {
    try {
      return JSON.parse(readFileSync(join(FIXTURES, 'viewer-state', 'manifest.json'), 'utf8')) as {
        commentVideo: string | null;
        commentId: string | null;
      };
    } catch {
      return null;
    }
  })();
  test.skipIf(!viewerStateManifest?.commentId || !viewerStateManifest.commentVideo)(
    'the traceability index reaches fixtures/viewer-state/',
    () => {
      const index = loadCaptureIndex();
      expect(index.values.has(viewerStateManifest!.commentId!)).toBe(true);
      expect(index.values.has(viewerStateManifest!.commentVideo!)).toBe(true);
    },
  );
});

// The sanitiser replaces every comment's text and count, so nothing above says
// anything about the two booleans that ride through untouched. They were both
// wrong for weeks with an all-green corpus: `creatorHearted` true for every
// comment ever exported, `isLiked` for none, because no fixture had a liked
// comment in it to disagree. `comments-viewer-state.json` is that comment.
describe('comment corpus — viewer state', () => {
  type CommentDoc = { items: { isLiked: boolean; creatorHearted: boolean }[] };
  const pages = corpus.filter((d) => d.name.startsWith('comments')).map((d) => d.value as CommentDoc);
  const all = pages.flatMap((p) => p.items);

  test('the comment corpus can see a liked comment and a hearted one', () => {
    expect(all.some((c) => c.isLiked)).toBe(true);
    expect(all.some((c) => c.creatorHearted)).toBe(true);
  });

  test('a creator heart is not universal — no page of comments is hearted throughout', () => {
    // The old reading marked every comment on every page. A creator hearting
    // *every* comment on a page of 20 is not a thing a person does.
    for (const page of pages.filter((p) => p.items.length > 3)) {
      expect(page.items.every((c) => c.creatorHearted)).toBe(false);
    }
  });
});

// ---------------------------------------------------------------------------
// The viewer-state pair: states asserted, not just shapes
// ---------------------------------------------------------------------------
//
// Everything above tests *shape*. The account state a field reports is the one
// thing a shape test cannot see, and it is where `creatorHearted`, `isLiked` and
// `containsVideo` were all wrong at once with an all-green suite. These files
// were captured with the account put in a known state and the state *proven from
// the raw response* first (`capture-viewer-state.ts`), so what they must parse to
// is not in question. They are committed sanitised, so this runs on any checkout.
describe('viewer-state corpus — the account states the parsers must report', () => {
  const doc = <T>(name: string): T => {
    const found = corpus.find((d) => d.name === `viewer-state-${name}.json`);
    if (!found) throw new Error(`corpus/viewer-state-${name}.json is missing — run capture:viewer-state, then export-contract-corpus`);
    return found.value as T;
  };

  describe('the watch page: myRating and isSubscribed', () => {
    type Detail = { myRating: string; isSubscribed: boolean };
    test('before — unrated, channel not subscribed', () => {
      expect(doc<Detail>('video-detail-before')).toMatchObject({ myRating: 'none', isSubscribed: false });
    });
    test('after — liked, channel subscribed', () => {
      expect(doc<Detail>('video-detail-after')).toMatchObject({ myRating: 'like', isSubscribed: true });
    });
    test('a video the account disliked reads as dislike — the third value', () => {
      expect(doc<Detail>('video-detail-disliked').myRating).toBe('dislike');
    });
  });

  describe('the save dialog: containsVideo and removeToken', () => {
    type Row = { id: string; containsVideo: boolean; removeToken: string | null };
    const rows = (name: string): Row[] => doc<{ playlists: Row[] }>(name).playlists;

    test('before — no playlist holds the video, and there is nothing to remove', () => {
      expect(rows('membership-before').length).toBeGreaterThan(1);
      expect(rows('membership-before').some((r) => r.containsVideo)).toBe(false);
      expect(rows('membership-before').some((r) => r.removeToken !== null)).toBe(false);
    });

    test('after — exactly Watch Later holds it, and only that row can be removed from', () => {
      const after = rows('membership-after');
      expect(after.filter((r) => r.containsVideo).map((r) => r.id)).toEqual(['WL']);
      expect(after.filter((r) => r.removeToken !== null).map((r) => r.id)).toEqual(['WL']);
    });
  });

  describe("comments: the viewer's like and the creator's heart", () => {
    type C = { isLiked: boolean; creatorHearted: boolean; deleteParams: string | null };
    const page = (name: string): C[] => doc<{ items: C[] }>(name).items;
    const count = (items: C[], f: (c: C) => boolean) => items.filter(f).length;

    // The capture is the creator's own video and the account's own comment on it.
    // The comments by other people were liked and hearted by the creator already
    // and stay that way; the pair differs in exactly the own comment.
    test('the creator sees every comment liked and hearted except the own one, before', () => {
      const before = page('comments-before');
      expect(before.length).toBeGreaterThan(1);
      const own = before.filter((c) => c.deleteParams !== null);
      expect(own).toHaveLength(1);
      expect([own[0]!.isLiked, own[0]!.creatorHearted]).toEqual([false, false]);
      expect(count(before, (c) => c.isLiked)).toBe(before.length - 1);
      expect(count(before, (c) => c.creatorHearted)).toBe(before.length - 1);
    });

    test('after, the own comment is liked and hearted and nothing else moved', () => {
      const before = page('comments-before');
      const after = page('comments-after');
      expect(after).toHaveLength(before.length);
      expect(count(after, (c) => c.isLiked)).toBe(after.length);
      expect(count(after, (c) => c.creatorHearted)).toBe(after.length);
      const changed = after.filter((c, i) => c.isLiked !== before[i]!.isLiked || c.creatorHearted !== before[i]!.creatorHearted);
      expect(changed).toHaveLength(1);
      expect(changed[0]!.deleteParams).not.toBeNull();
    });

    test("anyone else sees the hearts and none of the creator's likes", () => {
      // The same comments as an anonymous viewer: the heart is public, the like is
      // the *viewer's* — so every comment reads hearted and none reads liked.
      const anonymous = page('comments-after-anonymous');
      expect(anonymous.length).toBeGreaterThan(1);
      expect(count(anonymous, (c) => c.creatorHearted)).toBe(anonymous.length);
      expect(count(anonymous, (c) => c.isLiked)).toBe(0);
      expect(count(anonymous, (c) => c.deleteParams !== null)).toBe(0);
    });
  });
});
