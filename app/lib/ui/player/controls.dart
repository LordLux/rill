/// The shell player's control overlay.
///
/// One widget, two mount points: inside the watch page's 16:9 box, and
/// full-window above the `Navigator` when fullscreen. It never builds a video
/// surface of its own — it draws *over* whichever one the caller mounted, so a
/// mode change moves the controls and leaves the texture alone.
///
/// **Two constraints shape the whole file.** Everything the scrubber reads comes
/// off `player.stream.*` and never `getProperty` (hard invariant 9, F15: a
/// blocking FFI read on the UI isolate sat on mpv's core lock for 6.4 s). And
/// nothing here may use a tooltip, a `PopupMenuButton` or any other route: at
/// the fullscreen mount point this widget is *above* the `Navigator`, so there
/// is no `Overlay` and no `Navigator` to host one. The quality menu is therefore
/// a panel in this `Stack` rather than a popup.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent, PointerSignalEvent, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playback/engine.dart';
import '../../domain/playback_source.dart';
import '../../theme/tokens.dart';
import '../playback_controller.dart';
import '../player_shell.dart';
import '../queue_controller.dart';
import 'shortcuts.dart' show volumeStep;
import 'view_mode.dart';

/// How long the pointer must be still before the controls go away.
const Duration autoHideDelay = Duration(seconds: 1);

/// How close two clicks have to be to count as one double click.
///
/// Flutter's own `kDoubleTapTimeout`. Named here because it is load-bearing
/// rather than incidental — see [_PlayerControlsState._onTap].
const Duration doubleClickWindow = kDoubleTapTimeout;

/// The bar, for tests that need to read its opacity rather than infer it.
const Key playerControlsBarKey = ValueKey('player-controls-bar');
const Key playerScrubberKey = ValueKey('player-scrubber');
const Key playerQualityButtonKey = ValueKey('player-quality-button');
const Key playerQualityMenuKey = ValueKey('player-quality-menu');
const Key playerQualityAutoKey = ValueKey('player-quality-auto');
const Key playerSwitchCoverKey = ValueKey('player-switch-cover');
const Key playerBusySpinnerKey = ValueKey('player-busy-spinner');

/// How long the player must be busy before the spinner appears.
///
/// **A grace period, not a delay for its own sake.** Most seeks resolve fast
/// enough that an immediate spinner is a flash — a control that appears and
/// vanishes inside a couple of frames reads as a glitch, not as feedback. F18
/// puts seeks at 0.36–4.6 s, so this catches the ones that make anybody wait and
/// stays out of the way of the ones that do not.
const Duration busySpinnerDelay = Duration(milliseconds: 250);

/// How long the volume slider stays open after the pointer leaves it.
const Duration volumeSliderHideDelay = Duration(milliseconds: 200);

Duration _fadeDuration(bool visible) => visible ? const Duration(milliseconds: 150) : const Duration(milliseconds: 400);

const Key playerPreviousKey = ValueKey('player-previous');
const Key playerNextKey = ValueKey('player-next');
const Key playerPlayPauseKey = ValueKey('player-play-pause');
const Key playerMuteKey = ValueKey('player-mute');
const Key playerVolumeSliderKey = ValueKey('player-volume-slider');
const Key playerCaptionsKey = ValueKey('player-captions');
const Key playerMiniPlayerKey = ValueKey('player-mini-player');
const Key playerTheatreKey = ValueKey('player-theatre');
const Key playerFullscreenKey = ValueKey('player-fullscreen');

class PlayerControls extends ConsumerStatefulWidget {
  const PlayerControls({super.key, required this.engine});

  final PlaybackEngine engine;

