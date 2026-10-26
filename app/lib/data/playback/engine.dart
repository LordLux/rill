import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/playback_source.dart';
import '../../ui/debug_constants.dart';

/// The player, as everything above it is allowed to see it.
///
/// An interface rather than `Player` directly, for two reasons that are not
/// symmetrical. The small one is that `flutter test` has no libmpv, so a
/// controller talking to `Player` cannot be tested at all. The large one is
/// **hard invariant 9**: everything a caller can reach here is a stream or a
/// value this class already cached from one. There is no `getProperty` on this
/// surface, so no future caller can poll one from the UI isolate — F15 measured
/// a 6.4 s frame-loop freeze doing exactly that, and it manufactured a false
/// "seek is broken" reading before the harness was corrected.
abstract class PlaybackEngine {
  /// Position, duration and buffering come from mpv's event stream (invariant 9).
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;

  /// mpv waiting rather than presenting: opening a file, repositioning after a
  /// seek, or genuinely starved of data.
  ///
  /// **Wider than "the cache ran dry", and that is what makes it useful.**
  /// media_kit raises this from `core-idle` as well as `paused-for-cache`, and
  /// F18 measured seeks as ~95% `core-idle` (median 2458 ms of 2600) with
  /// `paused-for-cache` at **zero in all 75 samples** — so a spinner keyed on
  /// cache starvation alone would never appear on the thing that actually makes
  /// the user wait. media_kit also suppresses the `core-idle` that a `pause`
  /// causes, so this does not fire on a deliberate pause.
  ///
  /// It does **not** cover the long-pause resume penalty: F18 found those never
  /// touch `core-idle` or `paused-for-cache` at all, so a 0.5–2.3 s resume after
  /// a long idle shows nothing. Known gap, no signal available for it.
  Stream<bool> get bufferingStream;

  /// How far the demuxer has read ahead — the scrubber's buffered range.
  Stream<Duration> get bufferStream;

  /// The width mpv is **actually decoding**. Null until the first frame is decoded.
  Stream<int?> get widthStream;

  /// The height mpv is **actually decoding**, which is not the height that was
  /// asked for: a variant can be opened and then serve something else, and the
  /// quality menu that reports the request rather than the result is the one
  /// that lies exactly when it matters. Null until the first frame is decoded.
  Stream<int?> get heightStream;

  /// mpv's own volume, 0–100. Streamed rather than assumed, so a volume set from
  /// anywhere is the one the slider draws.
  Stream<double> get volumeStream;

  /// Fires once per media that plays to its end. Drives queue autoplay.
  Stream<bool> get completedStream;

  /// The last values seen on the streams above. Never a property read.
  Duration get position;
  Duration get duration;
  bool get playing;

  /// Whether mpv has a **configured video output** — that is, whether there is
  /// actually a picture.
  ///
  /// The signal for "video is back after audio-only", and the only one that
  /// works. Measured 2026-09-23 across a `vid=no` -> `vid=auto` toggle on a
  /// 96-minute 1080p video: media_kit's cached [width] and the
  /// `VideoController`'s `rect` both keep their old values straight through
  /// audio-only and never clear, and mpv's own `width` comes back the instant
  /// the track is re-enabled — 5 seconds before anything is on screen.
  /// `vo-configured` is `no` for the whole audio-only phase and flips to `yes`
  /// exactly when the picture returns.
  ///
  /// Observed rather than polled, so hard invariant 9 holds: mpv delivers the
  /// change on its own event thread and nothing reads a property from the UI
  /// isolate.
  Stream<bool> get videoOutputStream;

  /// The latest value of [videoOutputStream].
  bool get videoOutputReady;

  /// Whether mpv is waiting rather than presenting — see [bufferingStream].
  bool get buffering;
  Duration get buffer;
  int? get width;
  int? get height;
  double get volume;

  /// The video surface, for whichever widget is currently showing it.
  ///
  /// A method on the engine rather than a `Video` built at each call site,
  /// because the thing being shared is subtle and worth having exactly one
  /// statement of: **the texture belongs to the engine, not to the widget.**
  /// `VideoController` allocates the native `VideoOutput` and registers its
  /// release on `Player.dispose` — so a `Video` widget unmounting frees nothing,
  /// and this is a `Texture` id reference that any subtree may hold. Nothing
  /// resizes on layout either; `setSize` is only ever called explicitly.
  ///
  /// That is what lets the watch page and the mini-player show live video from
  /// one player without either of them owning it, and without a texture being
  /// created or freed when the route changes.
  Widget videoWidget({BoxFit fit = BoxFit.contain});
  Widget videoSurface({BoxFit fit = BoxFit.contain});

  /// The layer link tied to the video surface, for syncing overlays.
  LayerLink get videoLayerLink;

  /// The ASS document currently attached, or null.
  ///
  /// Engine state rather than controller state, because it is a fact about what
  /// mpv is holding — and because [open] has to know it in order to put it back
  /// after a quality switch.
  String? get subtitle;

  /// Attach an ASS document as an external subtitle track, or detach with null.
  /// 
  /// The document is injected entirely in-memory and bypasses the filesystem.
  /// This is one of the three options identified in the task brief for 
  /// decoupling track styling from media demuxing.
  Future<void> setSubtitle(String? ass);

  /// Toggle visibility of the current subtitle track.
  Future<void> setSubtitleVisible(bool visible);

