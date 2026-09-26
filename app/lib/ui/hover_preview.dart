/// Hover previews — the real video, muted, played in the tile. `architecture.md` §2.6 has the
/// decision and what it replaced; `protocol.md` §3.7 has the RPC contract.
///
/// **One shared preview player, never one per tile**, and a *different* engine from the shell's:
/// the shell's holds a paused video's position and its texture, which is exactly what
/// "preview over a paused video" must not disturb.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/caption_track.dart';
import '../domain/playback_source.dart';

/// Resolve a video to something playable. `playback.open {preload: true}`.
typedef PreviewResolver = Future<PlaybackSource> Function(String videoId);

/// Open a **reportable** session — `playback.open` without preload. Separate from
/// [PreviewResolver] on purpose; see [HoverPreview.watchThreshold].
typedef PreviewSessionOpener = Future<String?> Function(String videoId);

/// One `playback.report`, or the `playback.close` that ends a promoted session.
typedef PreviewReporter = Future<void> Function(String sessionId, int positionMs, String state);
typedef PreviewSessionCloser = Future<void> Function(String sessionId);

/// The hovered video's caption tracks, from the cached `/player` only.
typedef PreviewCaptionLister = Future<List<CaptionTrack>> Function(String videoId);

/// One track as an ASS document, fetched only when the CC button is pressed.
typedef PreviewCaptionFetcher = Future<String?> Function(String videoId, String trackId);

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

Future<PlaybackSource> _resolveOverRpc(String videoId) async {
  // `preload: true` is load-bearing (§3.7): the sessionId it returns is not reportable, which
  // makes "a hover is not a watch" structural rather than a rule to remember.
  final response = await RpcClient.instance.call('playback.open', {
    'videoId': videoId,
    'preload': true,
  });
  return PlaybackSource.fromJson(response as Map<String, dynamic>);
}

/// The track list for a hovered video, from the cached tier-1 `/player` only.
///
/// `allowFallback: false` is the whole point (`protocol.md` §3.8): the preload
/// that resolved this preview already fetched and cached that response, so this
/// costs no request to YouTube — while the full list may cost a second
/// `/player`, and a pointer sweeping a grid would spend one per tile. The price
/// is that the CC toggle is absent on the minority of videos only the fallback
/// would have found tracks for, which on a muted thumbnail preview is the right
/// side to err on.
Future<List<CaptionTrack>> _captionsOverRpc(String videoId) async {
  final response = await RpcClient.instance.call('captions.list', {
    'videoId': videoId,
    'allowFallback': false,
  });
  return [
    for (final entry in (response as Map)['tracks'] as List<dynamic>)
      CaptionTrack.fromJson((entry as Map).cast<String, Object?>()),
  ];
}

Future<String?> _captionContentOverRpc(String videoId, String trackId) async {
  final response = await RpcClient.instance.call('captions.get', {
    'videoId': videoId,
    'trackId': trackId,
  });
  return CaptionTrackContent.fromJson((response as Map).cast<String, Object?>()).content;
}

Future<String?> _openSessionOverRpc(String videoId) async {
  // No `preload`, so this one is registered and reportable. Its `/player` response is already
  // cached from the preload, so it costs one RPC round trip and no request to YouTube.
  final response = await RpcClient.instance.call('playback.open', {'videoId': videoId});
  return PlaybackSource.fromJson(response as Map<String, dynamic>).sessionId;
}

Future<void> _reportOverRpc(String sessionId, int positionMs, String state) async {
  await RpcClient.instance.call('playback.report', {
    'sessionId': sessionId,
    'positionMs': positionMs,
    'state': state,
  });
}

Future<void> _closeOverRpc(String sessionId) async {
  await RpcClient.instance.call('playback.close', {'sessionId': sessionId});
}

// ---------------------------------------------------------------------------
// What a tile is showing
// ---------------------------------------------------------------------------

/// The preview state of one tile. `null` in every tile that is not previewing.
@immutable
class PreviewSession {
  const PreviewSession({
    required this.videoId,
    required this.engine,
    required this.muted,
    required this.visible,
    this.captionTrack,
    this.captionsOn = false,
  });

  final String videoId;
  final PlaybackEngine engine;
  final bool muted;

  /// The track the CC button would turn on, or null when the video has none —
  /// in which case the button is not drawn at all.
  ///
  /// One track, not a list: a thumbnail-sized preview is no place for a language
  /// picker, so the toggle offers the video's first track and the watch page is
  /// where a language is chosen.
  final CaptionTrack? captionTrack;