  @override
  ConsumerState<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends ConsumerState<PlayerControls> {
  bool _visible = true;
  bool _playing = false;
  bool _qualityOpen = false;
  Timer? _hideTimer;
  StreamSubscription<bool>? _playingSubscription;

  /// The scrubber mid-drag. Null when the thumb is not held.
  double? _dragging;

  /// Open for as long as a second click would still count as a double.
  ///
  /// A `Timer` rather than a recorded `DateTime`, and the difference is not
  /// stylistic: `DateTime.now()` is the wall clock, which a widget test's fake
  /// clock never advances — so a timestamp comparison makes every pair of clicks
  /// in every test a double click, however much simulated time passes between
  /// them. A timer is driven by the same clock the test pumps.
  Timer? _doubleClickWindow;

  /// What the play state was before the click, for the undo below.
  bool _playingBeforeTap = false;

  @override
  void initState() {
    super.initState();
    _playing = widget.engine.playing;
    _playingSubscription = widget.engine.playingStream.listen((playing) {
      if (!mounted || playing == _playing) return;
      setState(() => _playing = playing);
      // Pausing brings the controls back and keeps them; playing starts the
      // countdown. Both are the same rule read from the two directions.
      _restartHideTimer();
    });
    _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _doubleClickWindow?.cancel();
    unawaited(_playingSubscription?.cancel());
    super.dispose();
  }

  /// The auto-hide rule, in one place.
  ///
  /// Hides only while **playing**, only after [autoHideDelay], and never while
  /// the quality menu is open — a menu that vanishes from under the pointer is
  /// worse than one that overstays.
  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_playing || _qualityOpen) {
      if (!_visible) setState(() => _visible = true);
      return;
    }
    _hideTimer = Timer(autoHideDelay, () {
      if (!mounted) return;
      setState(() => _visible = false);
    });
  }

  void _wake() {
    if (!_visible) setState(() => _visible = true);
    _restartHideTimer();
  }

  /// Click, and the double-click that may or may not be arriving.
  ///
  /// Click toggles play/pause and double-click toggles fullscreen, which
  /// conflict. The obvious fix — hold every click for the ~250 ms double-click
  /// window to see whether a second follows — is what `GestureDetector`'s own
  /// `onTap` + `onDoubleTap` pair does, and it makes **every** pause feel
  /// broken: the video keeps playing for a quarter of a second after the user
  /// has already clicked it.
  ///
  /// So the first click acts immediately, and a second click within the window
  /// *undoes* it and goes fullscreen instead. The undo restores the recorded
  /// pre-click play state rather than toggling again, because two toggles are
  /// only a no-op if the first one has finished landing (see
  /// `PlaybackController.setPlaying`).
  void _onTap() {
    _wake();
    final playback = ref.read(playbackProvider.notifier);

    if (_doubleClickWindow?.isActive ?? false) {
      // Closed rather than left to expire: a third click starts a fresh single
      // click, so a triple does not read as two overlapping doubles.
      _doubleClickWindow!.cancel();
      _doubleClickWindow = null;
      unawaited(playback.setPlaying(_playingBeforeTap));
      ref.read(playerViewProvider.notifier).toggleFullscreen();
      return;
    }

    _playingBeforeTap = widget.engine.playing;
    // Immediately. The window opens *after* the action, not instead of it.
    unawaited(playback.togglePlayPause());
    _doubleClickWindow = Timer(doubleClickWindow, () => _doubleClickWindow = null);
  }

  /// Shift + scroll — volume.
  ///
  /// Plain scroll is deliberately left alone: over a player embedded in a
  /// scrolling page, a bare wheel has to scroll the page.
  ///
  /// **Claimed through the `pointerSignalResolver` rather than merely read**,
  /// which is the contract for handling a pointer signal at all — the resolver
  /// exists so exactly one handler acts on each one, and it hands the event to
  /// the first registrant. This is that one: signals dispatch leaf-first and the
  /// watch page's `ListView` is an ancestor.
  ///
  /// **What that is *not* load-bearing for, measured rather than assumed:** the
  /// page does not scroll under a shift-scroll even without this. Flutter's
  /// `Scrollable` flips its axis while a shift key is down and then reads
  /// `scrollDelta.dx`, which a vertical wheel leaves at zero — so removing the
  /// registration changes nothing observable here, and the test that asserts the
  /// page stayed put passes either way. Registering is still right: it stops
  /// being a coincidence the moment anything horizontal is in the ancestry.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isShiftPressed) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _wake();
      // Scrolling *up* is a negative `dy` on every platform Flutter reports one
      // for, and up is louder.
      final delta = event.scrollDelta.dy > 0 ? -volumeStep : volumeStep;
      unawaited(ref.read(playbackProvider.notifier).nudgeVolume(delta));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.tokens;

    return Listener(
      onPointerSignal: _onPointerSignal,
      child: MouseRegion(
        // The pointer disappears with the controls, as it does in every video
        // player. `onHover` fires on movement only, which is exactly the wake
        // condition the task asks for.
        cursor: _visible ? MouseCursor.defer : SystemMouseCursors.none,
        onHover: (_) => _wake(),
        onExit: (_) => _wake(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // **The quality-switch cover.**
            //
            // A switch reopens the media inside mpv, and mpv starts the new
            // stream at zero and only then takes the seek back to where the user
            // was. Uncovered, that reads as: black, then a flash of the video's
            // *first frame* — which on most uploads is the thumbnail — then the
            // picture resuming in the right place. The middle third is the part
            // that looks broken, and it is not a thumbnail being drawn by
            // anything here: it is one real frame of the new stream, from a
            // position nobody asked for.
            //
            // Opaque black over the surface until the position comes back past
            // where it left (`isSwitchingQuality`, which the controller holds
            // until exactly that — see `PlaybackController.switchQuality`).
            // Above the video and below the bar, so the controls stay usable.
            if (ref.watch(playbackProvider.select((p) => p.isSwitchingQuality))) ColoredBox(key: playerSwitchCoverKey, color: tokens.scrim),
            // The click surface, beneath the bar so the bar's own buttons win
            // the hit test and its background absorbs rather than falls through.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onTap,
              child: const SizedBox.expand(),
            ),
            // Above the click surface so it paints over the cover, but
            // pointer-transparent — a spinner that swallowed the click to
            // play/pause would take the control away exactly when the player is
            // least responsive.
            //
            // **Keyed, and it does not work without the key.** This is the only
            // child of this `Stack` that owns `State`, and the cover above it
            // appears and disappears — which changes the children list at index
            // 0. Flutter's list diff scans forward while widgets match, scans
            // backward from the end, and then rematches everything in between
            // **by key alone**; unkeyed children in that middle range are
            // discarded and inflated fresh. The cover toggling breaks the
            // forward scan at index 0 and the quality menu breaks the backward
            // scan, which puts the spinner squarely in that range: without a key
            // its `State` was destroyed and its grace timer cancelled at the
            // exact moment a switch started, so the spinner it exists to show
            // could never appear. Traced, not guessed — `initState` ran a second
            // time before the first `dispose`.
            IgnorePointer(
              key: const ValueKey('player-busy'),
              child: _BusySpinner(engine: widget.engine),
            ),
            if (_qualityOpen)
              Positioned(
                right: 12,
                // `top` as well as `bottom`, so the menu is bounded by the
                // player box rather than by a guess: a 22-rung ladder in a 16:9
                // box on a 900 px window would otherwise run off the top and be
                // silently clipped by the `Stack`.
                top: 8,
                bottom: 96,
                child: _QualityMenu(
                  key: playerQualityMenuKey,
                  onPicked: (variant) {
                    setState(() => _qualityOpen = false);
                    _restartHideTimer();
                    unawaited(ref.read(playbackProvider.notifier).switchQuality(variant));
                  },
                ),
              ),
            // The fullscreen header: what is playing, since fullscreen hides the
            // page that would otherwise say. Fades with the bar rather than on
            // its own timer — one visibility, so they cannot disagree.
            if (ref.watch(playerViewProvider.select((view) => view.fullscreen)))
              Positioned(
                key: const ValueKey('player-header'),
                left: 0,
                right: 0,
                top: 0,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: _fadeDuration(_visible),
                  curve: Curves.easeIn,
                  child: AnimatedSlide(
                    offset: Offset.zero.translate(0, _visible ? 0 : -0.15),
                    duration: _fadeDuration(_visible),
                    curve: _visible ? Curves.decelerate : Curves.easeInExpo,
                    child: IgnorePointer(child: _FullscreenHeader(tokens: tokens)),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                key: playerControlsBarKey,
                opacity: _visible ? 1 : 0,
                duration: _fadeDuration(_visible),
                curve: Curves.easeIn,
                child: AnimatedSlide(
                  offset: Offset.zero.translate(0, _visible ? 0 : 0.15),
                  duration: _fadeDuration(_visible),
                  curve: _visible ? Curves.decelerate : Curves.easeInExpo,
                  child: IgnorePointer(
                    ignoring: !_visible,
                    child: GestureDetector(
                      // Absorbs. A click on the bar's background is not a click on
                      // the video, and must not pause it.
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              tokens.scrim.withValues(alpha: .95),
                              tokens.scrim.withValues(alpha: .75),
                              tokens.scrim.withValues(alpha: 0),
                            ],
                          ),
                        ),
                        child: Material(
                          type: MaterialType.transparency,
                          child: _buildBar(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    final queue = ref.watch(queueProvider);
    final view = ref.watch(playerViewProvider);
    final playback = ref.watch(playbackProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Scrubber(
          key: playerScrubberKey,
          engine: widget.engine,
          dragging: _dragging,
          hold: playback.hold,
          onDrag: (value) {
            setState(() => _dragging = value);
            _wake();
          },
          onDragEnd: (value) {
            setState(() => _dragging = null);
            unawaited(
              ref.read(playbackProvider.notifier).seek(Duration(milliseconds: value.round())),
            );
            _restartHideTimer();
          },
        ),
        // The bar has to survive a narrow window: at 900 px with the drawer
        // open the player is ~630 px wide, and the full cluster set needs ~700.
        // A `RenderFlex` overflow is silent in a release build — no stripes,
        // just controls cut off past the right edge — so the volume slider
        // collapses to its icon rather than the row overflowing.
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 640;
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Row(
                children: [
                  StreamBuilder<bool>(
                    stream: widget.engine.playingStream,
                    initialData: widget.engine.playing,
                    builder: (context, snapshot) => _ControlIcon(
                      iconKey: playerPlayPauseKey,
                      icon: (snapshot.data ?? false) ? Icons.pause : Icons.play_arrow,
                      onPressed: () {
                        _wake();
                        unawaited(ref.read(playbackProvider.notifier).togglePlayPause());
                      },
                    ),
                  ),
                  // **Absent, not disabled, when there is nowhere to go.** The
                  // queue stops rather than wrapping, and on an ordinary video
                  // there is no queue at all — two greyed-out arrows on every
                  // single video are two controls that never do anything. So
                  // they appear exactly when a playlist, mix or queue has given
                  // them somewhere to go. `Shift + P` / `Shift + N` still fire
                  // either way, which is what keeps the keyboard from being the
                  // thing that disappeared.
                  if (queue.hasPrevious)
                    _ControlIcon(
                      iconKey: playerPreviousKey,
                      icon: Icons.skip_previous,
                      onPressed: () {
                        _wake();
                        ref.read(playbackProvider.notifier).previous();
                      },
                    ),
                  if (queue.hasNext)
                    _ControlIcon(
                      iconKey: playerNextKey,
                      icon: Icons.skip_next,
                      onPressed: () {
                        _wake();
                        ref.read(playbackProvider.notifier).next();
                      },
                    ),
                  _Volume(engine: widget.engine, compact: compact, onChanged: _wake),
                  const SizedBox(width: 8),
                  // **One flex child between the clusters, not two.**
                  //
                  // This was `Flexible(clock)` followed by a `Spacer()`, and the
                  // pair is why the right-hand cluster sat ~300 px short of the
                  // right edge. Both are flex children with flex 1, so `Row`
                  // hands each *half* the free space — but `Flexible` is loose,
                  // so the clock uses ~80 px of its half and returns the rest.
                  // Returned space is not given to the `Spacer`, which has
                  // already been sized; it falls to the end of the row under the
                  // default `MainAxisAlignment.start`. The gap was the clock's
                  // unspent allowance, sitting at the far right.
                  //
                  // One `Expanded` holding a left-aligned clock has no share to
                  // return, and the cluster after it is genuinely flush right.
                  // It also keeps what the old comment wanted: at a narrow width
                  // the clock is the thing that gives up characters, because it
                  // is the only child that can be squeezed.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _Clock(
                        engine: widget.engine,
                        dragging: _dragging,
                        hold: playback.hold,
                      ),
                    ),
                  ),
                  _QualityButton(
                    key: playerQualityButtonKey,
                    engine: widget.engine,
                    playback: playback,
                    open: _qualityOpen,
                    onPressed: () {
                      setState(() => _qualityOpen = !_qualityOpen);
                      _restartHideTimer();
                    },
                  ),
                  // Captions. Present and **disabled** — they are their own task
                  // and there is nothing behind this yet. A disabled control
                  // says "later"; a live one that does nothing says "broken".
                  // (This replaces the reserved empty gap, which left the
                  // right-hand cluster looking as though it had lost a button.)
                  const _ControlIcon(
                    iconKey: playerCaptionsKey,
                    icon: Icons.closed_caption_outlined,
                    onPressed: null,
                  ),
                  _ControlIcon(
                    iconKey: playerMiniPlayerKey,
                    icon: Icons.branding_watermark_outlined,
                    onPressed: () {
                      _wake();
                      toMiniPlayer(ref);
                    },
                  ),
                  // **State, not action — and only this one.** Every other icon
                  // here says what pressing it does; this one says which mode
                  // the player is in, because "theatre" has no familiar glyph
                  // and an icon nobody recognises is better as a status than as
                  // an instruction. Fullscreen keeps action semantics next to
                  // it: `fullscreen_exit` is legible as a verb in a way the
                  // crop icons are not.
                  _ControlIcon(
                    iconKey: playerTheatreKey,
                    icon: view.theatre ? Icons.crop_7_5 : Icons.crop_16_9,
                    onPressed: () {
                      _wake();
                      ref.read(playerViewProvider.notifier).toggleTheatre();
                    },
                  ),
                  _ControlIcon(
                    iconKey: playerFullscreenKey,
                    icon: view.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    onPressed: () {
                      _wake();
                      ref.read(playerViewProvider.notifier).toggleFullscreen();
                    },
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            );
          },
        ),
      ],
    ).withScrimForeground(tokens);
  }
}