  /// The plain text of the caption currently on screen, tags stripped.
  ///
  /// **The one thing about a caption that mpv does publish**, and Task 19 is
  /// built on it. libass composites into the video texture and exposes no
  /// geometry, so there is nothing to hit-test — but `sub-text` stays populated
  /// while libass is drawing (measured 2026-08-20 with `sub-ass=yes` and
  /// `sub-visibility=yes`, which is the shipping configuration), and knowing the
  /// *words* is enough to estimate the rectangle they occupy.
  ///
  /// **Nothing renders this.** Drawing it would be the second caption renderer
  /// that hid a bug for two tasks — see [kNoFlutterSubtitles]. It feeds the hit
  /// rectangle, the hover cursor and the drag ghost, and the ghost is only ever
  /// on screen while the real caption is being dragged.
  Stream<String?> get subtitleTextStream;

  /// Enable or disable mpv's video track without reopening the media.
  ///
  /// **This is what makes Audio-Only → Video instant.** The old approach opened
  /// the audio URL as the primary media in audio-only mode, which meant
  /// switching back to video required a full `engine.open` — a cold reopen
  /// costing 6+ seconds (seek, duration wait, picture wait). Toggling `vid`
  /// instead keeps the demuxer, the cache and the position intact; mpv simply
  /// stops or starts decoding video frames.
  ///
  /// `vid=auto` re-enables; `vid=no` disables. Both are mpv properties that
  /// the shipped v0.36.0-403 build supports (F12/F15 confirmed `vid` in the
  /// string table).
  Future<void> setVideoTrack(bool enabled);

  /// [retainSubtitle] puts the attached track back after the media reopens.
  ///
  /// A quality switch reopens the media (F19) and mpv drops external subtitle
  /// tracks with it. Opening a *different video* must not carry the previous
  /// one's captions, so this is opt-in and only `switchQuality` passes it.
  ///
  /// [shouldPlay] is asked at the moment the open would start playing, and a false
  /// answer leaves it paused: [play] is what was wanted when the call was made, and
  /// a pause pressed during the load must win over it.
  Future<void> open(
    PlaybackVariant variant, {
    bool play = true,
    bool Function()? shouldPlay,
    bool retainSubtitle = false,
    bool isLive = false,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration to);
  Future<void> setVolume(double volume);

  /// One frame forward (`direction > 0`) or back — the `,` and `.` keys.
  ///
  /// A distinct operation from [seek] rather than a seek of 1/fps, because
  /// "one frame" is a thing only the decoder knows: a computed seek lands *near*
  /// the neighbouring frame and rounds differently on variable frame rate.
  Future<void> stepFrame(int direction);

  /// Stop playback and release the current media. The engine stays usable.
  ///
  /// An [open] still waiting when this is called ends with [OpenSuperseded]. A stop is not an
  /// ending: it reports no completion, so nothing above it advances a queue.
  Future<void> stop();

  /// The last [open] was given a separate audio stream and none loaded: the video plays
  /// without sound and nothing else says so. Always false for a muxed variant, and for an
  /// audio-only open, which fails with [AudioUnavailable] instead.
  bool get audioMissing;

  /// Changes of [audioMissing]. The one that matters after an open is `false`: the track list
  /// can trail the grace [open] allows it on a loaded machine, so a notice raised for missing
  /// audio has to come down if the audio turns up after all.
  Stream<bool> get audioMissingStream;

  /// Whether [switchVideo] can change to [variant] on the media that is open, without
  /// reopening it: the video is an added track, the audio is the one the media was opened
  /// with, and this is not a live stream or a muxed variant. False sends the caller to
  /// [open], whose cover is the cost of that.
  bool canSwitchVideo(PlaybackVariant variant);

  /// Change the video to [variant] in place (`video-add`, a seek to where the clock is, then
  /// `video-remove` of the track it replaced). One at a time is the caller's to keep. The
  /// old picture, and the old quality's sound, hold until it is done; a failure leaves the
  /// old quality playing and is reported, never thrown, so the caller can reopen.
  Future<VideoSwitch> switchVideo(PlaybackVariant variant);

  Future<void> dispose();
}

/// How [PlaybackEngine.switchVideo] ended.
enum VideoSwitch {
  /// The new quality is showing, at the old position.
  done,

  /// The stream would not open or the seek never finished; the old quality is still playing.
  refused,

  /// [PlaybackEngine.canSwitchVideo] said no; nothing was touched.
  unsupported,
}

/// An [PlaybackEngine.open] that a newer open or a stop overtook before it finished.
///
/// Not a failure of the stream: the caller that started it has moved on, and says so by its
/// own generation check before it reads this.
class OpenSuperseded implements Exception {
  const OpenSuperseded();

  @override
  String toString() => 'the open was superseded';
}

/// An audio-only open whose audio did not load: nothing is left to play, since the video-only
/// stream is not selected. Its text reaches the screen, so it names no URL.
class AudioUnavailable implements Exception {
  const AudioUnavailable();