  final bool captionsOn;

  /// Whether mpv has produced a frame yet. The tile keeps its thumbnail until it has, so a
  /// slow open never shows a black rectangle.
  final bool visible;

  PreviewSession copyWith({bool? muted, bool? visible}) => PreviewSession(
        videoId: videoId,
        engine: engine,
        muted: muted ?? this.muted,
        visible: visible ?? this.visible,
        captionTrack: captionTrack,
        captionsOn: captionsOn,
      );
}

/// A tile's slot for its own preview. Every tile owns one and [HoverPreview] writes to at most
/// one at a time — which is why this is not a single `ChangeNotifier` the whole grid listens to.
typedef PreviewSink = ValueNotifier<PreviewSession?>;

// ---------------------------------------------------------------------------

/// The one hover-preview surface: one delay, one engine, one active tile.
class HoverPreview {
  HoverPreview({
    required this.engineFactory,
    required this.shell,
    required this.isAudioOnly,
    PreviewResolver? resolve,
    PreviewSessionOpener? openSession,
    PreviewReporter? report,
    PreviewSessionCloser? closeSession,
    PreviewCaptionLister? captionList,
    PreviewCaptionFetcher? captionContent,
    this.delay = hoverDelay,
  })  : _resolve = resolve ?? _resolveOverRpc,
        _openSession = openSession ?? _openSessionOverRpc,
        _report = report ?? _reportOverRpc,
        _closeSession = closeSession ?? _closeOverRpc,
        _captionList = captionList ?? _captionsOverRpc,
        _captionContent = captionContent ?? _captionContentOverRpc {
    // Not just a guard on `enter`: the user can hit play in the mini-player with the pointer
    // already resting on a tile, and two decoders at once is what F16 says this cannot afford.
    _shellSubscription = shell.playingStream.listen((playing) {
      if (playing) stop();
    });
  }

  /// How long a hover must last before a stream is resolved. Long, deliberately: this opens a
  /// video, so only a hover somebody meant should do it (§2.6).
  static const Duration hoverDelay = Duration(milliseconds: 800);

  /// The tallest variant a preview will take. F16: 2160p60 dropped 16–29% of frames on an
  /// Intel iGPU for the video the user actually chose — a thumbnail has none of that budget.
  static const int maxPreviewHeight = 720;

  /// **A preview that runs this long stops being a preview** and promotes itself to a reported
  /// watch (§3.7). Long enough that a pointer parked on a tile is not a view, short enough that
  /// anything deliberate is one — and a watch that never reports is one the recommender never
  /// learns from, which is the failure `playback.report` exists to prevent.
  static const Duration watchThreshold = Duration(seconds: 30);

  /// The §3.5 report cadence once promoted.
  @visibleForTesting
  static Duration reportInterval = const Duration(seconds: 15);

  /// The shell's engine — read for suppression, never opened or stopped.
  final PlaybackEngine shell;
  final Duration delay;
  final bool Function() isAudioOnly;

  /// Builds the preview engine, at most once and only when a preview starts.
  final PlaybackEngine Function() engineFactory;
  final PreviewResolver _resolve;
  final PreviewSessionOpener _openSession;
  final PreviewReporter _report;
  final PreviewSessionCloser _closeSession;

  PlaybackEngine? _engine;

  /// The generation currently using [_engine]. A `_start` whose `open()` finally returns after
  /// the pointer moved on must only stop the engine if nothing newer has taken it over.
  int _engineOwner = -1;
  StreamSubscription<bool>? _shellSubscription;
  final List<StreamSubscription<Object?>> _engineSubscriptions = [];

  Timer? _delayTimer;
  Timer? _reportTimer;

  String? _pendingId;
  String? _activeId;
  PreviewSink? _sink;
  final PreviewCaptionLister _captionList;
  final PreviewCaptionFetcher _captionContent;

  bool _muted = true;

  /// The hovered video's first caption track, once the free list has answered.
  CaptionTrack? _captionTrack;
  bool _captionsOn = false;

  /// The reportable session, once the preview has outlived [watchThreshold].
  String? _sessionId;
  bool _promoting = false;

  /// Bumped on every enter and stop, so a resolution landing after the pointer moved on cannot
  /// install itself over whatever is current.
  int _generation = 0;

