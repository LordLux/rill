import { createInterface } from 'node:readline';

const version = parseInt(process.argv[2] || '1', 10);
// 'empty-home': the base browse returns no items and auth.verify answers
// slowly. That is the one shape in which a response the client did NOT cancel
// can land after a newer request — auth.verify is issued with a plain call —
// so it is the only way to exercise the controller's generation guard on its
// own, rather than behind $cancel.
// 'base-fail-auto': the *base* browse itself fails with retry:"auto", which is
// the shape that exposed an unbounded retry — a scheduled retry re-entering
// loadHome as a base load refilled the very budget it was spending. The reply
// counts attempts so a test can assert the budget is finite.
// 'paging-user' / 'paging-auto': the base browse hands back a continuation that
// is rigged to fail, so a test can reach the *second* page's error path. Without
// a continuation the controller's `loadMore` never issues anything at all.
const mode = process.argv[3] || '';
const pagingContinuation = mode === 'paging-user'
  ? 'PAGE2!fail=user'
  : mode === 'paging-auto'
    ? 'PAGE2!fail=auto'
    : null;
process.stdout.write(JSON.stringify({
  method: 'event.ready',
  params: { protocolVersion: version, capabilities: {} }
}) + '\n');

const rl = createInterface({ input: process.stdin });
let baseAttempts = 0;
const pending = new Map();

// Playback, recorded rather than answered blindly: `test.playbackLog` hands the
// whole conversation back so a test can assert on the cadence of reports and on
// preloads it has no other way to observe.
/** The one video id that is a premiere. 2026-08-22T15:00:00Z. */
const PREMIERE_ID = 'premiere1';
const PREMIERE_AT_MS = 1787670000_000;
/**
 * The one video id that always fails to resolve.
 *
 * Keyed on the id rather than on a launch mode so a single sidecar can serve a
 * whole test file — a test needing both a premiere and a genuine failure would
 * otherwise restart the process mid-file, which is the race that made
 * `player_controls_test.dart` flaky.
 */
const BROKEN_ID = 'broken1';

/**
 * Members-only, in the two shapes the app has to survive.
 *
 * `members1` is the ordinary one: the sidecar recognised the refusal and
 * answered `VIDEO_MEMBERS_ONLY`.
 *
 * `memberslocale1` is the case the structural fallback exists for — the
 * sidecar classifies from YouTube's localised prose, so on a locale its
 * pattern misses it answers a plain `STREAM_UNAVAILABLE` instead. The watch
 * page must still show the members slate, because `video.info` says so from a
 * badge style YouTube does not translate.
 */
/**
 * An open that YouTube's throttle refused — `RATE_LIMITED`, `retry: "user"`
 * (decided 2026-09-17). The watch page has to say the connection is limited,
 * not that the video would not open.
 */
const RATE_LIMITED_ID = 'ratelimited1';
const MEMBERS_ID = 'members1';
const MEMBERS_LOCALE_ID = 'memberslocale1';
/** Members-only, and nothing anywhere knows the channel's name. */
const MEMBERS_NO_CHANNEL_ID = 'membersnochan1';

/** No caption tracks at all — the CC control must not be drawn. */
const NO_CAPTIONS_ID = 'nocaps1';
/** `captions.list` fails. A caption failure must not touch playback. */
const CAPTIONS_FAIL_ID = 'capsfail1';

/**
 * Task 25. The one video id every action (`action.like`/`dislike`/
 * `removeRating`/`addToWatchLater`/`removeFromPlaylist`) refuses for —
 * `watch_actions_test.dart`'s only way to reach the optimistic-revert path
 * from outside the widget.
 */
const ACTION_FAIL_ID = 'actionfail1';

/** Per-video like/dislike state, mutable so a rating round-trips into the
 *  next `video.info` — 'LIKE' | 'DISLIKE' | 'INDIFFERENT', matching the real
 *  sidecar's `likeStatus` vocabulary (`sidecar/src/parser/video.ts`). */
const ratings: Record<string, string> = {};

/** Per-video Watch Later membership, for `playlist.forVideo`. */
const watchLaterMembership = new Set<string>();

