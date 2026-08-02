/**
 * The libmpv options every playback surface sets.
 *
 * One option, and it is a hedge rather than a requirement. F13 measured the
 * libmpv `media_kit_libs_windows_video` actually ships — mpv v0.36.0-403 /
 * FFmpeg n6.0 — seeking `ANDROID_VR` streams 4/4 with nothing set at all, five
 * runs. So this changes nothing today. It matters the day the pin moves: on
 * FFmpeg from Lavf 62.10.101 onward, ffmpeg soft-seeks instead of repositioning
 * — it drains hundreds of megabytes through the open connection rather than
 * issuing a new range request — and the same four seeks go 0/4, frozen at
 * exactly the target position while nothing advances. With this option they go
 * 4/4 (F11, F13, and spike 03's matrix, which measured `request_size` alone
 * sufficient on `ANDROID_VR`).
 *
 * The shipped build accepts the option, returns success, echoes it back on read,
 * and ignores it entirely, because its FFmpeg has no such AVOption. That is why
 * it is set unconditionally rather than probed for: **option acceptance is not
 * evidence of option support** (hard invariant 8). One string covers both worlds
 * and makes a future pin bump a non-event instead of an incident where playback
 * looks perfect until the user touches the progress bar.
 *
 * Nothing in the sidecar plays anything — `probe-playback.ts` is the only
 * consumer here. It lives in `src/` rather than in the probe because the Flutter
 * player is the other consumer and there should be one place that records both
 * the value and the reason for it.
 */

/** 1 MB. The value every measurement in F11 and F13 used. */
export const REQUEST_SIZE_BYTES = 1_048_576;

/** The `stream-lavf-o` value: options passed through to ffmpeg's HTTP protocol. */
export const STREAM_LAVF_OPTIONS = `request_size=${REQUEST_SIZE_BYTES}`;

/** mpv/libmpv option name → value. media_kit takes the same pairs. */
export const MPV_OPTIONS: Readonly<Record<string, string>> = Object.freeze({
  'stream-lavf-o': STREAM_LAVF_OPTIONS,
});

/** The same options as command-line arguments, for anything spawning mpv. */
export const MPV_ARGS: readonly string[] = Object.freeze(
  Object.entries(MPV_OPTIONS).map(([name, value]) => `--${name}=${value}`),
);

/**
 * The command that plays a resolved source: one URL, or two merged with
 * `--audio-file` (§2.4).
 */
export function mpvCommand(videoUrl: string, audioUrl: string | null): string {
  return [
    'mpv',
    `"${videoUrl}"`,
    ...(audioUrl ? [`--audio-file="${audioUrl}"`] : []),
    ...MPV_ARGS,
  ].join(' ');
}