  @visibleForTesting
  String? get activeVideoId => _activeId;
  @visibleForTesting
  bool get isWaiting => _delayTimer?.isActive ?? false;
  @visibleForTesting
  String? get reportingSessionId => _sessionId;
  @visibleForTesting
  bool get isMuted => _muted;

  /// Whether a preview may start at all right now. Playing suppresses; paused does not (§2.6).
  bool get isSuppressed => isAudioOnly() || shell.playing;

  /// The pointer entered a tile. Nothing happens for [delay].
  void enter(String videoId, PreviewSink sink) {
    if (isSuppressed) return;
    if (_activeId == videoId && identical(_sink, sink)) return;
    if (_pendingId == videoId) return;

    stop();
    _pendingId = videoId;
    final generation = _generation;
    _delayTimer = Timer(delay, () {
      if (generation != _generation) return;
      _delayTimer = null;
      unawaited(_start(videoId, sink, generation));
    });
  }

  /// The pointer left a tile — during the delay or mid-playback, both count.
  void exit(String videoId) {
    if (_pendingId != videoId && _activeId != videoId) return;
    stop();
  }

  /// Turn the preview's captions on or off.
  ///
  /// **A preview is muted by default, so this is the control that makes one
  /// legible** — which is why it earns a place in a cluster deliberately kept to
  /// two buttons. It costs one `timedtext` fetch on the *first* press for a
  /// video and nothing after that (the sidecar caches the rendered ASS), and
  /// nothing at all if it is never pressed: the list that decides whether to
  /// draw the button is read from a `/player` response the preload already
  /// cached. Hovering a grid of tiles issues no extra request to YouTube.
  Future<void> toggleCaptions() async {
    final engine = _engine;
    final track = _captionTrack;
    final videoId = _activeId;
    if (engine == null || track == null || videoId == null) return;

    final generation = _generation;
    if (_captionsOn) {
      _captionsOn = false;
      _push();
      unawaited(engine.setSubtitle(null));
      return;
    }

    // Icon first, like the mute toggle: the fetch can take a moment and a button
    // that waits for it before redrawing reads as an unresponsive one.
    _captionsOn = true;
    _push();
    try {
      final ass = await _captionContent(videoId, track.id);
      // A pointer that moved on took the engine with it. Attaching now would put
      // this video's words over whichever preview is running instead.
      if (generation != _generation || !_captionsOn) return;
      await engine.setSubtitle(ass);
    } on Object catch (error) {
      // Silent, like every other preview failure: the answer to "no captions on
      // a thumbnail" is the thumbnail, never an error state on a tile nobody
      // clicked.
      stderr.writeln('preview $videoId: captions unavailable ($error)');
      if (generation != _generation) return;
      _captionsOn = false;
      _push();
    }
  }

  /// Mute or unmute the running preview. The tile's one hover control.
  Future<void> toggleMute() async {
    final engine = _engine;
    if (engine == null || _activeId == null) return;
    _muted = !_muted;
    // Icon first, volume second: `setVolume` crosses a platform channel, and a button that
    // waits for it before redrawing reads as an unresponsive one.
    _push();
    unawaited(engine.setVolume(_muted ? 0 : 100));
  }

  // -------------------------------------------------------------------------

