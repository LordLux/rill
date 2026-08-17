/// The shell player's control overlay.
///
/// One widget, two mount points: inside the watch page's 16:9 box, and
/// full-window above the `Navigator` when fullscreen. It never builds a video
/// surface of its own — it draws *over* whichever one the caller mounted, so a
/// mode change moves the controls and leaves the texture alone.
///
/// **Two constraints shape the whole file.** Everything read comes off
/// `player.stream.*`, never `getProperty` (hard invariant 9). And nothing here
/// may use a tooltip, a `PopupMenuButton` or any other route — at the fullscreen
/// mount point this is above the `Navigator`, with no `Overlay` to host one, so
/// the quality menu is a panel in this `Stack` rather than a popup.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent, PointerSignalEvent, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playback/engine.dart';
import '../../theme/tokens.dart';
import '../playback_controller.dart';
import '../player_shell.dart';
import '../queue_controller.dart';
import 'settings_menu.dart';
import 'shortcuts.dart' show volumeStep;
import 'view_mode.dart';

/// `describeVariant` and `distinctQualities` moved to `settings_menu.dart` with
/// the menu that is their only caller. Re-exported so `controls_probe.dart` and
/// anything else that reached for them here still can.
export 'settings_menu.dart' show describeVariant, distinctQualities;

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
const Key playerVerticalVolumeKey = ValueKey('player-vertical-volume');
const Key playerVerticalVolumeSliderKey = ValueKey('player-vertical-volume-slider');
const Key playerCaptionsKey = ValueKey('player-captions');
const Key playerMiniPlayerKey = ValueKey('player-mini-player');
const Key playerTheatreKey = ValueKey('player-theatre');
const Key playerFullscreenKey = ValueKey('player-fullscreen');

class PlayerControls extends ConsumerStatefulWidget {
  const PlayerControls({super.key, required this.engine, this.actualAspectRatio});

  final PlaybackEngine engine;
  final double? actualAspectRatio;