  @override
  String toString() => 'The audio for this video would not load.';
}

/// Why captions need two settings, and what happens with neither.
///
/// **media_kit ships with libass off, and draws subtitles in Flutter instead.**
/// `PlayerConfiguration.libass` defaults to `false`, and media_kit turns that
/// into `sub-ass=no` *and* `sub-visibility=no` on the mpv side — so mpv strips
/// every ASS tag and then draws nothing. It observes the resulting plain text on
/// mpv's `sub-text` property and hands it to `SubtitleView`, a Flutter widget
/// that `Video` mounts by default (`SubtitleViewConfiguration.visible` is
/// `true`) and paints with a Flutter `TextStyle`.
///
/// So captions *appeared* to work while every override the sidecar emits was
/// being discarded: no bold, no italic, no font, no size, no colour, no
/// position. Diagnosed 2026-08-19 from a screenshot of `L-BgxLtMxh0` in which
/// two cues the document puts at opposite ends of the frame were stacked at the
/// bottom in document order — which is `SubtitleView` rendering
/// `player.state.subtitle`, a *list* of strings, and not a layout libass would
/// ever produce.
///
/// It also means Task 17's "stacked duplicates" were never libass colliding two
/// events. They were two list entries. The sidecar-side merge is still right —
/// it is what a single caption composited from two pens actually is — but the
/// symptom that motivated it had this cause.
///
/// The two settings have to agree, and each alone is wrong:
///
///  - `libass: true` alone leaves `SubtitleView` painting a plain-text copy over
///    the styled one, which is the same caption twice in two fonts.
///  - `visible: false` alone leaves `sub-visibility=no`, which is no captions.
///
/// `architecture.md` §2.9 is the decision this restores; it said "Flutter draws
/// no captions" and, until this, the shipped widget did.
/// Off, so the only thing drawing captions is libass. Half of the pair.
const kNoFlutterSubtitles = SubtitleViewConfiguration(visible: false);

/// On, so mpv renders them at all. The other half.
///
/// Kept beside its partner and named, rather than written inline at the one call
/// site, because the two are only correct together and a reader who finds one
/// needs to find the other.
const kLibassEnabled = true;

/// The real engine: one `media_kit` [Player] for the whole app.
///
/// Owned by the shell above the `Navigator` (task §1), so a route pop cannot
/// take it — and with it the audio and the position — down.
class MediaKitEngine implements PlaybackEngine {
  /// [logLevel] is for measurement harnesses only. mpv at `v` is the level that
  /// shows stream opens and cache events — the per-track evidence no property
  /// exposes, because `demuxer-cache-state` describes one demuxer and an
  /// external audio track is a second one. It is off in the app.
  MediaKitEngine({MPVLogLevel? logLevel}) {
    // `libass: true` is not optional, and its default is the reason captions
    // rendered as plain text for two tasks. See [kNoFlutterSubtitles].
    _player = Player(
      configuration: logLevel == null
          ? const PlayerConfiguration(libass: kLibassEnabled)
          : PlayerConfiguration(libass: kLibassEnabled, logLevel: logLevel),
    );
    _video = VideoController(_player);

    // The one option architecture §2.4 says to set unconditionally. The build
    // media_kit ships (mpv v0.36.0-403 / FFmpeg n6.0) accepts it, echoes it back
    // and ignores it — it has no such AVOption (F12/F15, and hard invariant 8
    // is about exactly this false positive). It costs nothing here and is the
    // difference between 0/4 and 4/4 seeks on any FFmpeg from Lavf 62.10.101
    // onward, so a future pin bump is a non-event instead of a silent freeze.
    unawaited(_setStreamOptions());
    unawaited(_observeVideoOutput());
    unawaited(_observeTrackState());

    _subscriptions.addAll([
      _player.stream.position.listen((value) => _position = value),
      _player.stream.duration.listen((value) => _duration = value),
      _player.stream.playing.listen((value) => _playing = value),
      _player.stream.buffering.listen((value) => _buffering = value),
      _player.stream.buffer.listen((value) => _buffer = value),
      _player.stream.width.listen((value) => _width = value),
      _player.stream.height.listen((value) => _height = value),
      _player.stream.volume.listen((value) => _volume = value),
    ]);
  }

  late final Player _player;
  late final VideoController _video;

  /// Receives one line per call below. Set by `mpv_log.dart`; null otherwise.
  void Function(String line)? trace;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  Duration _buffer = Duration.zero;
  int? _width;
  int? _height;
  double _volume = 100;
  bool _videoOutputReady = false;
  final StreamController<bool> _videoOutput = StreamController<bool>.broadcast();

  /// The controller, which outlives every route. Prefer [videoSurface].
  VideoController get videoController => _video;

  /// The variant handed to the last [open], **for diagnostics only**.
  ///
  /// `PlaybackController` publishes `source` and `variant` to state only *after*
  /// `open` returns, so when `open` throws — the 20 s audio-attach timeout being
  /// the case that matters — nothing above the engine ever learns which URL was
  /// being played. That is precisely the failure worth investigating, and it was
  /// unobservable from outside. Nothing that renders reads this.
  PlaybackVariant? lastOpened;

  /// mpv itself, **for diagnostics only** — hard invariant 9's own carve-out.
  ///
  /// Nothing that renders may touch this. `getProperty` is a blocking FFI call
  /// that can sit on mpv's core lock through a seek (F15 recorded a 6.4 s
  /// freeze), so the UI reads streams and this exists for measurement harnesses
  /// that need `observeProperty` — which delivers on mpv's event thread and
  /// polls nothing.
  NativePlayer get diagnostics => _player.platform as NativePlayer;

  /// mpv's own log lines. Empty unless the engine was built with a `logLevel`.
  Stream<PlayerLog> get logStream => _player.stream.log;

  /// mpv's error channel — failures it reports rather than logs. Diagnostics.
  Stream<String> get errorStream => _player.stream.error;

  /// `controls: NoVideoControls` because every caller draws its own.
  @override
  final LayerLink videoLayerLink = LayerLink();

  /// media_kit's `Video` widget, configured for this player.
  ///
  /// Built with `NoVideoControls` and `kNoFlutterSubtitles` — it is a *second* renderer for the same
  /// captions, and the one that was winning.
  @override
  Widget videoWidget({BoxFit fit = BoxFit.contain}) {
    return Video(
      controller: _video,
      fit: fit,
      controls: NoVideoControls,
      subtitleViewConfiguration: kNoFlutterSubtitles,
      fill: const Color(0x00000000), // Colors.transparent
    );
  }

  @override
  Widget videoSurface({BoxFit fit = BoxFit.contain}) {
    return CompositedTransformTarget(
      link: videoLayerLink,
      child: videoWidget(fit: fit),
    );
  }

