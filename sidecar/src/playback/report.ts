/**
 * `playback.report` — the load-bearing one (`protocol.md` §3.5, `architecture.md`
 * §2.4).
 *
 * If watch events stop landing, the recommender stops training and the homepage
 * drifts away from the real one — which defeats the point of the app. So this
 * path fails loudly. Nothing here swallows an error to keep a report quiet.
 *
 * **Two calls, never bridged.** Streams resolve anonymously as `VISIONOS`;
 * reporting goes over the authenticated `WEB` session with a CPN of its own
 * (F6, and A5 which rejects propagating a resolution client's CPN). The
 * consequence worth naming, because it contradicts a reasonable reading of the
 * task brief's "one player response": reporting needs a **`WEB`** `/player`
 * response, and ladder tier 1 fetched an `VISIONOS` one. The tracking URLs
 * carry request-scoped `ei` / `of` / `vm` parameters minted for the call that
 * produced them, so the anonymous response's URLs are not a substitute — using
 * them would be precisely the cross-client bridging A5 rejects.
 *
 * That `WEB` call is therefore a second `/player` round trip, and it is:
 *
 *   - **deferred** until the first report, so a video that is opened and never
 *     watched never pays for it, and
 *   - **cached** by `innertube/player-response.ts` for the whole watch, so the
 *     hundred-odd reports of a long video cost one.
 */

import { RpcError, messageOf } from '../errors.ts';
import { logger } from '../log.ts';
import { getPlayerResponse } from '../innertube/player-response.ts';
import type { Session } from '../innertube/session.ts';
import type { PlaybackReportState } from '../types.ts';
import { getPlaybackSession } from './sessions.ts';

const log = logger('playback-report');

export interface ReportDeps {
  /** The authenticated `WEB` session. The reporting client, per F6 and §2.3. */
  browse: Session;
}

export interface ReportParams {
  sessionId: string;
  positionMs: number;
  state: PlaybackReportState;
}

/**
 * `s.youtube.com` is where YouTube publishes these URLs; `www.youtube.com` is
 * where an authenticated request is answered as authenticated. youtubei.js makes
 * the same substitution for the same reason — a ping to the `s.` host succeeds
 * and is attributed to nobody, which is the failure this module exists to make
 * impossible to have silently.
 */
function authenticatedHost(url: string): string {
  return url.replace('https://s.', 'https://www.');
}

/** The client identity the stats endpoint wants alongside the ping. */
function statsClient(session: Session): { client_name: string; client_version: string } {
  const client = session.innertube.session.context.client;
  return {
    client_name: client.clientName ?? 'WEB',
    client_version: client.clientVersion ?? '2.0',
  };
}

async function ping(
  session: Session,
  url: string,
  params: Record<string, string | number>,
  description: string,
): Promise<void> {
  let response: Response;
  try {
    response = await session.innertube.actions.stats(
      authenticatedHost(url),
      statsClient(session),
      params,
    );
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `${description} failed: ${messageOf(error)}`);
  }

  if (!response.ok) {
    throw new RpcError('UPSTREAM_ERROR', `${description} answered HTTP ${response.status}`);
  }
}

/**
 * The tracking URLs for this video, from the `WEB` response.
 *
 * A response without them is a real loss of capability, not a quiet no-op: it
 * means this watch will not reach the user's history. `UPSTREAM_ERROR` rather
 * than a silent return, so it shows up as a failure somebody can see.
 */
async function trackingUrls(
  deps: ReportDeps,
  videoId: string,
  playlistId: string | null,
): Promise<{ playback: string | null; watchtime: string }> {
  // `playlistId` is what puts `list=` on the watchtime URL — measured
  // 2026-09-12: the same `/player` call without it carries no such parameter,
  // so every watch inside a mix was being reported as a standalone watch. A
  // mix is one of the strongest recommendation signals there is, and F6 is
  // about exactly this path.
  const response = await getPlayerResponse(deps.browse, videoId, 'WEB', { playlistId });
  if (!response.videostatsWatchtimeUrl) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `${videoId}: the WEB /player response carries no videostatsWatchtimeUrl — ` +
        'watch history cannot land for this video',
    );
  }
  return {
    playback: response.videostatsPlaybackUrl,
    watchtime: response.videostatsWatchtimeUrl,
  };
}

/**
 * One report. Cadence is the app's business (§3.5: every 10–30 s plus state
 * changes); this issues exactly the pings that report describes.
 *
 * The first report of a session also fires `videostatsPlaybackUrl`, which is
 * what registers the view at all — a watchtime ping on its own updates a
 * position for a view YouTube was never told about.
 */
export async function reportPlayback(
  deps: ReportDeps,
  params: ReportParams,
): Promise<Record<string, never>> {
  const session = getPlaybackSession(params.sessionId);
  if (!session) {
    // A client bug or a report after `playback.close`: either way the same bytes
    // will fail forever, which is what `BAD_REQUEST`'s `retry: "no"` means.
    throw new RpcError(
      'BAD_REQUEST',
      `playback.report: no open session '${params.sessionId}'. ` +
        'Report before playback.close, and only against a sessionId playback.open returned.',
    );
  }

  const positionSeconds = Math.max(0, params.positionMs / 1000);
  const urls = await trackingUrls(deps, session.videoId, session.playlistId);

  if (!session.playbackPinged && urls.playback) {
    await ping(
      deps.browse,
      urls.playback,
      // `fmt` names the itag being played. The client picks its variant and may
      // step down (F16), so this is the audio itag youtubei.js reports for the
      // same call rather than a claim about the video track — the endpoint reads
      // it as a hint, and the view registers either way.
      { cpn: session.cpn, fmt: 251, rtn: 0, rt: 0 },
      `${session.videoId}: playback ping`,
    );
    session.playbackPinged = true;
    log.info(`${session.videoId}: view registered (cpn ${session.cpn})`);
  }

  // The segment this report covers. `st` never runs past `et`: a backward seek
  // would otherwise describe a negative interval, and the endpoint's answer to
  // that is a 200 that counts nothing.
  const start = Math.min(session.lastPositionSeconds, positionSeconds);

  await ping(
    deps.browse,
    urls.watchtime,
    {
      cpn: session.cpn,
      st: start.toFixed(3),
      et: positionSeconds.toFixed(3),
      cmt: positionSeconds.toFixed(3),
      ...(params.state === 'ended' ? { final: '1' } : {}),
    },
    `${session.videoId}: watchtime ping`,
  );

  session.lastPositionSeconds = positionSeconds;
  log.debug(
    `${session.videoId}: reported ${params.state} at ${positionSeconds.toFixed(1)}s ` +
      `(segment ${start.toFixed(1)}→${positionSeconds.toFixed(1)})`,
  );

  return {};
}