/// Applies the on-scrim foreground to a whole subtree.
///
/// The bar sits over an arbitrary video frame, not over a surface, so its
/// contrast comes from the scrim tokens rather than from a `ColorScheme` role
/// (see `theme/tokens.dart` — that is exactly the distinction those two tokens
/// exist to draw).
extension on Widget {
  Widget withScrimForeground(RillTokens tokens) => IconTheme.merge(
    data: IconThemeData(color: tokens.onScrim),
    child: DefaultTextStyle.merge(
      style: TextStyle(color: tokens.onScrim),
      child: this,
    ),
  );
}

class _ControlIcon extends StatelessWidget {
  const _ControlIcon({required this.iconKey, required this.icon, required this.onPressed});

  final Key iconKey;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    return IconButton(
      key: iconKey,
      // No `tooltip:`. At the fullscreen mount point this is above the
      // `Navigator`, and a tooltip there throws "No Overlay widget found" —
      // in front of the user, the first time the controls are drawn.
      mouseCursor: onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      icon: Icon(icon),
      color: tokens.onScrim,
      disabledColor: tokens.onScrim.withValues(alpha: 0.35),
      onPressed: onPressed,
    );
  }
}

/// Title and channel, top-left, while fullscreen.
///
/// Fullscreen hides the watch page, and with it the only thing on screen that
/// said what was playing. The gradient is the bottom bar's, mirrored: densest at
/// the very top where the text sits, gone by the bottom of the strip.
class _FullscreenHeader extends ConsumerWidget {
  const _FullscreenHeader({required this.tokens});