/**
 * An ordinary (non-Watch-Later) playlist, so `playlist.forVideo` has more
 * than one row to test rendering against — `save_dialog_test.dart`'s "renders
 * existing membership correctly".
 */
const TEST_PLAYLIST_ID = 'PL_TEST';
const testPlaylistMembership = new Set<string>();

const captionLists: unknown[] = [];
const captionGets: unknown[] = [];
const searchCalls: unknown[] = [];
const suggestCalls: unknown[] = [];

/**
 * The auth state this fake is in — Task 22.
 *
 * Starts `authenticated` so every pre-existing test sees exactly the behaviour
 * it saw before this existed; `auth.setCookie` and `auth.signOut` move it, and
 * `auth.verify`/`auth.status` report it. That is the whole state machine, and
 * it is here rather than per test because the property under test is a
 * *sequence* — sign in, restart, sign out — which needs one process that
 * remembers.
 */
let authState: 'authenticated' | 'degraded' | 'anonymous' = 'authenticated';
const authCookies: string[] = [];
let signOuts = 0;

const opens: Array<{ videoId?: string; preload: boolean }> = [];
const reports: unknown[] = [];
const closes: unknown[] = [];
let sessions = 0;
let realOpens = 0;

const parentPid = process.env.FLUTTER_PARENT_PID;
if (parentPid) {
  setInterval(() => {
    try {
      process.kill(parseInt(parentPid, 10), 0);
    } catch (e) {
      process.stderr.write(`fake_sidecar: process.kill failed: ${e}\n`);
      process.exit(0);
    }
  }, 3000).unref();
}

process.stdin.on('end', () => {
  process.stderr.write('fake_sidecar: stdin end\n');
  process.exit(0);
});
process.stdin.on('error', (e) => {
  process.stderr.write(`fake_sidecar: stdin error ${e}\n`);
  process.exit(0);
});

rl.on('close', () => {
  process.exit(0);
});

