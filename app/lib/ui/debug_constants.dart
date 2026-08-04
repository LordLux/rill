// The measurement plan constants for the debug player.

/// Spike 05's check 4, unchanged: four seeks, at these wall-clock seconds.
const List<(int, int)> seekPlan = [
  (5, 100), (10, 200), (15, 300), (20, 400), (25, 500),
  (30, 600), (35, 700), (40, 800), (45, 900), (50, 1000)
];

/// Seconds after a seek before its position is read.
const int checkDelaySeconds = 5;

/// Wall-clock second the run ends.
const int quitAtSeconds = 5;

/// **Position must advance past the target, never equal it.**
const double advancedByAtLeast = 0.5;

/// F11 and F13's value. 1 MB.
const int requestSizeBytes = 1048576;

/// The hedge `sidecar/src/playback/mpv-options.ts` records, plus the seek-size companion.
const String streamLavfOptions = 'request_size=$requestSizeBytes,short_seek_size=$requestSizeBytes';

/// mpv properties sampled for the readout and the verdict.
const List<String> observedProperties = [
  'mpv-version',
  'ffmpeg-version',
  'hwdec',
  'hwdec-current',
  'video-codec',
  'current-tracks/video/decoder-desc',
  'audio-codec',
  'avsync',
  'frame-drop-count',
  'decoder-frame-drop-count',
  'track-list/count',
  'aid',
  'vo',
  'stream-lavf-o',
  'demuxer-cache-time',
  'video-params/w',
  'video-params/h',
  'video-params/pixelformat',
  'video-params/hw-pixelformat',
  'container-fps',
  'estimated-vf-fps',
];

/// How often the property sample runs.
const Duration sampleInterval = Duration(seconds: 1);

/// mpv log lines worth keeping
final RegExp interestingLogLines = RegExp(r'hwdec|hardware|software decoding|decoder|dav1d|Using|VO:|AO:', caseSensitive: false);