  final RillTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(playbackProvider.select((playback) => playback.item));
    if (item == null) return const SizedBox.shrink();

    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              tokens.scrim.withValues(alpha: .95),
              tokens.scrim.withValues(alpha: .75),
              tokens.scrim.withValues(alpha: 0),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tokens.onScrim,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.channelName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tokens.onScrim.withValues(alpha: 0.75), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "The player is waiting", wherever that wait comes from.
///
/// Three sources, one spinner: mpv buffering (an open, a seek repositioning, a
/// starved cache), a quality switch in flight, and the initial load. They are
/// the same thing to a viewer and there is no reason for them to look different.
///
/// It lives here rather than in the watch page so it appears at **both** mount
/// points — the 16:9 box and the fullscreen layer. The watch page's own
/// `isLoading` spinner covers the window before these controls are mounted at
/// all, which is why including `isLoading` here does not double up.
///
/// **Known gap, from F18:** a resume after a long pause costs 0.5–2.3 s and
/// never touches `core-idle` or `paused-for-cache`, so nothing here fires for
/// it. There is no signal to hang it on; inventing a timer would be guessing at
/// what mpv is doing rather than reading it.
class _BusySpinner extends ConsumerStatefulWidget {
  const _BusySpinner({required this.engine});

  final PlaybackEngine engine;