  /// Register the `vo-configured` observer, once, for the engine's lifetime.
  ///
  /// Once: media_kit throws `Already observed` on a second registration for the
  /// same property, so this cannot be done per toggle. mpv reports the value as
  /// the strings `yes` and `no`.
  ///
  /// Failure is logged and swallowed. A missing observer costs a spinner that
  /// never appears, which is the old behaviour — not a player that will not
  /// start.
  Future<void> _observeVideoOutput() async {
    try {
      await (_player.platform as NativePlayer).observeProperty('vo-configured', (value) async {
        final ready = value == 'yes';
        if (ready == _videoOutputReady) return;
        _videoOutputReady = ready;
        if (!_videoOutput.isClosed) _videoOutput.add(ready);
      });
    } on Object catch (e) {
      stderr.writeln('rill: could not observe vo-configured ($e) — no picture signal');
    }
  }

  Future<void> _setStreamOptions() async {
    // `RILL_STREAM_LAVF_O` replaces the value for one run. Measurement only —
    // it exists so ffmpeg's `reconnect*` options can be tested **one at a time**
    // against a real 15-minute idle, which is the only way to know which of them
    // matters rather than that some combination did. Unset in ordinary use.
    final override = Platform.environment['RILL_STREAM_LAVF_O']?.trim();
    final value = (override == null || override.isEmpty) ? streamLavfOptions : override;
    if (override != null && override.isNotEmpty) {
      stderr.writeln('engine: stream-lavf-o overridden -> $value');
    }
    try {
      await (_player.platform as NativePlayer).setProperty('stream-lavf-o', value);
      await (_player.platform as NativePlayer).setProperty('user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    } on Object {
      // media_kit discards mpv's return code anyway (F15), so a throw here is
      // the binding failing, not mpv refusing. Nothing this app does depends on
      // the option, so it is not worth failing a launch over.
    }
  }

  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;

  @override
  Stream<bool> get videoOutputStream => _videoOutput.stream;

  @override
  bool get videoOutputReady => _videoOutputReady;
  @override
  Stream<Duration> get bufferStream => _player.stream.buffer;
  @override
  Stream<int?> get widthStream => _player.stream.width;
  @override
  Stream<int?> get heightStream => _player.stream.height;
  @override
  Stream<double> get volumeStream => _player.stream.volume;
  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get playing => _playing;
  @override
  bool get buffering => _buffering;
  @override
  Duration get buffer => _buffer;
  @override
  int? get width => _width;
  @override
  int? get height => _height;
  @override
  double get volume => _volume;

  /// Open a variant: video first, then the audio track attached to it.
  ///
  /// The wait before `setAudioTrack` is the fix for the audio-attach race in
  /// `architecture.md` §4 — `audio-add … select` is ignored until a file is
  /// loaded and the demuxer reports a duration (F15). Guarded on the duration
  /// already being known, because a fast load has already fired the event and
  /// `firstWhere` on a stream that has passed waits forever.
  String? _subtitle;

  @override
  String? get subtitle => _subtitle;

  /// `SubtitleTrack.data` — mechanism (1) of the three in the task brief, and the
  /// cheapest: no file we own, no server, no cleanup path of our own.
  ///
  /// Two things about media_kit's implementation are worth knowing and are not
  /// documented by it. It writes the string to a **temp file with no extension**
  /// (a bare UUID under `Directory.systemTemp`) and hands mpv the URI, so format
  /// detection is by content — an ASS document has to start `[Script Info]`, and
  /// `ass.ts` guarantees it does. And it registers that file for deletion on
  /// `Player.dispose`, not on the next track change, so a session that switches
  /// language repeatedly leaves one small file per switch until the app exits.
  ///
  /// `SubtitleTrack.no()` rather than a `sub-remove`: media_kit routes the
  /// non-data case through `sid`, which is the property mpv uses to *select*
  /// nothing, and leaves the loaded track alone. Turning captions back on
  /// re-adds them, which costs a temp file and no round trip.
  bool _isSubtitleVisible = true;

  @override
  Future<void> setSubtitle(String? ass) async {
    _subtitle = ass;
    if (ass == null || !_isSubtitleVisible) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    await _player.setSubtitleTrack(SubtitleTrack.data(ass, title: 'Captions'));
  }

  @override
  Future<void> setSubtitleVisible(bool visible) async {
    _isSubtitleVisible = visible;
    if (visible && _subtitle != null) {
      await _player.setSubtitleTrack(SubtitleTrack.data(_subtitle!, title: 'Captions'));
    } else {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    }
  }

  /// media_kit's own view of mpv's `sub-text`, flattened to one string.
  ///
  /// It is a `List<String>` because mpv can report a cue as several lines, so
  /// they are joined the way ASS joins them and `\N` becomes a newline. Empty
  /// entries — which is what the stream carries between cues — become null, so
  /// "no caption" is one value rather than three spellings of it.
  ///
  /// **Nothing reads this today.** It was how `CaptionDragLayer` learned what
  /// libass was drawing, back when that was the only way to find out; `LibassLayer`
  /// renders the document itself and has the cues in hand. Kept as an engine
  /// capability rather than deleted with its one caller, but it is dead weight
  /// if nothing picks it up.
  @override
  Stream<String?> get subtitleTextStream => _player.stream.subtitle.map((lines) {
        final joined = lines.where((line) => line.isNotEmpty).join('\n').trim();
        return joined.isEmpty ? null : joined;
      });

  @override
  Future<void> open(
    PlaybackVariant variant, {
    bool play = true,
    bool Function()? shouldPlay,
    bool retainSubtitle = false,
    bool isLive = false,
  }) async {
    bool wantPlay() => play && (shouldPlay?.call() ?? true);
    // A newer open, or a stop, ends this one: its wait for a duration would otherwise run out
    // 20 s later and retry the load over whatever the engine has been given since.
    _supersedeOpen();
    final superseded = Completer<void>();
    _openSuperseded = superseded;
    _setAudioMissing(false);
    lastOpened = variant;
    trace?.call('open ${variant.height}p play=$play live=$isLive audio=${variant.audioUrl != null}');
    // Read before the open, applied after it. A reopen drops mpv's external
    // subtitle tracks, and this is the only place that knows one was attached.
    //
    // **The document itself stays through a retained reopen.** `LibassLayer` draws from
    // [subtitle], not from mpv's track, and clearing it here took the caption off the
    // screen for the whole switch (measured 2026-10-24); mpv's track is what the reopen
    // drops, and [setSubtitle] below puts that back.
    final retained = retainSubtitle ? _subtitle : null;
    if (!retainSubtitle) _subtitle = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffer = Duration.zero;
    // Cleared rather than left: this is what the quality menu reads as "actually
    // playing", and a stale height from the *previous* variant would keep
    // claiming the old one for as long as it took the first frame to decode —
    // which is precisely the window a user watches after switching.
    _width = null;
    _height = null;

    // **A file must have a selected stream at load, or it never loads.** The
    // video URL is video-only, so with `vid=no` and the audio not yet attached
    // nothing is selected: mpv skips the file, no duration ever arrives, and the
    // wait below runs out its 20 s — which is what the "stuck at 0:00" audio-only
    // stall was (`architecture.md` §2.4, `9299ed3`).
    //
    // `9299ed3` fixed that by forcing video on for every open, which works but
    // means every audio-only track fetched and decoded video only to drop it a
    // moment later. Instead, when video is off and there is a separate audio
    // stream, the audio is attached **at load** through `audio-files`, so the
    // file has a selected stream from the start and the video is never read.
    //
    // **Through `change-list`, never `setProperty('audio-files', …)`.** It is a
    // path list, and a property write parses the value: an empty string does not
    // clear it but sets a list of one empty path, which mpv then tries to open —
    // measured 2026-09-24, every video-mode open failed with `Cannot open file
    // '': Invalid argument`. A URL containing `;` would be split in two the same
    // way. `clr` empties it and `append` adds one element unparsed.
    //
    // Cleared on every open, never left: it is an option, not per-file state, so
    // a previous audio-only open's track would otherwise load into this one as a
    // second audio stream.
    // `RILL_DEBUG_DEAD_AUDIO=1` swaps the audio URL for one that cannot connect, to see the
    // "No sound" notice and the video-only fallback without waiting for YouTube to refuse one.
    // Measurement only; unset in ordinary use.
    final audioUrl = variant.audioUrl != null && Platform.environment['RILL_DEBUG_DEAD_AUDIO'] == '1'
        ? 'https://127.0.0.1:9/dead.webm'
        : variant.audioUrl;
    final native = _player.platform as NativePlayer;
    // **Attached at load in video mode too (todo 103, 102).** The audio used to be added
    // after the duration was known, and starting the video first played it silent until
    // the sound joined (issue #22). At load, mpv holds the whole open — duration and
    // picture too — until the audio has opened. Measured on the bundled libmpv with the
    // audio's first byte held 3 s (`scratch/measure-audio-hold.ts`): `time-pos` stayed
    // unset for 3.04 s and then ran with the audio decoder already up; the old order had
    // the video at 3.0 s by the time the audio joined. A dead audio URL (404) is not fatal,
    // the video plays without it; one that stalls holds the open, which the 20 s wait below
    // ends and the loop retries without the audio.
    //
    // **The audio is the file, and the video is added to it (todo 103).** A video track that
    // is the file's own can be deselected but never removed, and a deselected one keeps
    // downloading (measured 2026-10-25, `scratch/measure-deselected.ts`: at the full rate, past
    // the size of its file), so a switch from 2160p to 360p would have gone on fetching 2160p.
    // An added track is removed with `video-remove`, and its download stops. So a separate
    // audio opens as the main file and `video-add` brings the picture; that also gives audio-only
    // a stream to select at load without the `vid=no` hack above. A live stream and a muxed
    // variant keep the old layout, and so does an audio URL that will not open: the video alone
    // plays, and the player says there is no sound.
    // The observers (`vid`, `seeking`) are what tells an add that worked from one that did not.
    await _trackObserversDone.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    var audioMain = audioUrl != null && !isLive && _trackObserversReady;
    var audioAtLoad = audioUrl != null && !audioMain;
    _audioMainOpen = false;
    _mediaLoaded = false;
    _addedVideoIds.clear();

    // Where an open spends its time, one line at the end (todo 103).
    final clock = Stopwatch()..start();
    var loadfileMs = 0;
    while (true) {
      await native.command(['change-list', 'audio-files', 'clr', '']);
      if (audioAtLoad) await native.command(['change-list', 'audio-files', 'append', audioUrl!]);
      if (audioMain) {
        // Paused until the picture is on it: a clock running before the video is added would
        // leave the new track behind it (see [_addVideo]).
        await native.setProperty('vid', 'auto');
        await _player.open(Media(audioUrl!), play: false);
      } else {
        await native.setProperty('vid', !_videoTrackEnabled && audioAtLoad ? 'no' : 'auto');
        await _player.open(Media(variant.videoUrl), play: wantPlay());
      }
      if (superseded.isCompleted) throw const OpenSuperseded();
      loadfileMs = clock.elapsedMilliseconds;
      if (_player.state.duration > Duration.zero) break;

      try {
        // **Whichever comes first: a duration, or mpv saying the stream is dead.**
        //
        // The wait alone is what made a failed open cost 21.8 s (F20). When the
        // video URL is refused, mpv reports `Failed to open …` on
        // `player.stream.error` within a second and then has nothing left to do —
        // no duration is ever coming, so the guard sat out its full 20 s waiting
        // for an event that the failure had already ruled out. The timeout is
        // still the backstop for a stream that is merely slow; this is the path
        // for one that is already over.
        //
        // Racing rather than replacing: mpv's error channel is not a reliable
        // *absence* signal — F18 needed both it and the log — so a duration
        // arriving still wins, and an error that turns out to be non-fatal costs
        // an open that would have failed anyway.
        await Future.any([
          _player.stream.duration.firstWhere((d) => d > Duration.zero),
          _player.stream.error.first.then((error) {
            throw StateError('mpv could not open the stream: $error');
          }),
          superseded.future.then((_) => throw const OpenSuperseded()),
        ]).timeout(const Duration(seconds: 20));
        break;
      } on TimeoutException {
        // Nothing ever arrived. With the audio in the way, the audio is the likelier
        // thing to be stuck, and a video without sound beats one that does not open.
        if (!audioAtLoad && !audioMain) rethrow;
        stderr.writeln('rill: no duration after 20 s with the audio ${audioMain ? 'as the file' : 'at load'}, opening without the audio');
        audioAtLoad = false;
        audioMain = false;
      } on StateError catch (e) {
        // The audio URL itself was refused. Only that is worth another try; a refused video
        // URL (the old layout) is the failure it always was.
        if (!audioMain) rethrow;
        stderr.writeln('rill: the audio would not open ($e), opening without the audio');
        audioMain = false;
      }
    }

    final durationMs = clock.elapsedMilliseconds;
    _mediaLoaded = true;
    _audioMainOpen = audioMain;

    if (audioMain) {
      // The picture. Audio-only has none to add; the audio is what plays.
      if (_videoTrackEnabled) {
        await _addVideo(variant.videoUrl);
        if (superseded.isCompleted) throw const OpenSuperseded();
      }
      if (wantPlay()) await _player.play();
    }

    // **Did the audio actually load?** mpv does not say: a dead audio URL is not fatal, so the
    // video opens and plays in silence, and the 20 s fallback above ends the same way. The
    // external audio is the file's only audio, so a real track in the list (an observed event,
    // never a property read) is the proof.
    var audioStatus = audioUrl == null ? 'none' : (audioMain ? 'file' : (audioAtLoad ? 'at load' : 'dropped'));
    // As the file, the audio is there by construction: the open would not have ended without it.
    if (audioUrl != null && !audioMain) {
      final loaded = audioAtLoad && await _audioTrackListed();
      if (superseded.isCompleted) throw const OpenSuperseded();
      if (!loaded) {
        audioStatus = audioAtLoad ? 'missing' : 'dropped';
        stderr.writeln('rill: the audio did not load ($audioStatus)');
        if (!_videoTrackEnabled) {
          // Audio-only has nothing else to play, and the video-only stream is not selected.
          await stop();
          throw const AudioUnavailable();
        }
        _setAudioMissing(true);
        // The list may only be late: if the audio appears after all, say so.
        _lateAudio = _player.stream.tracks.where(_hasAudioTrack).listen((_) => _setAudioMissing(false));
      }
    }

    if (isLive && _player.state.duration > Duration.zero) {
      await _player.seek(_player.state.duration);
    }

    // Back to what was asked for. Only a muxed variant (no separate audio at load), or
    // one that gave its audio up above, gets here with `vid=auto` while the app wants it off.
    if (!_videoTrackEnabled && !audioAtLoad && !audioMain) {
      await native.setProperty('vid', 'no');
    }

    // Once the duration is known: a subtitle attached to a file that has none yet is
    // the same race `audio-add` used to have (F15).
    if (retained != null) await setSubtitle(retained);
    // Cumulative, in the order they happen: the gap between two is the step.
    stderr.writeln(
      'rill: open ${variant.height}p timings (cumulative): loadfile ${loadfileMs}ms, '
      'duration ${durationMs}ms, done ${clock.elapsedMilliseconds}ms '
      '(audio=$audioStatus)',
    );
  }

  /// Completed by whatever overtakes the open in flight — see [OpenSuperseded].
  Completer<void>? _openSuperseded;

  void _supersedeOpen() {
    final pending = _openSuperseded;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  bool _audioMissing = false;
  final StreamController<bool> _audioMissingChanges = StreamController<bool>.broadcast();
  StreamSubscription<Tracks>? _lateAudio;

  @override
  bool get audioMissing => _audioMissing;

  @override
  Stream<bool> get audioMissingStream => _audioMissingChanges.stream;

  /// Every change goes through here, and clearing it also stops the wait for a late track.
  void _setAudioMissing(bool value) {
    if (!value) {
      unawaited(_lateAudio?.cancel());
      _lateAudio = null;
    }
    if (_audioMissing == value) return;
    _audioMissing = value;
    if (!_audioMissingChanges.isClosed) _audioMissingChanges.add(value);
  }

  /// How long the track list may trail the duration before the audio counts as missing.
  static const Duration _trackListGrace = Duration(seconds: 2);

  bool _hasAudioTrack(Tracks tracks) => tracks.audio.any((track) => track.id != 'auto' && track.id != 'no');

  /// Whether the external audio is in the track list, waiting a moment for the list itself:
  /// it is its own event and may land just after the duration. Costs the full grace only when
  /// the audio is really missing.
  Future<bool> _audioTrackListed() async {
    if (_hasAudioTrack(_player.state.tracks)) return true;
    try {
      await _player.stream.tracks.firstWhere(_hasAudioTrack).timeout(_trackListGrace);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Toggle mpv's video track on or off — see [PlaybackEngine.setVideoTrack].
  ///
  /// `vid=auto` lets mpv select the best video track (the only one on a
  /// single-file open). `vid=no` disables video decoding entirely — the demuxer
  /// still reads and the audio track keeps playing, but no frames are decoded
  /// or composited, saving CPU and letting the texture go blank.
  ///
  /// **This is a property write, not an `mpv_command`.** Same binding as
  /// `setProperty('stream-lavf-o', …)` in [_setStreamOptions], and the same
  /// reason invariant 9 does not apply: it writes one value and reads nothing.
  @override
  Future<void> setVideoTrack(bool enabled) async {
    trace?.call('setVideoTrack enabled=$enabled');
    final changed = _videoTrackEnabled != enabled;
    _videoTrackEnabled = enabled;
    // Before anything is open this only records the wish, which [open] reads.
    if (_mediaLoaded && _audioMainOpen) {
      // The video is an added track here, so off is a removal (its download stops, as `vid=no`
      // stopped the old one) and on is an add, brought to the clock's place.
      if (!enabled) {
        await _removeVideos(keep: null);
      } else if (changed || _addedVideoIds.isEmpty) {
        final variant = lastOpened;
        if (variant != null) await _addVideo(variant.videoUrl);
      }
      return;
    }
    await (_player.platform as NativePlayer).setProperty('vid', enabled ? 'auto' : 'no');
  }

  // --- The video as an added track (todo 103) ---

  /// The audio is the file mpv opened and the picture is added to it — see [open].
  bool _audioMainOpen = false;

  /// A file is loaded, so there is a clock to bring a new track to.
  bool _mediaLoaded = false;

  /// The video tracks this engine added and has not removed, by mpv's id. The last is the
  /// selected one. Kept here rather than read from the track list, which trails.
  final List<int> _addedVideoIds = [];

  /// mpv's `vid` and `seeking`, as observed events.
  String _vid = 'auto';
  bool _seeking = false;
  final StreamController<String> _vidChanges = StreamController<String>.broadcast();
  final StreamController<bool> _seekingChanges = StreamController<bool>.broadcast();
  bool _trackObserversReady = false;
  final Completer<void> _trackObserversDone = Completer<void>();

  Future<void> _observeTrackState() async {
    try {
      final native = _player.platform as NativePlayer;
      await native.observeProperty('vid', (value) async {
        _vid = value;
        if (!_vidChanges.isClosed) _vidChanges.add(value);
      });
      await native.observeProperty('seeking', (value) async {
        _seeking = value == 'yes';
        if (!_seekingChanges.isClosed) _seekingChanges.add(_seeking);
      });
      _trackObserversReady = true;
    } on Object catch (e) {
      stderr.writeln('rill: could not observe vid/seeking ($e) — the audio is not opened as the file');
    } finally {
      if (!_trackObserversDone.isCompleted) _trackObserversDone.complete();
    }
  }

  /// The observed `vid` and the video tracks this engine has added, **for diagnostics only**.
  String get diagnosticVid => _vid;
  List<int> get diagnosticAddedVideoIds => List<int>.unmodifiable(_addedVideoIds);

  /// A numeric `vid`: a selected track, as opposed to `no` or `auto`.
  int? _selectedVideoId() => int.tryParse(_vid);

  /// Adds [url] as a video track, selects it, and puts it where the clock is.
  ///
  /// **The seek is not optional.** The added track is read from its own start while the clock
  /// stands where it was, so without it the clock and the audio stop at the old position until
  /// something seeks (measured in the app on real DASH streams, 2026-10-25: 12 s and more of
  /// nothing; a pause toggle and selecting by hand did not help, a seek did). The wait is for
  /// that seek to finish, seen as `seeking` going true and false again, which is also the
  /// signal when paused, where the clock never moves. Throws when the track does not appear.
  Future<void> _addVideo(String url) async {
    final native = _player.platform as NativePlayer;
    final before = _selectedVideoId();
    await native.command(['video-add', url, 'select']);
    // The command returns normally for a URL that would not open (media_kit only logs it), so
    // a new numeric `vid` is the proof the track exists.
    final id = await _newVideoId(before);
    if (id == null) throw StateError('the video stream would not open');
    _addedVideoIds.add(id);
    // Read now, not before the command: the old track plays on while the new one is fetched
    // (up to several seconds), and a target taken at the start sent the clock back by that
    // much when the seek landed (reported 2026-10-25; the probe printed it and was misread).
    // The clock stands still from the moment the add ends, so this is where it is.
    await _seekAndWait(_position);
  }

  /// The id of the video track that is selected now and was not [before], waiting a moment for
  /// the event that says so. The command has returned by now, so the track exists or never will:
  /// the wait is only for the event to arrive (a refused URL cost 15 s here with a 10 s wait on
  /// top of the command's own 5).
  Future<int?> _newVideoId(int? before) async {
    bool fresh(String value) {
      final id = int.tryParse(value);
      return id != null && id != before;
    }

    if (fresh(_vid)) return int.parse(_vid);
    try {
      final value = await _vidChanges.stream.firstWhere(fresh).timeout(const Duration(seconds: 2));
      return int.parse(value);
    } on TimeoutException {
      return null;
    }
  }

  /// Seeks to [target] and returns when the seek has finished, which is also the signal when
  /// paused, where the clock never moves. Three ways to see it, because none is certain alone:
  /// `seeking` going true and then false; the clock passing [target] by 0.4 s (playing); and
  /// `seeking` never going true at all, for a seek that was over before an event could say so
  /// (one inside what is already read, such as to 0 on a new file), taken as finished when the
  /// command has returned and 0.4 s have gone by with it still false. Listening starts before
  /// the command, and after the add, so a seek of the viewer's own that ends in between cannot
  /// read as this one. Times out after 20 s with a [TimeoutException].
  Future<void> _seekAndWait(Duration target) async {
    final done = Completer<void>();
    var sawSeeking = false;
    Timer? settle;
    late final StreamSubscription<bool> seeking;
    late final StreamSubscription<Duration> position;
    void finish() {
      if (done.isCompleted) return;
      settle?.cancel();
      unawaited(seeking.cancel());
      unawaited(position.cancel());
      done.complete();
    }

    seeking = _seekingChanges.stream.listen((value) {
      if (value) sawSeeking = true;
      if (!value && sawSeeking) finish();
    });
    position = _player.stream.position.listen((value) {
      if (_playing && value > target + const Duration(milliseconds: 400)) finish();
    });
    try {
      await _player.seek(target);
      settle = Timer(const Duration(milliseconds: 400), () {
        if (!sawSeeking && !_seeking) finish();
      });
      await done.future.timeout(const Duration(seconds: 20));
    } finally {
      settle?.cancel();
      await seeking.cancel();
      await position.cancel();
    }
  }

  /// `video-remove` for every added track but [keep], which is what stops their downloads.
  Future<void> _removeVideos({required int? keep}) async {
    final native = _player.platform as NativePlayer;
    for (final id in List<int>.of(_addedVideoIds)) {
      if (id == keep) continue;
      await native.command(['video-remove', '$id']);
      _addedVideoIds.remove(id);
    }
  }

  @override
  bool canSwitchVideo(PlaybackVariant variant) {
    final current = lastOpened;
    return _trackObserversReady &&
        _mediaLoaded &&
        _audioMainOpen &&
        current != null &&
        variant.audioUrl != null &&
        variant.audioUrl == current.audioUrl;
  }

  @override
  Future<VideoSwitch> switchVideo(PlaybackVariant variant) async {
    if (!canSwitchVideo(variant)) return VideoSwitch.unsupported;
    trace?.call('switchVideo ${variant.height}p');
    // Audio-only: nothing is showing, so the choice is only recorded and the add that brings
    // the video back uses it.
    if (!_videoTrackEnabled) {
      lastOpened = variant;
      return VideoSwitch.done;
    }
    final native = _player.platform as NativePlayer;
    final before = _selectedVideoId();
    await native.command(['video-add', variant.videoUrl, 'select']);
    final id = await _newVideoId(before);
    if (id == null) {
      // Refused: the old track is still the selected one and keeps playing.
      return VideoSwitch.refused;
    }
    _addedVideoIds.add(id);
    lastOpened = variant;
    try {
      // Where the clock is now, not where it was when the switch began — see [_addVideo].
      await _seekAndWait(_position);
    } on TimeoutException {
      return VideoSwitch.refused;
    }
    // Every other track goes, not just the one this switch replaced: a switch that was cut
    // short leaves its own behind, and each one left is a download.
    await _removeVideos(keep: id);
    return VideoSwitch.done;
  }

  /// What the app last asked for, which [open] honours rather than overriding.
  ///
  /// `vid` persists across `loadfile` — it is an option, not per-file state — so
  /// this is also the value mpv would use anyway. Tracked here because [open]
  /// has to *choose* how to load around it, not just inherit it.
  bool _videoTrackEnabled = true;

  @override
  Future<void> play() {
    trace?.call('play');
    return _player.play();
  }

  @override
  Future<void> pause() {
    trace?.call('pause');
    return _player.pause();
  }

  @override
  Future<void> playOrPause() {
    trace?.call('playOrPause (kit playing=${_player.state.playing})');
    return _player.playOrPause();
  }

  @override
  Future<void> seek(Duration to) {
    trace?.call('seek ${to.inMilliseconds}ms');
    return _player.seek(to);
  }

  @override
  Future<void> setVolume(double volume) {
    trace?.call('setVolume $volume');
    return _player.setVolume(volume);
  }

  /// mpv's own `frame-step` / `frame-back-step`.
  ///
  /// **This is not the property read hard invariant 9 forbids.** That rule is
  /// about *polling* `getProperty` from the UI isolate — a blocking read that can
  /// sit on mpv's core lock (F15 recorded a 6.4 s freeze). This writes: it is one
  /// `mpv_command` per key press, the same call `Player.seek` and `Player.play`
  /// already make through this binding, and it reads nothing back.
  ///
  /// Both commands pause as a side effect. That is mpv's behaviour and also
  /// YouTube's — frame stepping is something done to a still picture — so it is
  /// left alone rather than papered over with a `play()` afterwards.
  ///
  /// `frame-back-step` is documented as slow and best-effort: it seeks precisely
  /// and can miss. Nothing above this depends on it landing exactly, and the
  /// alternative — refusing to bind the key — is worse than an occasional
  /// two-frame jump.
  @override
  Future<void> stepFrame(int direction) {
    trace?.call('stepFrame $direction');
    return (_player.platform as NativePlayer).command([direction < 0 ? 'frame-back-step' : 'frame-step']);
  }

  @override
  Future<void> stop() {
    trace?.call('stop');
    _supersedeOpen();
    _setAudioMissing(false);
    _mediaLoaded = false;
    _audioMainOpen = false;
    _addedVideoIds.clear();
    return _player.stop();
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _lateAudio?.cancel();
    await _audioMissingChanges.close();
    await _vidChanges.close();
    await _seekingChanges.close();
    await _videoOutput.close();
    await _player.dispose();
  }
}