  @override
  ConsumerState<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends ConsumerState<PlayerControls> {
  bool get _isVertical => widget.actualAspectRatio != null && widget.actualAspectRatio! < 1.0;

  bool _visible = true;
  bool _playing = false;
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
  /// the settings menu is open — a menu that vanishes from under the pointer is
  /// worse than one that overstays.
  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_playing || ref.read(playerMenuProvider).open) {
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

  /// The gear, from either layout.
  ///
  /// `_wake` after rather than before: the toggle is what decides whether the
  /// hide timer may run at all, and waking first would start a countdown the
  /// open menu is about to have to cancel.
  void _toggleMenu() => _toggleMenuAt(SettingsPage.root);

  void _toggleQuality() => _toggleMenuAt(SettingsPage.quality);

  void _toggleMenuAt(SettingsPage page) {
    ref.read(playerMenuProvider.notifier).toggleAt(page);
    _wake();
  }

  /// Click, and the double-click that may or may not be arriving.
  ///
  /// The first click acts immediately and a second within the window *undoes*
  /// it and goes fullscreen — holding every click for the double-click window
  /// (what `onTap` + `onDoubleTap` does) makes every pause feel broken. The undo
  /// restores the recorded pre-click state rather than toggling again, because
  /// two toggles only cancel if the first has finished landing.
  void _onTap() {
    _wake();

    // The menu is closed by the window-wide listener in `player_shell.dart`,
    // which runs on the same pointer-down — so by the time a tap resolves here
    // it is already gone, and swallowing this click as "the one that dismissed
    // the menu" would eat a play/pause the user is entitled to. That is the
    // whole point of the click-through: outside the panel, the click means what
    // it would have meant with no menu open.

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
  /// Claimed through the `pointerSignalResolver` rather than merely read, which
  /// is the contract for handling a pointer signal at all.
  ///
  /// Measured: the page does not scroll under shift-scroll either way, because
  /// `Scrollable` flips its axis while shift is down and then reads a `dx` a
  /// vertical wheel leaves at zero. Registering stops that being a coincidence
  /// the moment anything horizontal is in the ancestry.
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

    // The menu can close from outside this widget — `Esc` in `shortcuts.dart`,
    // a click anywhere else via `player_shell.dart`. Both move the provider and
    // neither can reach in here, so the countdown the open menu suspended has to
    // be restarted by watching the state rather than by the closer remembering
    // to say so.
    ref.listen(playerMenuProvider.select((menu) => menu.open), (previous, next) {
      if (previous == true && next == false) _restartHideTimer();
    });

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
            // The quality-switch cover (architecture §2.7): a reopened media
            // plays one real frame from position zero before the seek back
            // lands, and that flash is what reads as broken. Held until the
            // position returns, above the video and below the bar.
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
            // **Keyed, and it does not work without the key.** The cover
            // toggling breaks the child list's forward scan and the menu breaks
            // the backward one, so this lands in the middle range Flutter
            // rematches by key alone — unkeyed, its `State` was destroyed and
            // its grace timer cancelled at the exact moment a switch started.
            IgnorePointer(
              key: const ValueKey('player-busy'),
              child: _BusySpinner(engine: widget.engine),
            ),
            // **Mounted unconditionally now that it fades.** The `if` used to
            // be here, and an `if` cannot animate an exit: the panel was gone
            // from the tree on the same frame it was told to close, with nothing
            // left to fade. `SettingsMenuFade` owns the mount instead and holds
            // it for the length of the fade. While closed it is a zero-width
            // box — two render objects and no hit target.
            Positioned(
              right: _isVertical ? 64 : 7,
              // `top` as well as `bottom`, so the menu is bounded by the
              // player box rather than by a guess: a 22-rung ladder in a 16:9
              // box on a 900 px window would otherwise run off the top and be
              // silently clipped by the `Stack`. The panel's own 400 cap is
              // the *other* limit; whichever is smaller wins, which is what
              // keeps a tall menu out of a short player.
              top: 8,
              bottom: _isVertical ? 56 : 58,
              child: SettingsMenuFade(
                visible: ref.watch(playerMenuProvider.select((menu) => menu.open)),
                child: PlayerSettingsMenu(
                  key: playerSettingsMenuKey,
                  onPicked: (variant) {
                    ref.read(playerMenuProvider.notifier).close();
                    _restartHideTimer();
                    unawaited(ref.read(playbackProvider.notifier).switchQuality(variant));
                  },
                ),
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

            // Vertical video player controls
            if (_isVertical)
              Positioned(
                right: 6,
                bottom: 52,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: _fadeDuration(_visible),
                  curve: Curves.easeIn,
                  child: AnimatedSlide(
                    offset: Offset.zero.translate(_visible ? 0 : 0.15, 0),
                    duration: _fadeDuration(_visible),
                    curve: _visible ? Curves.decelerate : Curves.easeInExpo,
                    child: IgnorePointer(
                      ignoring: !_visible,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.scrim.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(52),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _VerticalVolume(
                                key: playerVerticalVolumeKey,
                                engine: widget.engine,
                                onChanged: _wake,
                              ),
                              const SizedBox(height: 2),
                              KeyedSubtree(
                                key: qualityButtonAnchorKey,
                                child: _MenuButton(
                                  key: playerQualityButtonKey,
                                  icon: Icons.hd_outlined,
                                  busy: ref.watch(playbackProvider.select((p) => p.isSwitchingQuality)),
                                  open: ref.watch(
                                    playerMenuProvider.select(
                                      (menu) => menu.open && menu.page == SettingsPage.quality,
                                    ),
                                  ),
                                  onPressed: ref.watch(playbackProvider.select((p) => p.variants.isEmpty)) ? null : _toggleQuality,
                                ),
                              ),
                              const SizedBox(height: 2),
                              KeyedSubtree(
                                key: settingsMenuAnchorKey,
                                child: _MenuButton(
                                  key: playerSettingsButtonKey,
                                  icon: Icons.settings,
                                  open: ref.watch(
                                    playerMenuProvider.select(
                                      (menu) => menu.open && menu.page != SettingsPage.quality,
                                    ),
                                  ),
                                  onPressed: _toggleMenu,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
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
                              tokens.scrim.withValues(alpha: .75),
                              tokens.scrim.withValues(alpha: .5),
                              tokens.scrim.withValues(alpha: 0),
                            ],
                          ),
                        ),
                        child: Material(
                          type: MaterialType.transparency,
                          child: _isVertical ? _buildVerticalBar(context) : _buildBar(context),
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
                    builder: (context, snapshot) {
                      final playing = snapshot.data ?? false;
                      return _ControlIcon(
                        iconKey: playerPlayPauseKey,
                        icon: playing ? Icons.pause : Icons.play_arrow,
                        label: playing ? 'Pause' : 'Play',
                        onPressed: () {
                          _wake();
                          unawaited(ref.read(playbackProvider.notifier).togglePlayPause());
                        },
                      );
                    },
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
                      label: 'Previous video',
                      onPressed: () {
                        _wake();
                        ref.read(playbackProvider.notifier).previous();
                      },
                    ),
                  if (queue.hasNext)
                    _ControlIcon(
                      iconKey: playerNextKey,
                      icon: Icons.skip_next,
                      label: 'Next video',
                      onPressed: () {
                        _wake();
                        ref.read(playbackProvider.notifier).next();
                      },
                    ),
                  _Volume(engine: widget.engine, compact: compact, onChanged: _wake),
                  const SizedBox(width: 8),
                  // **One flex child between the clusters, not two**
                  // (architecture §2.7). A loose `Flexible` clock plus a
                  // `Spacer` leaves the clock's unspent half at the far right.
                  // `Expanded` has no share to return, and the clock stays the
                  // one child that gives up characters when width runs out.
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
                  // Captions. Present and **disabled** — they are their own task
                  // and there is nothing behind this yet. A disabled control
                  // says "later"; a live one that does nothing says "broken".
                  // (This replaces the reserved empty gap, which left the
                  // right-hand cluster looking as though it had lost a button.)
                  const _ControlIcon(
                    iconKey: playerCaptionsKey,
                    icon: Icons.closed_caption_outlined,
                    label: 'Captions',
                    onPressed: null,
                  ),
                  // **Quality, then the gear** — specific before general. It is
                  // the one picker anybody changes mid-video, so a row two taps
                  // deep inside the settings menu was the wrong depth for it.
                  //
                  // `KeyedSubtree` because each button needs two keys: the
                  // `ValueKey` the tests find it by, and the `GlobalKey` the
                  // click-outside measures it by. See `settingsMenuAnchorKey`.
                  KeyedSubtree(
                    key: qualityButtonAnchorKey,
                    child: _MenuButton(
                      key: playerQualityButtonKey,
                      icon: Icons.hd_outlined,
                      busy: playback.isSwitchingQuality,
                      open: ref.watch(
                        playerMenuProvider.select(
                          (menu) => menu.open && menu.page == SettingsPage.quality,
                        ),
                      ),
                      onPressed: playback.variants.isEmpty ? null : _toggleQuality,
                    ),
                  ),
                  KeyedSubtree(
                    key: settingsMenuAnchorKey,
                    child: _MenuButton(
                      key: playerSettingsButtonKey,
                      icon: Icons.settings,
                      open: ref.watch(
                        playerMenuProvider.select(
                          (menu) => menu.open && menu.page != SettingsPage.quality,
                        ),
                      ),
                      onPressed: _toggleMenu,
                    ),
                  ),
                  _ControlIcon(
                    iconKey: playerMiniPlayerKey,
                    icon: Icons.branding_watermark_outlined,
                    label: 'Miniplayer',
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
                    label: view.theatre ? 'Default view' : 'Theatre mode',
                    onPressed: () {
                      _wake();
                      ref.read(playerViewProvider.notifier).toggleTheatre();
                    },
                  ),
                  _ControlIcon(
                    iconKey: playerFullscreenKey,
                    icon: view.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    label: view.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
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

  Widget _buildVerticalBar(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    final queue = ref.watch(queueProvider);
    final view = ref.watch(playerViewProvider);
    final playback = ref.watch(playbackProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 6, 6),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: widget.engine.playingStream,
            initialData: widget.engine.playing,
            builder: (context, snapshot) {
              final playing = snapshot.data ?? false;
              return _ControlIcon(
                iconKey: playerPlayPauseKey,
                icon: playing ? Icons.pause : Icons.play_arrow,
                label: playing ? 'Pause' : 'Play',
                onPressed: () {
                  _wake();
                  unawaited(ref.read(playbackProvider.notifier).togglePlayPause());
                },
              );
            },
          ),
          if (queue.hasPrevious)
            _ControlIcon(
              iconKey: playerPreviousKey,
              icon: Icons.skip_previous,
              label: 'Previous video',
              onPressed: () {
                _wake();
                ref.read(playbackProvider.notifier).previous();
              },
            ),
          if (queue.hasNext)
            _ControlIcon(
              iconKey: playerNextKey,
              icon: Icons.skip_next,
              label: 'Next video',
              onPressed: () {
                _wake();
                ref.read(playbackProvider.notifier).next();
              },
            ),
          const SizedBox(width: 4),
          _Clock(
            engine: widget.engine,
            dragging: _dragging,
            hold: playback.hold,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Scrubber(
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
          ),
          const SizedBox(width: 4),
          _ControlIcon(
            iconKey: playerFullscreenKey,
            icon: view.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            label: view.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
            onPressed: () {
              _wake();
              ref.read(playerViewProvider.notifier).toggleFullscreen();
            },
          ),
          SizedBox(width: 4),
        ],
      ),
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
  const _ControlIcon({required this.iconKey, required this.icon, required this.label, required this.onPressed});

  final Key iconKey;
  final IconData icon;
  final String label;
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
      icon: Icon(icon, semanticLabel: label),
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
              tokens.scrim.withValues(alpha: .75),
              tokens.scrim.withValues(alpha: .5),
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
/// Here rather than in the watch page so it appears at **both** mount points.
/// The page's own `isLoading` spinner covers the window before these controls
/// mount at all, so including `isLoading` here does not double up.
///
/// **Known gap (F18):** a resume after a long pause costs 0.5–2.3 s and touches
/// neither `core-idle` nor `paused-for-cache`, so nothing fires for it.
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

            final pad = SliderTheme.of(context).padding ?? const EdgeInsets.symmetric(horizontal: 12.0);

            return SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                trackShape: const _RillSliderTrackShape(),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                padding: pad / 1.5,
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
/// **It takes room in the row rather than floating over it** — an `AnimatedSize`
/// in the `Row`, not an overlay, because a clock you cannot read while changing
/// the volume is a worse trade than a clock that moves.
///
/// The slider stays mounted at width zero rather than being swapped out, so open
/// and close are one continuous motion.
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
                label: volume == 0 ? 'Unmute' : 'Mute',
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

/// The speaker, with a slider that expands vertically upward on hover for vertical videos.
class _VerticalVolume extends ConsumerStatefulWidget {
  const _VerticalVolume({super.key, required this.engine, required this.onChanged});

  final PlaybackEngine engine;
  final VoidCallback onChanged;

  @override
  ConsumerState<_VerticalVolume> createState() => _VerticalVolumeState();
}

class _VerticalVolumeState extends ConsumerState<_VerticalVolume> {
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

        return MouseRegion(
          onEnter: (_) => _enter(),
          onExit: (_) => _exit(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRect(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  child: SizedBox(
                    key: playerVerticalVolumeSliderKey,
                    height: _open ? 100 : 0,
                    width: 36,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                ),
              ),
              _ControlIcon(
                iconKey: playerMuteKey,
                icon: volume == 0 ? Icons.volume_off : (volume < 50 ? Icons.volume_down : Icons.volume_up),
                label: volume == 0 ? 'Unmute' : 'Mute',
                onPressed: () {
                  widget.onChanged();
                  unawaited(ref.read(playbackProvider.notifier).toggleMute());
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The gear, and the quality button beside it.
///
/// One widget for both: they differ only in glyph and in which page they open,
/// and the *open* highlight has to work identically or the pair reads as two
/// unrelated controls that happen to sit together.
///
/// The spinner belongs to the quality button: a switch in flight is a fact about
/// that control, and the only other sign of one is the black cover, which alone
/// reads as a stall rather than as something the user asked for.
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    super.key,
    required this.icon,
    required this.open,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final bool open;

  /// Null draws it disabled — the quality button with an empty ladder.
  final VoidCallback? onPressed;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).tokens;

    return IconButton(
      onPressed: onPressed,
      mouseCursor: onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      iconSize: 20,
      style: IconButton.styleFrom(
        foregroundColor: tokens.onScrim,
        disabledForegroundColor: tokens.onScrim.withValues(alpha: 0.35),
        backgroundColor: open ? tokens.onScrim.withValues(alpha: 0.15) : Colors.transparent,
      ),
      icon: busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: tokens.onScrim),
            )
          : Icon(icon),
    );
  }
}

String formatClock(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(hours > 0 ? 2 : 1, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

class _RillSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _RillSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    assert(sliderTheme.disabledActiveTrackColor != null);
    assert(sliderTheme.disabledInactiveTrackColor != null);
    assert(sliderTheme.activeTrackColor != null);
    assert(sliderTheme.inactiveTrackColor != null);
    assert(sliderTheme.thumbShape != null);
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) return;

    final ColorTween activeTrackColorTween = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor,
      end: sliderTheme.activeTrackColor,
    );
    final ColorTween inactiveTrackColorTween = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor,
      end: sliderTheme.inactiveTrackColor,
    );
    final Paint activePaint = Paint()..color = activeTrackColorTween.evaluate(enableAnimation)!;
    final Paint inactivePaint = Paint()..color = inactiveTrackColorTween.evaluate(enableAnimation)!;

    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final Paint leftTrackPaint;
    final Paint rightTrackPaint;
    switch (textDirection) {
      case TextDirection.ltr:
        leftTrackPaint = activePaint;
        rightTrackPaint = inactivePaint;
        break;
      case TextDirection.rtl:
        leftTrackPaint = inactivePaint;
        rightTrackPaint = activePaint;
        break;
    }

    // Draw active track
    final Rect leftTrackSegment = Rect.fromLTRB(trackRect.left, trackRect.top, thumbCenter.dx, trackRect.bottom);
    if (!leftTrackSegment.isEmpty) {
      context.canvas.drawRect(leftTrackSegment, leftTrackPaint);
    }

    // Draw secondary track (buffered)
    if (secondaryOffset != null) {
      final bufferRight = math.max(thumbCenter.dx, secondaryOffset.dx);
      final Paint secondaryPaint = Paint()..color = sliderTheme.secondaryActiveTrackColor ?? sliderTheme.activeTrackColor!.withValues(alpha: 0.5);
      final Rect secondaryTrackSegment = Rect.fromLTRB(
        thumbCenter.dx,
        trackRect.top,
        bufferRight,
        trackRect.bottom,
      );
      if (!secondaryTrackSegment.isEmpty) {
        context.canvas.drawRect(secondaryTrackSegment, secondaryPaint);
      }

      // Draw inactive track (remaining)
      final Rect rightTrackSegment = Rect.fromLTRB(
        bufferRight,
        trackRect.top,
        trackRect.right,
        trackRect.bottom,
      );
      if (!rightTrackSegment.isEmpty) {
        context.canvas.drawRect(rightTrackSegment, rightTrackPaint);
      }
    } else {
      final Rect rightTrackSegment = Rect.fromLTRB(
        thumbCenter.dx,
        trackRect.top,
        trackRect.right,
        trackRect.bottom,
      );
      if (!rightTrackSegment.isEmpty) {
        context.canvas.drawRect(rightTrackSegment, rightTrackPaint);
      }
    }
  }
}