  @override
  ConsumerState<_BusySpinner> createState() => _BusySpinnerState();
}

class _BusySpinnerState extends ConsumerState<_BusySpinner> {
  bool _shown = false;
  bool _buffering = false;
  Timer? _graceTimer;
  StreamSubscription<bool>? _subscription;

  @override
  void initState() {
    super.initState();
    _buffering = widget.engine.buffering;
    _subscription = widget.engine.bufferingStream.listen((buffering) {
      if (!mounted || buffering == _buffering) return;
      _buffering = buffering;
      _update();
    });
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  /// Busy is checked against the whole set, not just the thing that changed —
  /// a switch that ends while mpv is still buffering must not take the spinner
  /// down with it.
  void _update() {
    final busy = _busy();
    if (!busy) {
      _graceTimer?.cancel();
      _graceTimer = null;
      if (_shown) setState(() => _shown = false);
      return;
    }
    // Already counting, or already up. Restarting the timer on every tick of a
    // sustained wait would mean the spinner never appears at all.
    if (_shown || (_graceTimer?.isActive ?? false)) return;
    _graceTimer = Timer(busySpinnerDelay, () {
      if (!mounted || !_busy()) return;
      setState(() => _shown = true);
    });
  }

  bool _busy() {
    final playback = ref.read(playbackProvider);
    return _buffering || playback.isSwitchingQuality || playback.isLoading;
  }

  @override
  Widget build(BuildContext context) {
    // Watched as well as read, so a switch starting or ending drives this even
    // though it arrives through Riverpod rather than through the stream above.
    ref.listen(
      playbackProvider.select((p) => p.isSwitchingQuality || p.isLoading),
      (_, _) => _update(),
    );

    if (!_shown) return const SizedBox.shrink();
    final tokens = Theme.of(context).tokens;
    return Center(
      key: playerBusySpinnerKey,
      child: SizedBox(
        width: 48,
        height: 48,
        child: CircularProgressIndicator(color: tokens.onScrim, strokeWidth: 3),
      ),
    );
  }
}

/// Position, buffered range and duration.
///
/// **Seeks on release, never during the drag.** F15 measured a 1.2–1.3 s stall
/// per seek, so a scrubber that seeked continuously would fire dozens across one
/// drag and the video would be unreachable for the length of it.
class _Scrubber extends StatelessWidget {
  const _Scrubber({
    super.key,
    required this.engine,
    required this.dragging,
    required this.hold,
    required this.onDrag,
    required this.onDragEnd,
  });