rl.on('line', (line) => {
  if (!line.trim()) return;
  try {
    const req = JSON.parse(line);
    
    if (req.method === '$cancel') {
      const id = req.params.id;
      if (pending.has(id)) {
        clearTimeout(pending.get(id));
        pending.delete(id);
      }
    } else if (req.method === 'test.echo') {
      const delay = req.params.delay || 0;
      const timer = setTimeout(() => {
        pending.delete(req.id);
        process.stdout.write(JSON.stringify({ id: req.id, result: req.params.msg }) + '\n');
      }, delay);
      pending.set(req.id, timer);
    } else if (req.method === 'test.error') {
      process.stdout.write(JSON.stringify({
        id: req.id,
        error: { code: 'TEST_ERROR', message: 'test error', retry: 'auto' }
      }) + '\n');
    } else if (req.method === 'auth.verify') {
      const replyAuth = () => process.stdout.write(JSON.stringify({
        id: req.id,
        result: mode === 'empty-home'
          ? { state: 'anonymous', tileCount: 0 }
          : authState === 'authenticated'
            ? { state: 'authenticated', tileCount: 10 }
            : { state: authState, tileCount: 0 },
      }) + '\n');
      // Deliberately not registered in `pending`: the client issues auth.verify
      // with a plain call and never cancels it, which is exactly the point.
      if (mode === 'empty-home') setTimeout(replyAuth, 400); else replyAuth();
    } else if (req.method === 'auth.setCookie') {
      // Task 22. The cookie *value* decides the answer, so a test can reach all
      // three states without a network: one that contains `degraded` is a stale
      // session, one with no `SAPISID` is refused, anything else works.
      //
      // The value is recorded so a test can assert the app persisted and
      // restored the same header. It is a fake in a test file and never a real
      // session — nothing here is a pattern for the app.
      const cookie = String(req.params?.cookie ?? '');
      authCookies.push(cookie);
      authState = cookie.includes('degraded')
        ? 'degraded'
        : cookie.includes('SAPISID=') ? 'authenticated' : 'anonymous';
      process.stdout.write(JSON.stringify({ id: req.id, result: { state: authState } }) + '\n');
    } else if (req.method === 'auth.signOut') {
      authState = 'anonymous';
      signOuts += 1;
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'auth.status') {
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: authState === 'authenticated'
          ? {
              state: 'authenticated',
              accountName: 'Ada Lovelace',
              accountHandle: '@ada',
              accountAvatarUrl: 'https://yt3.ggpht.com/ada',
            }
          : {
              state: authState,
              accountName: null,
              accountHandle: null,
              accountAvatarUrl: null,
            },
      }) + '\n');
    } else if (req.method === 'test.authLog') {
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: { state: authState, cookies: authCookies, signOuts },
      }) + '\n');
    } else if (req.method === 'playback.open') {
      // 'open-fails-once': the first real open answers STREAM_UNAVAILABLE with
      // retry:"user" — the §4 shape the watch page has to offer a retry out of.
      // The ladder's floor is a very good bet and not a promise (F9), so this is
      // a state a user can retry out of, and the retry has to actually work.
      opens.push({ videoId: req.params?.videoId, preload: req.params?.preload === true });
      const isPreload = req.params?.preload === true;
      if (req.params?.videoId === BROKEN_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'STREAM_UNAVAILABLE', message: 'every resolution tier declined', retry: 'user' },
        }) + '\n');
        return;
      }
      // A premiere, keyed on the video id rather than a mode so one test can
      // hold both an ordinary video and an upcoming one — which is what the feed
      // does, and what the watch page has to switch between.
      if (req.params?.videoId === PREMIERE_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'VIDEO_UPCOMING', message: 'Premieres in 9 days', retry: 'no' },
        }) + '\n');
        return;
      }
      if (req.params?.videoId === RATE_LIMITED_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: {
            code: 'RATE_LIMITED',
            message: 'ratelimited1: YouTube is throttling this connection',
            retry: 'user',
          },
        }) + '\n');
        return;
      }
      if (req.params?.videoId === MEMBERS_ID || req.params?.videoId === MEMBERS_NO_CHANNEL_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: {
            code: 'VIDEO_MEMBERS_ONLY',
            message: 'Join this channel to get access to members-only content like this video.',
            retry: 'no',
          },
        }) + '\n');
        return;
      }
      if (req.params?.videoId === MEMBERS_LOCALE_ID) {
        // The locale the sidecar's prose pattern misses: it could not classify
        // the refusal, so the ladder exhausted and this is an ordinary failure
        // as far as the error code goes. `video.info` still knows.
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: {
            code: 'STREAM_UNAVAILABLE',
            message: 'every resolution tier declined',
            retry: 'user',
          },
        }) + '\n');
        return;
      }
      if (mode === 'open-fails-once' && !isPreload && realOpens++ === 0) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'STREAM_UNAVAILABLE', message: 'every resolution tier declined', retry: 'user' },
        }) + '\n');
        return;
      }
      // A preload "resolves and caches without opening a session" (§3.6), so it
      // does not mint one here either.
      const sessionId = isPreload ? 'preload' : `session_${++sessions}`;
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: {
          sessionId,
          durationMs: 600000,
          storyboardTemplate: null,
          qualityDegraded: false,
          transport: 'plain',
          // A real ladder, ranked best-first. One rung was enough while nothing
          // consumed `variants[]`; the quality picker is what made the shape of
          // the list matter, and "the client may switch without reopening"
          // (§3.5) is not testable against a list of one.
          variants: [
            [2160, 60, 315],
            [1080, 60, 299],
            [720, 30, 136],
            [360, 30, 134],
          ].map(([height, fps, itag]) => ({
            videoUrl: `https://fake.invalid/${req.params?.videoId}/video/${height}`,
            audioUrl: `https://fake.invalid/${req.params?.videoId}/audio`,
            itag,
            height,
            fps,
            videoCodec: 'vp9',
            audioCodec: 'opus',
          })),
        },
      }) + '\n');
    } else if (req.method === 'playback.report') {
      reports.push(req.params);
      // 'report-fails': every report is refused. Reporting is load-bearing, so
      // the app has to be able to say it has stopped working rather than going
      // quiet — this is the only way to stage that from outside.
      if (mode === 'report-fails') {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'UPSTREAM_ERROR', message: 'watchtime ping answered HTTP 403', retry: 'auto' },
        }) + '\n');
        return;
      }
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'playback.close') {
      closes.push(req.params?.sessionId);
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'video.info') {
      const videoId = req.params?.videoId;
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: {
          id: videoId,
          title: `Detail for ${videoId}`,
          description: 'A description long enough to collapse.',
          channelName: videoId === MEMBERS_NO_CHANNEL_ID ? '' : 'Fake Channel',
          channelId: 'chan_001',
          channelAvatarUrl: null,
          subscriberText: '1.2M subscribers',
          durationSeconds: 600,
          isLive: false,
          viewCountText: '31,000,000 views',
          publishedText: '16 years ago',
          publishedDateText: 'Dec 6, 2009',
          likeText: '1.1M',
          myRating: ratings[videoId] === 'LIKE' ? 'like' : ratings[videoId] === 'DISLIKE' ? 'dislike' : 'none',
          isSubscribed: false,
          badges: [],
          // Structural, from `BADGE_STYLE_TYPE_MEMBERS_ONLY` — true for both
          // members ids, including the one whose *error* the sidecar could not
          // classify.
          isMembersOnly: videoId === MEMBERS_ID || videoId === MEMBERS_LOCALE_ID,
          premiereAtMs: videoId === PREMIERE_ID ? PREMIERE_AT_MS : null,
          related: [],
          relatedContinuation: null,
        },
      }) + '\n');
    } else if (req.method === 'action.like' || req.method === 'action.dislike' || req.method === 'action.removeRating') {
      const videoId = req.params?.videoId;
      if (videoId === ACTION_FAIL_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'UPSTREAM_ERROR', message: 'rating refused', retry: 'auto' },
        }) + '\n');
        return;
      }
      ratings[videoId] = req.method === 'action.like'
        ? 'LIKE'
        : req.method === 'action.dislike'
          ? 'DISLIKE'
          : 'INDIFFERENT';
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'action.subscribe' || req.method === 'action.unsubscribe') {
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'action.addToWatchLater') {
      const videoId = req.params?.videoId;
      if (videoId === ACTION_FAIL_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'UPSTREAM_ERROR', message: 'watch later refused', retry: 'auto' },
        }) + '\n');
        return;
      }
      watchLaterMembership.add(videoId);
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'playlist.forVideo') {
      const videoId = req.params?.videoId;
      const inWatchLater = watchLaterMembership.has(videoId);
      const inTestPlaylist = testPlaylistMembership.has(videoId);
      // `_videoId`/`_playlistId` are not part of the real contract (the real
      // token is exactly `{playlistId, actions}` — `sidecar/src/actions/
      // playlist.ts`) — smuggled in here only so this fake's
      // `action.removeFromPlaylist` below can tell which video/playlist pair
      // to clear. (The real token does name the video — `removedVideoId`, measured
      // 2026-09-20 — but not the playlist row it came from, and a fake that reads a
      // field of its own is easier to reason about than one that reads the real one.)
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: {
          playlists: [
            {
              id: 'WL',
              title: 'Watch later',
              privacy: 'private',
              containsVideo: inWatchLater,
              removeToken: inWatchLater
                ? JSON.stringify({
                    playlistId: 'WL',
                    _videoId: videoId,
                    _playlistId: 'WL',
                    actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: videoId }],
                  })
                : null,
            },
            {
              id: TEST_PLAYLIST_ID,
              title: 'My Mix',
              privacy: 'public',
              containsVideo: inTestPlaylist,
              removeToken: inTestPlaylist
                ? JSON.stringify({
                    playlistId: TEST_PLAYLIST_ID,
                    _videoId: videoId,
                    _playlistId: TEST_PLAYLIST_ID,
                    actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: videoId }],
                  })
                : null,
            },
          ],
        },
      }) + '\n');
    } else if (req.method === 'action.addToPlaylist') {
      const videoId = req.params?.videoId;
      const playlistId = req.params?.playlistId;
      if (videoId === ACTION_FAIL_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'UPSTREAM_ERROR', message: 'add refused', retry: 'auto' },
        }) + '\n');
        return;
      }
      if (playlistId === 'WL') watchLaterMembership.add(videoId);
      else testPlaylistMembership.add(videoId);
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'action.removeFromPlaylist') {
      let videoId: string | undefined;
      let playlistId: string | undefined;
      try {
        const token = JSON.parse(req.params?.removeToken ?? '{}');
        videoId = token._videoId;
        playlistId = token._playlistId;
      } catch {
        // fall through — an unparseable token below is treated as "nothing to remove"
      }
      if (videoId === ACTION_FAIL_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'UPSTREAM_ERROR', message: 'removal refused', retry: 'auto' },
        }) + '\n');
        return;
      }
      if (videoId && playlistId === 'WL') watchLaterMembership.delete(videoId);
      else if (videoId) testPlaylistMembership.delete(videoId);
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'playlist.create') {
      process.stdout.write(JSON.stringify({ id: req.id, result: { playlistId: 'PL_NEW_FAKE' } }) + '\n');
    } else if (req.method === 'playlist.delete') {
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'captions.list') {
      // Three shapes, keyed on the video id so one sidecar serves a whole file:
      // NO_CAPTIONS_ID has none (the CC control must hide), CAPTIONS_FAIL_ID
      // errors, everything else has two tracks in two languages — which is the
      // minimum that makes "switch language" and "prefer the same language on
      // the next video" testable at all.
      // The id *and* whether `styled` was asked for, so a test can assert that
      // the video-open path does not pay for the badge and the menu does.
      captionLists.push(
        req.params?.includeStyled === true ? `${req.params?.videoId}+styled` : req.params?.videoId,
      );
      if (req.params?.videoId === NO_CAPTIONS_ID) {
        process.stdout.write(JSON.stringify({ id: req.id, result: { tracks: [] } }) + '\n');
        return;
      }
      if (req.params?.videoId === CAPTIONS_FAIL_ID) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: { code: 'UPSTREAM_ERROR', message: 'timedtext answered 500', retry: 'auto' },
        }) + '\n');
        return;
      }
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: {
          tracks: [
            // `styled` is null unless asked for, which is what the real sidecar
            // does: the answer needs a caption document, not a `/player`. The
            // three values are one per branch of the badge — karaoke, styled,
            // and plain, which earns none.
            { id: '.en', languageCode: 'en', label: 'English', isAutoGenerated: false, trackName: 'Commentary', styled: req.params?.includeStyled === true ? 'karaoke' : null, isTranslatable: true },
            { id: 'a.de', languageCode: 'de', label: 'German (auto-generated)', isAutoGenerated: true, trackName: '', styled: req.params?.includeStyled === true ? 'plain' : null, isTranslatable: true },
          ],
        },
      }) + '\n');
    } else if (req.method === 'captions.get') {
      // Task 19's optional parameters are recorded rather than acted on: what
      // the app *put on the wire* is the claim under test, and the sidecar's own
      // handling of them is asserted in `sidecar/test/captions.test.ts` against
      // the real renderer.
      //
      // `hasMetrics` is now permanently false and is kept for that reason — the
      // width table went out with the mpv pipeline, and a test that watches it
      // stay absent is what stops it drifting back onto the wire.
      captionGets.push({
        videoId: req.params?.videoId,
        trackId: req.params?.trackId,
        style: req.params?.style ?? null,
        offset: req.params?.offset ?? null,
        hasMetrics: req.params?.metrics !== undefined,
      });
      const trackId = req.params?.trackId;
      const language = trackId === 'a.de' ? 'de' : 'en';
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: {
          trackId,
          languageCode: language,
          format: 'ass',
          // Enough of a document that a test can assert *which* track landed on
          // the engine, not merely that something did.
          content: [
            '[Script Info]',
            'ScriptType: v4.00+',
            '',
            '[Events]',
            `Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,${trackId}`,
            '',
          ].join('\n'),
          cueCount: 1,
          // The geometry the client needs to place its hit rectangle. The real
          // numbers `ass.ts` uses, so a test measuring against these measures
          // against the document the app would actually be handed.
          layout: {
            fontFamily: 'Arial',
            fontSize: 48,
            playResX: 1920,
            playResY: 1080,
            margin: 60,
            outlineWidth: 2.5,
            boxPadding: 6,
            defaultAlignment: 2,
            defaultX: 960,
            defaultY: 1020,
            lineSpacing: 1.2,
          },
        },
      }) + '\n');
    } else if (req.method === 'test.captionLog') {
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: { lists: captionLists, gets: captionGets },
      }) + '\n');
    } else if (req.method === 'video.related') {
      process.stdout.write(JSON.stringify({ id: req.id, result: { items: [], continuation: null } }) + '\n');
    } else if (req.method === 'test.reset') {
      // Forget everything this run has recorded, so one sidecar can serve a
      // whole test file instead of one per test.
      //
      // **Restarting it per test is what made the suite flaky.** Killing and
      // respawning close behind each other raced Windows tearing down the old
      // process's pipes, and `Process.start` then failed outright — as an
      // unhandled async error, so it failed whichever test was running rather
      // than the one that caused it. One sidecar per file, reset between tests,
      // removes the race rather than widening the window around it.
      opens.length = 0;
      reports.length = 0;
      closes.length = 0;
      sessions = 0;
      realOpens = 0;
      baseAttempts = 0;
      captionLists.length = 0;
      captionGets.length = 0;
      searchCalls.length = 0;
      suggestCalls.length = 0;
      authCookies.length = 0;
      signOuts = 0;
      for (const key of Object.keys(ratings)) delete ratings[key];
      watchLaterMembership.clear();
      testPlaylistMembership.clear();
      // `test.reset {authState}` puts the session where a test needs to start
      // without going through `auth.signOut` — which would land in `signOuts`
      // and be counted against the test that follows. Default restores the
      // file's own starting state, so every pre-existing caller is unchanged.
      authState = typeof req.params?.authState === 'string'
        ? req.params.authState as typeof authState
        : (mode === 'empty-home' ? 'anonymous' : 'authenticated');
      process.stdout.write(JSON.stringify({ id: req.id, result: {} }) + '\n');
    } else if (req.method === 'test.playbackLog') {
      // The test's window into what the client actually sent. Reports are
      // fire-and-forget from the app's side, so there is nowhere else to see
      // whether the cadence is real or whether it only pings at completion.
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: { opens, reports, closes },
      }) + '\n');
    } else if (req.method === 'feed.home') {
      // Token grammar, for tests only:
      //
      //   ""                 base browse — ships a chip bar, like the real one
      //   "MUSIC"            filtered — echoed back in every item title
      //   "MUSIC@250"        the same, answered after 250 ms
      //   "MUSIC@250!keepalive"  answered even after $cancel
      //   "MUSIC!fail=user"  answered with a retry:"user" failure envelope
      //   "MUSIC!fail=auto"  answered with a retry:"auto" failure envelope
      //
      // `!keepalive` makes the sidecar answer a request the client cancelled,
      // so a superseded payload is genuinely put on the wire after its
      // replacement rather than never being sent. What drops it on the client
      // is layered — see the test — but without this the scenario cannot even
      // be staged.
      //
      // `!fail=` stages the paging-error path. The failure has to arrive as a
      // real envelope with a real `retry` value, because what the controller
      // does next is decided entirely by that field.
      const raw = (req.params && (req.params.continuation || req.params.chipToken)) || '';

      if (mode === 'base-fail-auto' && raw === '') {
        baseAttempts++;
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: {
            code: 'UPSTREAM_ERROR',
            message: `base browse failed, attempt ${baseAttempts}`,
            retry: 'auto',
          },
        }) + '\n');
        return;
      }

      const failAt = raw.indexOf('!fail=');
      if (failAt !== -1) {
        const mode = raw.slice(failAt + '!fail='.length);
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: mode === 'auto'
            ? { code: 'UPSTREAM_ERROR', message: 'upstream fell over', retry: 'auto' }
            : { code: 'STREAM_UNAVAILABLE', message: 'page unavailable', retry: 'user' },
        }) + '\n');
        return;
      }
      const keepalive = raw.endsWith('!keepalive');
      const spec = keepalive ? raw.slice(0, -'!keepalive'.length) : raw;
      const at = spec.indexOf('@');
      const label = at === -1 ? spec : spec.slice(0, at);
      const delay = at === -1 ? 0 : parseInt(spec.slice(at + 1), 10) || 0;
      const tag = label === '' ? 'BASE' : label;

      const send = () => {
        pending.delete(req.id);
        process.stdout.write(JSON.stringify({
          id: req.id,
          result: {
            // A filtered or paged response carries no feed chips — that is the
            // behaviour measured in home-continuation.json.
            chips: label === '' ? [
              { label: 'All', token: '', selected: true, scope: 'feed' },
              { label: 'Music', token: 'MUSIC', selected: false, scope: 'feed' },
              { label: 'Gaming', token: 'GAMING', selected: false, scope: 'feed' },
            ] : [],
            items: (mode === 'empty-home' && label === '' ? [] : [0, 1, 2]).map((n) => ({
              kind: 'video',
              id: `vid_${tag}_${n}`,
              title: `${tag} item ${n}`,
              channelName: 'Fake Channel',
              channelId: 'chan_001',
              channelAvatarUrl: null,
              thumbnailUrl: 'https://fake.url/img.jpg',
              durationSeconds: 60,
              isLive: false,
              viewCountText: null,
              publishedText: null,
              badges: [],
              canWatchLater: true,
              canAddToQueue: true,
            })),
            continuation: label === '' ? pagingContinuation : null,
          },
        }) + '\n');
      };

      if (delay === 0) {
        send();
      } else {
        const timer = setTimeout(send, delay);
        // Only a cancellable request goes in `pending`; $cancel clears that map.
        if (!keepalive) pending.set(req.id, timer);
      }
    } else if (req.method === 'search.suggest') {
      // Grammar: "<text>@<delayMs>" — the delay is how a debounce/cancel test
      // stages an in-flight request to supersede. Every call is recorded so a
      // test can assert exactly how many reached the wire.
      suggestCalls.push(req.params?.q);
      const raw = req.params?.q || '';
      const at = raw.indexOf('@');
      const q = at === -1 ? raw : raw.slice(0, at);
      const delay = at === -1 ? 0 : parseInt(raw.slice(at + 1), 10) || 0;
      const send = () => {
        pending.delete(req.id);
        process.stdout.write(JSON.stringify({
          id: req.id,
          result: { suggestions: [`${q} one`, `${q} two`, `${q} three`] },
        }) + '\n');
      };
      if (delay === 0) {
        send();
      } else {
        const timer = setTimeout(send, delay);
        pending.set(req.id, timer);
      }
    } else if (req.method === 'search.query') {
      // Token grammar, mirroring `feed.home`'s (test-only):
      //
      //   "foo"                first page — items tagged with the query
      //   "foo@250"            the same, answered after 250 ms
      //   "foo@250!keepalive"  answered even after $cancel
      //   "foo!fail=user"      answered with a retry:"user" failure envelope
      //   "foo!fail=auto"      answered with a retry:"auto" failure envelope
      //   "empty"              a real, successful zero-item page (not a failure)
      //
      // `continuation` alone (no `q`) is the second-page shape §3.3 promises —
      // this fixture answers it with a distinct item set and no further page.
      searchCalls.push({ q: req.params?.q, filters: req.params?.filters ?? null });
      const continuation = req.params?.continuation as string | undefined;
      if (continuation) {
        process.stdout.write(JSON.stringify({
          id: req.id,
          result: {
            items: [3, 4, 5].map((n) => ({
              kind: 'video',
              id: `search_p2_${n}`,
              title: `search page2 item ${n}`,
              channelName: 'Fake Channel',
              channelId: 'chan_001',
              channelAvatarUrl: null,
              thumbnailUrl: 'https://fake.url/img.jpg',
              durationSeconds: 60,
              isLive: false,
              viewCountText: null,
              publishedText: null,
              badges: [],
              canWatchLater: true,
              canAddToQueue: true,
            })),
            continuation: null,
          },
        }) + '\n');
        return;
      }

      const rawQ = (req.params?.q as string) || '';
      const failAt = rawQ.indexOf('!fail=');
      if (failAt !== -1) {
        const failMode = rawQ.slice(failAt + '!fail='.length);
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: failMode === 'auto'
            ? { code: 'UPSTREAM_ERROR', message: 'search upstream fell over', retry: 'auto' }
            : { code: 'STREAM_UNAVAILABLE', message: 'search unavailable', retry: 'user' },
        }) + '\n');
        return;
      }

      const keepalive = rawQ.endsWith('!keepalive');
      const spec = keepalive ? rawQ.slice(0, -'!keepalive'.length) : rawQ;
      const at = spec.indexOf('@');
      const q = at === -1 ? spec : spec.slice(0, at);
      const delay = at === -1 ? 0 : parseInt(spec.slice(at + 1), 10) || 0;

      const send = () => {
        pending.delete(req.id);
        const items = q === 'empty'
          ? []
          : [0, 1, 2].map((n) => ({
              kind: 'video',
              id: `search_${n}`,
              title: `${q} result ${n}`,
              channelName: 'Fake Channel',
              channelId: 'chan_001',
              channelAvatarUrl: null,
              thumbnailUrl: 'https://fake.url/img.jpg',
              durationSeconds: 60,
              isLive: false,
              viewCountText: null,
              publishedText: null,
              badges: [],
              canWatchLater: true,
              canAddToQueue: true,
            }));
        process.stdout.write(JSON.stringify({
          id: req.id,
          result: { items, continuation: q === 'empty' ? null : 'SEARCH_PAGE2' },
        }) + '\n');
      };

      if (delay === 0) {
        send();
      } else {
        const timer = setTimeout(send, delay);
        if (!keepalive) pending.set(req.id, timer);
      }
    } else if (req.method === 'feed.subscriptions') {
      // **A signed-out subscriptions feed is an upstream refusal, not an empty
      // page.** Measured live 2026-09-08 against the real sidecar: after
      // `auth.signOut`, `feed.subscriptions` answers
      // `UPSTREAM_ERROR — "You must be signed in to perform this operation."`.
      // Modelled here so `anonymous_browsing_test.dart` is asserting a real
      // difference between the browse family and the resolve family, rather
      // than a fake that answers the same thing either way.
      if (authState === 'anonymous') {
        process.stdout.write(JSON.stringify({
          id: req.id,
          error: {
            code: 'UPSTREAM_ERROR',
            message: 'You must be signed in to perform this operation.',
            retry: 'auto',
          },
        }) + '\n');
        return;
      }
      // Same anonymous/authenticated split as `feed.home`'s 'empty-home' mode
      // drives for `auth.verify`, minus the chip bar `feed.subscriptions` never
      // had.
      const items = mode === 'empty-home'
        ? []
        : [0, 1, 2].map((n) => ({
            kind: 'video',
            id: `sub_${n}`,
            title: `subscriptions item ${n}`,
            channelName: 'Fake Channel',
            channelId: 'chan_001',
            channelAvatarUrl: null,
            thumbnailUrl: 'https://fake.url/img.jpg',
            durationSeconds: 60,
            isLive: false,
            viewCountText: null,
            publishedText: null,
            badges: [],
            canWatchLater: true,
            canAddToQueue: true,
          }));
      process.stdout.write(JSON.stringify({ id: req.id, result: { items, continuation: null } }) + '\n');
    } else if (req.method === 'test.searchLog') {
      process.stdout.write(JSON.stringify({
        id: req.id,
        result: { searchCalls, suggestCalls },
      }) + '\n');
    } else if (req.method === 'test.large_payload') {
      const largeStr = 'x'.repeat(1000000);
      process.stdout.write(JSON.stringify({ id: req.id, result: largeStr }) + '\n');
    } else if (req.method === 'test.structured_payload') {
      // Deliberately structured rather than one long string: `test.large_payload`
      // is a megabyte of 'x', which jsonDecode chews through in a few ms — far
      // too fast to tell an offloaded decode from an inline one. An array of
      // objects is the shape that actually costs parser time, which is what the
      // ordering test needs to be measuring.
      const n = req.params?.count ?? 120000;
      const rows = [];
      for (let i = 0; i < n; i++) {
        rows.push({ i, id: `vid_${i}`, title: `row ${i} ${'y'.repeat(48)}`, live: false });
      }
      process.stdout.write(JSON.stringify({ id: req.id, result: rows }) + '\n');
    }
  } catch (err) {
    process.stderr.write(`fake_sidecar error: ${err}\n`);
  }
});