  Future<void> _start(String videoId, PreviewSink sink, int generation) async {
    // Again, not only in `enter`: 800 ms is long enough to have started something meanwhile.
    if (isSuppressed) return;

    PlaybackSource source;
    try {
      source = await _resolve(videoId);
    } on Object catch (error) {
      // Silent to the user: the answer to "no preview" is the thumbnail already on screen,
      // never an error state on a tile nobody clicked.
      stderr.writeln('preview $videoId: not resolvable ($error)');
      return;
    }
    if (generation != _generation || isSuppressed) return;

    final variant = pickPreviewVariant(source.variants);
    if (variant == null) {
      stderr.writeln('preview $videoId: no variant at or under ${maxPreviewHeight}p');
      return;
    }

    final engine = _engine ??= engineFactory();

    _activeId = videoId;
    _sink = sink;
    _muted = true;
    _captionTrack = null;
    _captionsOn = false;
    _engineOwner = generation;

    // Off the critical path on purpose: the preview opens whether or not this
    // ever answers, and the CC button simply appears when it does.
    unawaited(() async {
      try {
        final tracks = await _captionList(videoId);
        if (generation != _generation || tracks.isEmpty) return;
        _captionTrack = tracks.first;
        _push();
      } on Object catch (error) {
        stderr.writeln('preview $videoId: caption list unavailable ($error)');
      }
    }());

    // Muted before opening, and **not awaited**. Measured 2026-08-11: `setVolume` on a freshly
    // constructed engine never completes — media_kit resolves it against a platform that is only
    // ready once the player has media, so awaiting here deadlocks the preview before it opens
    // anything, with no error. Unawaited it still lands, well before `open` attaches audio.
    unawaited(engine.setVolume(0));
    if (generation != _generation) {
      _activeId = null;
      _sink = null;
      return;
    }

    // Not visible yet — the tile keeps its thumbnail until there is a frame.
    _push();
    _watchForFirstFrame(engine, generation);

    try {
      await engine.open(variant);
    } on Object catch (error) {
      stderr.writeln('preview $videoId: would not open ($error)');
      if (generation == _generation) stop();
      return;
    }
    if (generation != _generation) {
      // Only if a newer preview has not taken the engine over. `open()` can return long after
      // the pointer moved on — media_kit waits up to 20 s for a duration — and stopping here
      // unconditionally kills whatever the user is hovering *now*. Doing nothing is equally
      // wrong: `stop()` ran while this open was still in flight, so without this the stream
      // would start playing behind a tile that is no longer previewing.
      if (_engineOwner == generation) unawaited(engine.stop());
      return;
    }

    // The platform is up now, so this one confirms the mute rather than merely requesting it,
    // and honours a toggle made while the stream was opening.
    unawaited(engine.setVolume(_muted ? 0 : 100));
  }

  /// Reveal the surface on the first sign that mpv is decoding, and promote the
  /// preview to a watch once it has run past [watchThreshold].
  void _watchForFirstFrame(PlaybackEngine engine, int generation) {
    _cancelEngineSubscriptions();
    _engineSubscriptions.addAll([
      // Two first-frame signals, because neither is reliable alone: mpv can report a position
      // before it clears buffering on a fast start, and the reverse on a slow one.
      engine.positionStream.listen((position) {
        if (generation != _generation) return;
        if (position > Duration.zero) _reveal();
        if (position >= watchThreshold) unawaited(_promoteToWatch());
      }),
      engine.bufferingStream.listen((buffering) {
        if (generation != _generation) return;
        if (!buffering && engine.playing) _reveal();
      }),
      // The video ran out: tear down exactly as a pointer leaving would (§2.6). `stop()` is the
      // whole implementation on purpose — "ended" and "left" must not become two paths that
      // drift. It does not loop or restart: `enter` only fires on a real crossing, so the
      // preview stays down until the pointer leaves and comes back.
      engine.completedStream.listen((completed) {
        if (!completed || generation != _generation) return;
        stop(finalState: 'ended');
      }),
    ]);
  }

  void _reveal() {
    final current = _sink?.value;
    if (current == null || current.visible) return;
    _sink!.value = current.copyWith(visible: true);
  }

  /// Turn a long-running preview into a reported watch ([watchThreshold]). Guarded because the
  /// position stream fires several times a second, all of them past the threshold once one is.
  Future<void> _promoteToWatch() async {
    if (_sessionId != null || _promoting) return;
    final videoId = _activeId;
    if (videoId == null) return;

    _promoting = true;
    final generation = _generation;
    try {
      final sessionId = await _openSession(videoId);
      if (sessionId == null) return;
      if (generation != _generation) {
        // Aborted while this was in flight. The session was registered and nothing else knows
        // about it, so close it here or it lingers against the §5 cap for nothing.
        unawaited(_closeSession(sessionId));
        return;
      }
      _sessionId = sessionId;

      // Immediately, not on the first tick: this is the report that registers the view at all.
      unawaited(_sendReport('playing'));
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(reportInterval, (_) => unawaited(_sendReport(null)));
    } on Object catch (error) {
      stderr.writeln('preview $videoId: could not promote to a watch ($error)');
    } finally {
      _promoting = false;
    }
  }

  Future<void> _sendReport(String? state, {String? sessionId, int? positionMs}) async {
    final id = sessionId ?? _sessionId;
    if (id == null) return;
    final engine = _engine;
    final resolved = state ?? ((engine?.playing ?? false) ? 'playing' : 'paused');
    try {
      await _report(id, positionMs ?? engine?.position.inMilliseconds ?? 0, resolved);
    } on Object catch (error) {
      // Never retried — the next tick carries a superset of this segment. Logged, because a
      // client that has quietly stopped reporting is a failure nothing else surfaces.
      stderr.writeln('preview playback.report failed: $error');
    }
  }