  final PlaybackEngine engine;
  final double? dragging;

  /// Where the video is while the engine cannot say — see [PlaybackHold].
  /// Outranks the stream, and is outranked by the thumb: three sources, one
  /// order, and it is the same order in the clock.
  ///
  /// **Its duration matters as much as its position here.** `max` is built from
  /// the duration, and a reopened media reports zero for both — so a hold that
  /// supplied only the position would clamp 3:00 into a 1 ms range and pin the
  /// thumb to the far right.
  final PlaybackHold? hold;

  final ValueChanged<double> onDrag;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: engine.positionStream,
      initialData: engine.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: engine.bufferStream,
          initialData: engine.buffer,
          builder: (context, bufferSnapshot) {
            final duration = hold?.duration ?? engine.duration;
            final max = math.max(duration.inMilliseconds.toDouble(), 1.0);
            final position = (hold?.position ?? positionSnapshot.data ?? Duration.zero).inMilliseconds.toDouble();
            final value = (dragging ?? position).clamp(0.0, max);
            final buffered = (bufferSnapshot.data ?? Duration.zero).inMilliseconds.toDouble();

            return SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                max: max,
                // The buffered range. Clamped above `value` because a secondary
                // track behind the thumb is an assertion error, and mpv reports
                // a buffer of zero for a moment after every seek.
                secondaryTrackValue: buffered.clamp(value, max),
                onChanged: onDrag,
                onChangeEnd: onDragEnd,
              ),
            );
          },
        );
      },
    );
  }
}

class _Clock extends StatelessWidget {
  const _Clock({required this.engine, required this.dragging, required this.hold});

  final PlaybackEngine engine;
  final double? dragging;

