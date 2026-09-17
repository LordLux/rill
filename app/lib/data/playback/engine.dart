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

  /// [retainSubtitle] puts the attached track back after the media reopens.
  ///
  /// A quality switch reopens the media (F19) and mpv drops external subtitle
  /// tracks with it. Opening a *different video* must not carry the previous
  /// one's captions, so this is opt-in and only `switchQuality` passes it.
  Future<void> open(PlaybackVariant variant, {bool play = true, bool retainSubtitle = false, bool isLive = false});
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
  Future<void> stop();

  Future<void> dispose();
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
  Future<void> open(PlaybackVariant variant, {bool play = true, bool retainSubtitle = false, bool isLive = false}) async {
    lastOpened = variant;
    trace?.call('open ${variant.height}p play=$play live=$isLive audio=${variant.audioUrl != null}');
    // Read before the open, applied after it. A reopen drops mpv's external
    // subtitle tracks, and this is the only place that knows one was attached.
    final retained = retainSubtitle ? _subtitle : null;
    _subtitle = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffer = Duration.zero;
    // Cleared rather than left: this is what the quality menu reads as "actually
    // playing", and a stale height from the *previous* variant would keep
    // claiming the old one for as long as it took the first frame to decode —
    // which is precisely the window a user watches after switching.
    _width = null;
    _height = null;

    await _player.open(Media(variant.videoUrl), play: play);

    if (_player.state.duration <= Duration.zero) {
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
      ]).timeout(const Duration(seconds: 20));
    }

    if (isLive && _player.state.duration > Duration.zero) {
      await _player.seek(_player.state.duration);
    }

    final audioUrl = variant.audioUrl;
    if (audioUrl == null) {
      if (retained != null) await setSubtitle(retained);
      return;
    }

    await _player.setAudioTrack(AudioTrack.uri(audioUrl, title: 'YouTube audio'));
    // After the audio, not before: both go through `sub-add`/`audio-add` against
    // a freshly loaded file, and attaching a subtitle to a file whose duration is
    // not known yet is the same race the audio wait above exists for.
    if (retained != null) await setSubtitle(retained);
  }

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
    return _player.stop();
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
  }
}