  /// Stop everything and hand the tile back its thumbnail. [finalState] is what a *promoted*
  /// preview reports on the way out — `paused` for a pointer leaving, `ended` for a video that
  /// ran out (§3.7).
  void stop({String finalState = 'paused'}) {
    _generation++;
    _delayTimer?.cancel();
    _delayTimer = null;
    _pendingId = null;
    _cancelEngineSubscriptions();

    final sessionId = _sessionId;
    final positionMs = _engine?.position.inMilliseconds ?? 0;
    _reportTimer?.cancel();
    _reportTimer = null;
    _sessionId = null;

    _sink?.value = null;
    _sink = null;
    _activeId = null;
    _muted = true;
    _captionTrack = null;
    _captionsOn = false;

    if (_engine != null) unawaited(_engine!.stop());

    // Both use values captured *before* the engine was stopped: read afterwards, the position
    // is zero and a twenty-minute watch reports as nothing.
    if (sessionId != null) {
      unawaited(() async {
        await _sendReport(finalState, sessionId: sessionId, positionMs: positionMs);
        try {
          await _closeSession(sessionId);
        } on Object catch (error) {
          stderr.writeln('preview playback.close failed: $error');
        }
      }());
    }
  }

  void _push() {
    final sink = _sink;
    final engine = _engine;
    final videoId = _activeId;
    if (sink == null || engine == null || videoId == null) return;
    sink.value = PreviewSession(
      videoId: videoId,
      engine: engine,
      muted: _muted,
      visible: sink.value?.visible ?? false,
      captionTrack: _captionTrack,
      captionsOn: _captionsOn,
    );
  }

  void _cancelEngineSubscriptions() {
    for (final subscription in _engineSubscriptions) {
      unawaited(subscription.cancel());
    }
    _engineSubscriptions.clear();
  }

  Future<void> dispose() async {
    stop();
    await _shellSubscription?.cancel();
    _shellSubscription = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) await engine.dispose();
  }
}

/// The best variant at or under [HoverPreview.maxPreviewHeight]. `variants` is ranked
/// best-first, so the first match wins; when nothing fits, the *smallest* rung does — taking
/// the top would be the worst possible answer.
@visibleForTesting
PlaybackVariant? pickPreviewVariant(List<PlaybackVariant> variants) {
  if (variants.isEmpty) return null;
  for (final variant in variants) {
    if (variant.height <= HoverPreview.maxPreviewHeight) return variant;
  }
  return variants.last;
}

// ---------------------------------------------------------------------------
// Scope
// ---------------------------------------------------------------------------

/// Hands [HoverPreview] down to the tiles. **Absence disables previews**, deliberately: a tile
/// built outside a scope issues no RPC and starts no mpv, which is what keeps every other tile
/// test from doing either.
class HoverPreviewScope extends InheritedWidget {
  const HoverPreviewScope({super.key, required this.preview, required super.child});

  final HoverPreview preview;

  static HoverPreview? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HoverPreviewScope>()?.preview;

  @override
  bool updateShouldNotify(HoverPreviewScope oldWidget) => !identical(preview, oldWidget.preview);
}

/// Owns a [HoverPreview] for the lifetime of a subtree. [engineFactory] is called at most once
/// and only when a preview actually starts, so a user who never hovers pays for no second mpv.
class HoverPreviewScopeHost extends StatefulWidget {
  const HoverPreviewScopeHost({
    super.key,
    required this.shell,
    required this.isAudioOnly,
    required this.engineFactory,
    required this.child,
  });

  final PlaybackEngine shell;
  final bool Function() isAudioOnly;
  final PlaybackEngine Function() engineFactory;
  final Widget child;

  @override
  State<HoverPreviewScopeHost> createState() => _HoverPreviewScopeHostState();
}

class _HoverPreviewScopeHostState extends State<HoverPreviewScopeHost> {
  late final HoverPreview _preview = HoverPreview(
    shell: widget.shell,
    isAudioOnly: widget.isAudioOnly,
    engineFactory: widget.engineFactory,
  );

  @override
  void dispose() {
    unawaited(_preview.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      HoverPreviewScope(preview: _preview, child: widget.child);
}