  /// See [_Scrubber.hold]. Same sources, same order — a clock reading
  /// `0:00 / 0:00` beside a scrubber holding 3:12 would be its own kind of wrong.
  final PlaybackHold? hold;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: engine.positionStream,
      initialData: engine.position,
      builder: (context, snapshot) {
        final duration = hold?.duration ?? engine.duration;
        // While dragging, the clock reads the thumb rather than the video —
        // otherwise the number under the finger is the position the user is
        // leaving, which is the one piece of information they do not need.
        final position = dragging == null ? (hold?.position ?? snapshot.data ?? Duration.zero) : Duration(milliseconds: dragging!.round());
        return Text(
          '${formatClock(position)} / ${formatClock(duration)}',
          // One line, clipped. Inside the `Expanded` above, a narrow bar hands
          // this a tight width, and the default wrap would make the clock two
          // lines tall and take the whole control bar with it.
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: const TextStyle(fontSize: 12),
        );
      },
    );
  }
}

/// The speaker, and a slider that is only there when the pointer is.
///
/// **It takes room in the row rather than floating over it.** The slider opens
/// *between* the mute button and the clock, so the clock and everything after it
/// shift right to make space — which is why this is an `AnimatedSize` in the
/// `Row` and not an overlay. An overlay would sit on top of the clock, and a
/// clock you cannot read while changing the volume is a worse trade than a
/// clock that moves.
///
/// The slider stays mounted at width zero rather than being swapped out, so the
/// open and close are one continuous motion instead of a widget appearing at the
/// end of a growing gap.
class _Volume extends ConsumerStatefulWidget {
  const _Volume({required this.engine, required this.compact, required this.onChanged});

  final PlaybackEngine engine;

  /// Icon only, and no hover reveal either. The slider is the first thing a
  /// narrow bar gives up, because `M` and the mute button both still work
  /// without it and the right-hand cluster does not — and a bar too narrow for
  /// the slider is one where opening it would push the clusters into overflow.
  final bool compact;

  final VoidCallback onChanged;

  @override
  ConsumerState<_Volume> createState() => _VolumeState();
}

class _VolumeState extends ConsumerState<_Volume> {
  bool _open = false;
  Timer? _closeTimer;

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  void _enter() {
    _closeTimer?.cancel();
    _closeTimer = null;
    widget.onChanged();
    if (!_open) setState(() => _open = true);
  }

  /// **Closes on a delay, and the delay is the point.** The pointer has to cross
  /// the gap between the speaker and the slider, and on the way it is briefly
  /// over neither — an immediate close would collapse the slider out from under
  /// a pointer heading straight for it, every time.
  void _exit() {
    _closeTimer?.cancel();
    _closeTimer = Timer(volumeSliderHideDelay, () {
      if (!mounted) return;
      setState(() => _open = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: widget.engine.volumeStream,
      initialData: widget.engine.volume,
      builder: (context, snapshot) {
        final volume = (snapshot.data ?? 100).clamp(0.0, 100.0);
        final open = _open && !widget.compact;

        return MouseRegion(
          // One region over the button *and* the slider, so travelling from one
          // to the other never leaves it.
          onEnter: (_) => _enter(),
          onExit: (_) => _exit(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ControlIcon(
                iconKey: playerMuteKey,
                icon: volume == 0 ? Icons.volume_off : (volume < 50 ? Icons.volume_down : Icons.volume_up),
                onPressed: () {
                  widget.onChanged();
                  unawaited(ref.read(playbackProvider.notifier).toggleMute());
                },
              ),
              ClipRect(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  child: SizedBox(
                    key: playerVolumeSliderKey,
                    width: open ? 120 : 0,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                      ),
                      child: Slider(
                        value: volume,
                        max: 100,
                        onChanged: (next) {
                          widget.onChanged();
                          unawaited(ref.read(playbackProvider.notifier).setVolume(next));
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The quality button, labelled with what is **actually** decoding.
///
/// mpv's reported height, not the one that was requested: a variant can be asked
/// for and something else served, and a menu that reports the request is
/// confident exactly when it is wrong. Falls back to the requested height only
/// until the first frame, when mpv has nothing to report yet.
class _QualityButton extends StatelessWidget {
  const _QualityButton({
    super.key,
    required this.engine,
    required this.playback,
    required this.open,
    required this.onPressed,
  });

  final PlaybackEngine engine;
  final PlaybackState playback;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.tokens;
    final variants = playback.variants;

    return StreamBuilder<int?>(
      stream: engine.heightStream,
      initialData: engine.height,
      builder: (context, snapshot) {
        final actual = snapshot.data ?? playback.variant?.height;
        return TextButton(
          onPressed: variants.isEmpty ? null : onPressed,
          style: TextButton.styleFrom(
            foregroundColor: tokens.onScrim,
            disabledForegroundColor: tokens.onScrim.withValues(alpha: 0.35),
            backgroundColor: open ? tokens.onScrim.withValues(alpha: 0.15) : Colors.transparent,
            enabledMouseCursor: SystemMouseCursors.click,
            disabledMouseCursor: SystemMouseCursors.basic,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (playback.isSwitchingQuality)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: tokens.onScrim),
                )
              else
                const Icon(Icons.settings, size: 16),
              const SizedBox(width: 6),
              Text(actual == null ? 'Quality' : '${actual}p', style: const TextStyle(fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}

/// The ladder, as a panel in the controls `Stack`.
///
/// Not a `PopupMenuButton` and not a `DropdownButton`: both push a route, and at
/// the fullscreen mount point there is no `Navigator` above this widget to push
/// onto.
class _QualityMenu extends ConsumerWidget {
  const _QualityMenu({super.key, required this.onPicked});

  final ValueChanged<PlaybackVariant> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(playbackProvider);
    final variants = distinctQualities(playback.variants);
    final current = playback.variant;

    // Bottom-aligned inside whatever height the `Positioned` allows, so the menu
    // grows upward from the button and stops at the top of the player.
    return Align(
      alignment: Alignment.bottomRight,
      child: Material(
        elevation: 8,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        // An explicit width, not a minimum: the `Positioned` below pins three
        // edges and leaves the fourth unbounded, and a shrink-wrapping
        // `ListView` given unbounded cross-axis space is an assertion, not a
        // narrow menu.
        child: SizedBox(
          width: 180,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final variant in variants)
                InkWell(
                  onTap: () => onPicked(variant),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check,
                          size: 16,
                          // Matched on what the row *says*, not on identity: the
                          // open variant may be the second 1080p60 of three, and
                          // ticking nothing because the menu is showing the
                          // first would be a menu with no current entry at all.
                          //
                          // Transparent rather than absent: a tick that appears
                          // and disappears shifts every label sideways, so the
                          // marked row is the one that does not move.
                          color: current != null && variant.height == current.height && variant.fps == current.fps ? scheme.primary : Colors.transparent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          describeVariant(variant),
                          style: TextStyle(fontSize: 13, color: scheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                ),
              // **Last, and deliberately dead** (task §3). Automatic stepping on
              // frame drops needs a threshold over a window, hysteresis, and a
              // way to tell a decode limit from a momentary stall — it is out of
              // scope, and the picker exists partly to find out what this
              // machine actually does before any of that is designed.
              //
              // At the *bottom* rather than the top: the ladder above it is
              // ordered best-first, so a row that means "let the player decide"
              // reads as the end of the list rather than as a rung above 2160p.
              // It is *disabled* rather than merely inert — a row that can be
              // clicked and does nothing reads as a bug.
              Divider(height: 1, color: scheme.outlineVariant),
              Opacity(
                key: playerQualityAutoKey,
                opacity: 0.4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.check, size: 16, color: Colors.transparent),
                      const SizedBox(width: 8),
                      Text('Auto', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `1080p60`, or `1080p` at 30. The codec is deliberately absent: `transport`
/// and the ladder tier are telemetry the UI must not be able to read off (§3.5),
/// and a codec name in a quality menu is an invitation to treat it as a choice.
String describeVariant(PlaybackVariant variant) => variant.fps > 30 ? '${variant.height}p${variant.fps}' : '${variant.height}p';

/// One row per height+fps, best-ranked first.
///
/// **Measured, not anticipated:** a real ladder for `aqz-KE-bpKQ` is 22 rungs —
/// 2160p60 twice, 1440p60 twice, 1080p60 three times, and so on down — because
/// the same resolution ships in several codecs. Listed raw that is a menu of
/// twenty-two entries with four distinct labels repeated, where picking between
/// two rows reading "1080p60" is a coin flip the user cannot inform.
///
/// So the *menu* collapses them and the ladder does not: `variants` stays
/// exactly as the sidecar ranked it (§3.5 — the sidecar ranks, the client
/// picks), and the first of each pair is the one the ranking already preferred.
List<PlaybackVariant> distinctQualities(List<PlaybackVariant> variants) {
  final seen = <String>{};
  return [
    for (final variant in variants)
      if (seen.add('${variant.height}x${variant.fps}')) variant,
  ];
}

String formatClock(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(hours > 0 ? 2 : 1, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
