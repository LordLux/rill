/// The shell player's control overlay.
///
/// One widget, two mount points: inside the watch page's 16:9 box, and
/// full-window above the `Navigator` when fullscreen. It never builds a video
/// surface of its own — it draws *over* whichever one the caller mounted, so a
/// mode change moves the controls and leaves the texture alone.
///
/// **Two constraints shape the whole file.** Everything read comes off
/// `player.stream.*`, never `getProperty` (hard invariant 9). And the quality
/// menu is a panel in this `Stack` rather than a `PopupMenuButton` — that one
/// still needs a route this `Stack` cannot give it.
///
/// **A `tooltip:`/`Tooltip` is fine here now, and was not always.** This file
/// used to say neither mount point had an `Overlay` to host one, and at the
/// fullscreen mount point — above the `Navigator` — that was true once. It
/// stopped being true when `_FullscreenPlayer` (`player_shell.dart`) was given
/// its own local `Overlay`, added because Material's `Slider` renders its
/// value indicator through an `OverlayPortal` and needed one regardless
/// (`architecture.md` §2.8). That fix never made it back to this comment,
/// which kept telling the next person to route around a constraint that no
/// longer existed.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show GestureBinding, PointerDeviceKind, PointerScrollEvent, PointerSignalEvent, PointerUpEvent, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, KeyDownEvent, KeyEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playback/engine.dart';
import '../../domain/playback_source.dart';
import '../../domain/player_controls_visibility.dart';
import '../../theme/tokens.dart';
import '../spoken.dart';
import 'volume_bar.dart';
import '../captions_controller.dart';
import '../playback_controller.dart';
import '../audio_mode_controller.dart';
import '../player_shell.dart';
import '../queue_controller.dart';
import '../video_info.dart';
import '../focus_ring.dart' show KeyboardNavigation;
import '../focus_surface.dart';
import '../widgets/shortcut_tooltip.dart';
import 'scrubber_bar.dart';
import 'scrubber_chapters.dart';
import 'shortcuts.dart' show PlayerAction;
import 'settings_menu.dart';
import 'shortcuts.dart' show volumeStep;
import 'view_mode.dart';

/// `describeVariant` and `distinctQualities` moved to `settings_menu.dart` with
/// the menu that is their only caller. Re-exported so `controls_probe.dart` and
/// anything else that reached for them here still can.
export 'settings_menu.dart' show describeVariant, distinctQualities;

/// `playerControlsBarKey` lives in `domain/player_controls_visibility.dart` now
/// — `LibassLayer` needs it too, and that is the file with no reason to import
/// this one. Re-exported so existing callers (this file's own tests included)
/// do not need to know it moved.
export '../../domain/player_controls_visibility.dart' show playerControlsBarKey, playerControlsVisibleProvider;

/// How long the pointer must be still before the controls go away.
const Duration autoHideDelay = Duration(seconds: 1);

/// How close two clicks have to be to count as one double click.
///
/// Flutter's own `kDoubleTapTimeout`. Named here because it is load-bearing
/// rather than incidental — see [_PlayerControlsState._onTap].
const Duration doubleClickWindow = kDoubleTapTimeout;

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
  const PlayerControls({super.key, required this.engine, this.actualAspectRatio, this.child});

  final PlaybackEngine engine;
  final double? actualAspectRatio;
  final Widget? child;

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

  int _hoveredClickables = 0;

  /// Mirrors `_BusySpinnerState._shown` — set by the callback passed to
  /// [_BusySpinner] below, not derived independently. Deriving it here too
  /// would be a second copy of the grace-period timer with its own chance to
  /// disagree with the spinner about whether it is currently on screen; this
  /// way the bar is visible exactly when the spinner is, never a frame off.
  bool _busyShown = false;

  void _onBusyChanged(bool busy) {
    if (_busyShown == busy) return;
    _busyShown = busy;
    _restartHideTimer();
  }

  Widget _buildHoverable(Widget child) {
    return MouseRegion(
      onEnter: (_) {
        _hoveredClickables++;
        _restartHideTimer();
      },
      onExit: (_) {
        _hoveredClickables--;
        _restartHideTimer();
      },
      child: child,
    );
  }

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
    HardwareKeyboard.instance.addHandler(_onKey);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  /// Tab after a click, or Escape after Tab, changes whether the focused control
  /// counts as "selected by keyboard" without moving focus, so no focus event says
  /// so: the countdown has to be re-decided here.
  void _onHighlightMode(FocusHighlightMode mode) {
    if (!mounted) return;
    if (mode == FocusHighlightMode.traditional && _focusInside && !_visible) {
      _wake();
      return;
    }
    _restartHideTimer();
  }

  /// Keyboard focus is on the bar, a submenu or anything else in here, so the bar
  /// stays up exactly as it does while the pointer is over it. **Keyboard focus
  /// only:** a control that was merely clicked keeps focus too, and the bar has
  /// always hidden after a click.
  bool _focusInside = false;

  /// The observer's own node, so "is focus in here" can be *asked* at any moment. The
  /// focus event only says it changed: a control that already holds focus when this
  /// widget is rebuilt around it (a layout swap, a quality switch) is never reported,
  /// and the bar then hid under a selected control.
  final FocusNode _focusProbe = FocusNode(debugLabel: 'player controls', canRequestFocus: false, skipTraversal: true);

  bool get _keyboardInside => (_focusInside || _focusProbe.hasFocus) && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  void _onFocusInsideChanged(bool has) {
    if (_focusInside == has) return;
    _focusInside = has;
    // Focus reaching a hidden bar shows it (and `_keyboardInside` then keeps it up).
    if (has && !_visible && KeyboardNavigation.active) {
      _wake();
      return;
    }
    _restartHideTimer();
  }

  /// Any key brings the bar back. Hidden controls are not focusable, so without
  /// this the first Tab after they auto-hide would skip them and a keyboard user
  /// could never find them again; with it, that Tab shows them and the next one
  /// lands. Never claims the event.
  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && !_visible) _wake();
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _focusProbe.dispose();
    _hideTimer?.cancel();
    _doubleClickWindow?.cancel();
    unawaited(_playingSubscription?.cancel());
    super.dispose();
  }

  /// The one place `_visible` changes, so `playerControlsVisibleProvider` — the
  /// copy `LibassLayer` reads to nudge captions off the bar — cannot drift from
  /// what this widget actually shows.
  void _setVisible(bool value) {
    if (_visible == value) return;
    setState(() => _visible = value);
    ref.read(playerControlsVisibleProvider.notifier).set(value);
  }

  /// Restarts the countdown that hides the bar.
  ///
  /// Hides only while **playing**, only after [autoHideDelay], never while
  /// the settings menu is open, never when hovering a clickable control, and
  /// never while the busy spinner is on screen — a stall is exactly when
  /// someone reaches for mute or pause, and the controls must not have
  /// vanished out from under that reach.
  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_playing || ref.read(playerMenuProvider).open || _hoveredClickables > 0 || _busyShown || _keyboardInside) {
      _setVisible(true);
      return;
    }
    _hideTimer = Timer(autoHideDelay, () {
      if (!mounted) return;
      // Asked again now: whatever was true when the countdown started may not be.
      if (_keyboardInside) {
        _restartHideTimer();
        return;
      }
      _setVisible(false);
    });
  }

  void _wake() {
    _setVisible(true);
    _restartHideTimer();
  }

  /// The gear, from either layout.
  ///
  /// `_wake` after rather than before: the toggle is what decides whether the
  /// hide timer may run at all, and waking first would start a countdown the
  /// open menu is about to have to cancel.
  void _toggleMenu() => _toggleMenuAt(SettingsPage.root);

  void _toggleQuality() => _toggleMenuAt(SettingsPage.quality);
  void _toggleCaptions() => _toggleMenuAt(SettingsPage.captions);

  /// Whether a page belongs to the gear rather than to one of the two buttons
  /// with their own door. Listed positively so a fourth page defaults to *not*
  /// lighting the gear up, which is the safe direction.
  static bool _isGearPage(SettingsPage page) =>
      page == SettingsPage.root || page == SettingsPage.moreOptions;

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

    // Ordered: the progress bar and controls first, then whatever the slates hold (in
    // fullscreen, the queue's toggle and the queue). Reading order alone put a queue sliding
    // in at the top of the screen before the controls at the bottom.
    return TooltipBounds(
      child: FocusSurface(
        ordered: true,
        child: Focus(
          focusNode: _focusProbe,
          // No semantics node: this `Focus` only watches focus, and the node it would
          // add above the whole player brings the Slider/OverlayPortal fault back
          // (`architecture.md` F51) — measured, ~1 450 AXTree errors a run.
          includeSemantics: false,
          onFocusChange: _onFocusInsideChanged,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: MouseRegion(
              // The pointer disappears with the controls, as it does in every video
              // player. `onHover` fires on movement only, which is exactly the wake
              // condition the task asks for.
              cursor: _visible ? MouseCursor.defer : SystemMouseCursors.none,
              onHover: (event) {
                if (event.delta != Offset.zero) _wake();
              },
              onExit: (_) => _wake(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The quality-switch cover (architecture §2.7): a reopened media
                  // plays one real frame from position zero before the seek back
                  // lands, and that flash is what reads as broken. Held until the
                  // position returns, above the video and below the bar.
                  if (ref.watch(playbackProvider.select((p) => p.isSwitchingQuality)) && !ref.watch(audioModeProvider)) ColoredBox(key: playerSwitchCoverKey, color: tokens.scrim),
                  // The click surface, beneath the bar so the bar's own buttons win
                  // the hit test and its background absorbs rather than falls through.
                  // Kept in audio-only too. It was gated off to let the music
                  // layout's buttons be clicked, which did not work — the opaque
                  // `MouseRegion` above it was the real blocker — and the gate cost
                  // tap-to-pause and double-click-to-fullscreen for nothing. The
                  // layout now sits above this instead.
                  Semantics(
                    button: true,
                    label: 'Play or pause',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _onTap,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  if (widget.child != null) // Before the bar: what the slates hold is a problem the viewer has to act on (Try
                    // again, Notify me, Sign in) and comes first. In fullscreen the queue's toggle and
                    // the queue carry their own larger numbers and still follow the controls.
                    FocusTraversalOrder(order: const NumericFocusOrder(0.5), child: widget.child!),
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
                    child: _BusySpinner(engine: widget.engine, onBusyChanged: _onBusyChanged),
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
                  if (ref.watch(playerViewProvider.select((view) => view.fullscreen)) && !ref.watch(audioModeProvider))
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
                        alwaysIncludeSemantics: true,
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
                                border: Border.all(color: tokens.onScrim.withValues(alpha: 0x1F / 0xFF)),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildHoverable(
                                      _VerticalVolume(
                                        key: playerVerticalVolumeKey,
                                        engine: widget.engine,
                                        onChanged: _wake,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    if (ref.watch(captionsProvider.select((c) => c.hasTracks))) ...[
                                      KeyedSubtree(
                                        key: captionsButtonAnchorKey,
                                        child: _buildHoverable(
                                          _MenuButton(
                                            key: playerCaptionsKey,
                                            icon: ref.watch(captionsProvider.select((c) => c.isOn)) ? Icons.closed_caption : Icons.closed_caption_outlined,
                                            label: 'Captions',
                                            action: PlayerAction.captions,
                                            busy: ref.watch(captionsProvider.select((c) => c.isLoadingTrack)),
                                            open: ref.watch(
                                              playerMenuProvider.select(
                                                (menu) => menu.open && menu.page == SettingsPage.captions,
                                              ),
                                            ),
                                            onPressed: _toggleCaptions,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                    ],
                                    KeyedSubtree(
                                      key: qualityButtonAnchorKey,
                                      child: _buildHoverable(
                                        _MenuButton(
                                          key: playerQualityButtonKey,
                                          icon: Icons.hd_outlined,
                                          label: 'Quality',
                                          busy: ref.watch(playbackProvider.select((p) => p.isSwitchingQuality)),
                                          open: ref.watch(
                                            playerMenuProvider.select(
                                              (menu) => menu.open && menu.page == SettingsPage.quality,
                                            ),
                                          ),
                                          onPressed: ref.watch(playbackProvider.select((p) => p.variants.isEmpty)) ? null : _toggleQuality,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    KeyedSubtree(
                                      key: settingsMenuAnchorKey,
                                      child: _buildHoverable(
                                        _MenuButton(
                                          key: playerSettingsButtonKey,
                                          icon: Icons.settings,
                                          label: 'Settings',
                                          open: ref.watch(
                                            playerMenuProvider.select(
                                              (menu) => menu.open && _isGearPage(menu.page),
                                            ),
                                          ),
                                          onPressed: _toggleMenu,
                                        ),
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
                    // `alwaysIncludeSemantics` here and on the vertical column: the Sliders
                    // in here must never have their semantics skipped while hidden
                    // (architecture.md F51).
                    child: AnimatedOpacity(
                      key: playerControlsBarKey,
                      alwaysIncludeSemantics: true,
                      opacity: _visible ? 1 : 0,
                      duration: _fadeDuration(_visible),
                      curve: Curves.easeIn,
                      child: AnimatedSlide(
                        offset: Offset.zero.translate(0, _visible ? 0 : 0.15),
                        duration: _fadeDuration(_visible),
                        curve: _visible ? Curves.decelerate : Curves.easeInExpo,
                        // **Focusable while hidden, and focusing it shows it**
                        // (`_onFocusInsideChanged`). It was `ExcludeFocus` while hidden, but
                        // Tab runs in the same key event that wakes the bar, so it found the
                        // controls still excluded and skipped them: every walk of the watch
                        // page started at the queue instead of the player.
                        child: IgnorePointer(
                          ignoring: !_visible,
                          child: GestureDetector(
                            // Absorbs. A click on the bar's background is not a click on
                            // the video, and must not pause it.
                            behavior: HitTestBehavior.opaque,
                            // Not a semantic tap target: its tap node *merges* its descendants,
                            // which is where a control's tooltip overlay was grafted (F51).
                            excludeFromSemantics: true,
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
                              child: FocusTraversalOrder(
                                order: const NumericFocusOrder(1),
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: _isVertical ? _buildVerticalBar(context) : (ref.watch(audioModeProvider) ? _buildAudioBar(context) : _buildBar(context)),
                                ),
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
          ),
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    final playback = ref.watch(playbackProvider);
    final captions = ref.watch(captionsProvider);
    final isAudioOnly = ref.watch(audioModeProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHoverable(
          _Scrubber(
            key: playerScrubberKey,
            engine: widget.engine,
            dragging: _dragging,
            hold: playback.hold,
            source: playback.source,
            audioOnly: isAudioOnly,
            enabled: !playback.isUnplayable,
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
                  _TransportControls(engine: widget.engine, onWake: _wake, buildHoverable: _buildHoverable, enabled: !playback.isUnplayable),
                  _buildHoverable(
                    _Volume(engine: widget.engine, compact: compact, onChanged: _wake),
                  ),
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
                        source: playback.source,
                      ),
                    ),
                  ),
                  // **Captions, and absent entirely when the video has none.**
                  // Not disabled: an empty track list is a settled answer once
                  // `captions.list` has answered (`protocol.md` §3.8 — the
                  // `MWEB` fallback has already run), so a greyed button would
                  // promise something that is never coming for this video. The
                  // gap left in Task 16 was the placeholder for this.
                  //
                  // Filled when captions are on, outlined when off — the one
                  // other control here that reports state rather than action is
                  // theatre, and for the same reason: "on" is the fact worth
                  // reading at a glance.
                  if (captions.hasTracks && !isAudioOnly)
                    KeyedSubtree(
                      key: captionsButtonAnchorKey,
                      child: _buildHoverable(
                        _MenuButton(
                          key: playerCaptionsKey,
                          icon: captions.isOn ? Icons.closed_caption : Icons.closed_caption_outlined,
                          label: 'Captions',
                          action: PlayerAction.captions,
                          busy: captions.isLoadingTrack,
                          open: ref.watch(
                            playerMenuProvider.select(
                              (menu) => menu.open && menu.page == SettingsPage.captions,
                            ),
                          ),
                          onPressed: _toggleCaptions,
                        ),
                      ),
                    ),
                  if (!isAudioOnly)
                    KeyedSubtree(
                      key: qualityButtonAnchorKey,
                      child: _buildHoverable(
                        _MenuButton(
                          key: playerQualityButtonKey,
                          icon: Icons.hd_outlined,
                          label: 'Quality',
                          busy: playback.isSwitchingQuality,
                          open: ref.watch(
                            playerMenuProvider.select(
                              (menu) => menu.open && menu.page == SettingsPage.quality,
                            ),
                          ),
                          onPressed: playback.variants.isEmpty ? null : _toggleQuality,
                        ),
                      ),
                    ),
                  KeyedSubtree(
                    key: settingsMenuAnchorKey,
                    child: _buildHoverable(
                      _MenuButton(
                        key: playerSettingsButtonKey,
                        icon: Icons.settings,
                        label: 'Settings',
                        open: ref.watch(
                          playerMenuProvider.select(
                            (menu) => menu.open && _isGearPage(menu.page),
                          ),
                        ),
                        onPressed: _toggleMenu,
                      ),
                    ),
                  ),
                  _ViewControls(onWake: _wake, buildHoverable: _buildHoverable),
                  const SizedBox(width: 4),
                ],
              ),
            );
          },
        ),
      ],
    ).withScrimForeground(tokens);
  }

  Widget _buildAudioBar(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    final playback = ref.watch(playbackProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHoverable(
          _Scrubber(
            key: playerScrubberKey,
            engine: widget.engine,
            dragging: _dragging,
            hold: playback.hold,
            source: playback.source,
            audioOnly: true,
            enabled: !playback.isUnplayable,
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
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 640;
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Row(
                children: [
                  _TransportControls(engine: widget.engine, onWake: _wake, buildHoverable: _buildHoverable, enabled: !playback.isUnplayable),
                  _buildHoverable(
                    _Volume(engine: widget.engine, compact: compact, onChanged: _wake),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _Clock(
                        engine: widget.engine,
                        dragging: _dragging,
                        hold: playback.hold,
                        source: playback.source,
                      ),
                    ),
                  ),
                  KeyedSubtree(
                    key: settingsMenuAnchorKey,
                    child: _buildHoverable(
                      _MenuButton(
                        key: playerSettingsButtonKey,
                        icon: Icons.settings,
                        label: 'Settings',
                        open: ref.watch(
                          playerMenuProvider.select(
                            (menu) => menu.open && _isGearPage(menu.page),
                          ),
                        ),
                        onPressed: _toggleMenu,
                      ),
                    ),
                  ),
                  _ViewControls(onWake: _wake, buildHoverable: _buildHoverable),
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
    final view = ref.watch(playerViewProvider);
    final playback = ref.watch(playbackProvider);
    final isAudioOnly = ref.watch(audioModeProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 6, 6),
      child: Row(
        children: [
          _TransportControls(engine: widget.engine, onWake: _wake, buildHoverable: (child) => child, enabled: !playback.isUnplayable),
          const SizedBox(width: 4),
          _Clock(
            engine: widget.engine,
            dragging: _dragging,
            hold: playback.hold,
            source: playback.source,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Scrubber(
              key: playerScrubberKey,
              engine: widget.engine,
              dragging: _dragging,
              hold: playback.hold,
              source: playback.source,
              audioOnly: isAudioOnly,
              enabled: !playback.isUnplayable,
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
            action: PlayerAction.fullscreen,
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
  const _ControlIcon({
    required this.iconKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.action,
  });

  final Key iconKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Which keyboard shortcut does the same thing, if any — drives the
  /// tooltip's badge. See `ShortcutTooltip`.
  final PlayerAction? action;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    return ShortcutTooltip(
      silent: true, // F51
      label: label,
      action: action,
      child: IconButton(
        key: iconKey,
        mouseCursor: onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        icon: Icon(icon, semanticLabel: label),
        color: tokens.onScrim,
        disabledColor: tokens.onScrim.withValues(alpha: 0.35),
        onPressed: onPressed,
      ),
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
  const _BusySpinner({required this.engine, required this.onBusyChanged});

  final PlaybackEngine engine;

  /// Fired whenever the spinner's own on-screen state flips — never polled,
  /// so the bar's hide timer can key off exactly what the viewer sees rather
  /// than the raw (and grace-delayed) busy signal underneath it.
  final ValueChanged<bool> onBusyChanged;

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
      if (_shown) {
        setState(() => _shown = false);
        widget.onBusyChanged(false);
      }
      return;
    }
    // Already counting, or already up. Restarting the timer on every tick of a
    // sustained wait would mean the spinner never appears at all.
    if (_shown || (_graceTimer?.isActive ?? false)) return;
    _graceTimer = Timer(busySpinnerDelay, () {
      if (!mounted || !_busy()) return;
      setState(() => _shown = true);
      widget.onBusyChanged(true);
    });
  }

  bool _busy() {
    final playback = ref.read(playbackProvider);
    return _buffering ||
        playback.isSwitchingQuality ||
        playback.isLoading ||
        playback.isRestoringVideo;
  }

  @override
  Widget build(BuildContext context) {
    // Watched as well as read, so a switch starting or ending drives this even
    // though it arrives through Riverpod rather than through the stream above.
    ref.listen(
      playbackProvider.select((p) => p.isSwitchingQuality || p.isLoading || p.isRestoringVideo),
      (_, _) => _update(),
    );

    if (!_shown) return const SizedBox.shrink();
    // `primaryFixed` rather than `primary`: a fixed light tone of the accent,
    // one step lighter than the role the rest of the player paints with —
    // legible over an arbitrary video frame without reading as saturated.
    final accent = Theme.of(context).colorScheme.primaryFixed;
    return Center(
      key: playerBusySpinnerKey,
      child: SizedBox(
        width: 48,
        height: 48,
        child: CircularProgressIndicator(color: accent, strokeWidth: 3),
      ),
    );
  }
}

/// Position, buffered range and duration.
///
/// **Seeks on release, never during the drag.** F15 measured a 1.2–1.3 s stall
/// per seek, so a scrubber that seeked continuously would fire dozens across one
/// drag and the video would be unreachable for the length of it.
///
/// Chapter segments, the hover growth and the bubble are `architecture.md`
/// §2.7. They change what the `Slider` paints and what surrounds it, never what
/// it does: seeking is untouched.
class _Scrubber extends ConsumerStatefulWidget {
  const _Scrubber({
    super.key,
    required this.engine,
    required this.dragging,
    required this.hold,
    required this.source,
    required this.audioOnly,
    required this.enabled,
    required this.onDrag,
    required this.onDragEnd,
  });

  /// Suppresses the buffered range — see the note where it is read.
  final bool audioOnly;

  /// False when nothing is open — a premiere, a members-only video, a failure.
  /// The `Slider` is still there, so focus and semantics are its own, but it is
  /// disabled: no drag, no tap, no thumb, and none of the hover growth or the
  /// bubble, which have no time to name.
  final bool enabled;

  final PlaybackEngine engine;
  final double? dragging;
  final PlaybackSource? source;

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
  ConsumerState<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends ConsumerState<_Scrubber> with SingleTickerProviderStateMixin {
  late final SegmentGrowth _growth = SegmentGrowth(this);

  /// The pointer's x in the scrubber's box, null when it is elsewhere. Read by
  /// the bubble alone, so a pointer move rebuilds that and nothing else.
  final ValueNotifier<double?> _pointerX = ValueNotifier<double?>(null);

  /// What the pointer handlers need from the last build. Null when the bar has
  /// no time to show — live, or no duration yet — which is also when hovering
  /// does nothing.
  ScrubberTimeline? _timeline;
  EdgeInsets _padding = EdgeInsets.zero;

  @override
  void dispose() {
    _growth.dispose();
    _pointerX.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_Scrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dragging != widget.dragging) _retarget();
  }

  double? _boxWidth() {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.width : null;
  }

  /// The position the bubble names: the thumb's while it is held, else the
  /// pointer's — null when neither is on the bar.
  Duration? _shownPosition(ScrubberTimeline timeline, double? pointerX, double? boxWidth) {
    final dragging = widget.dragging;
    if (dragging != null) return Duration(milliseconds: dragging.round().clamp(0, timeline.duration.inMilliseconds));
    if (pointerX == null || boxWidth == null) return null;
    final track = scrubberTrackSpan(boxWidth, _padding);
    return trackTimeAt(pointerX, trackLeft: track.left, trackWidth: track.width, duration: timeline.duration);
  }

  void _retarget() {
    final timeline = _timeline;
    final position = timeline == null ? null : _shownPosition(timeline, _pointerX.value, _boxWidth());
    _growth.retarget(position == null ? null : timeline!.segmentAt(position));
  }

  void _onPointer(double? dx) {
    _pointerX.value = _timeline == null ? null : dx;
    _retarget();
  }

  /// A finger lifting takes the bubble with it; a mouse leaves it until it
  /// leaves the bar, unless it was released somewhere else.
  void _onPointerUp(PointerUpEvent event) {
    final box = context.findRenderObject();
    final outside = box is RenderBox && box.hasSize && !(Offset.zero & box.size).contains(box.globalToLocal(event.position));
    if (event.kind != PointerDeviceKind.mouse || outside) _onPointer(null);
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final hold = widget.hold;
    final source = widget.source;
    final dragging = widget.dragging;

    // Chapters are one video's: keyed by its id, so a list can never paint on
    // the next video, and a new video starts with nothing hovered.
    final videoId = ref.watch(playbackProvider.select((playback) => playback.item?.id));
    final chapters = videoId == null ? null : ref.watch(videoInfoProvider(videoId).select((info) => info.value?.chapters));
    ref.listen(playbackProvider.select((playback) => playback.item?.id), (_, _) {
      _pointerX.value = null;
      _growth.reset();
    });

    return StreamBuilder<Duration>(
      stream: engine.positionStream,
      initialData: engine.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: engine.bufferStream,
          initialData: engine.buffer,
          builder: (context, bufferSnapshot) {
            double durationMs = (hold?.duration ?? engine.duration).inMilliseconds.toDouble();
            double max = math.max(durationMs, 1.0);
            double positionMs = (hold?.position ?? positionSnapshot.data ?? Duration.zero).inMilliseconds.toDouble();
            // **No buffered range in audio-only, because there is no honest one
            // to draw.** `vid=no` tears the video demuxer down, and mpv's cache
            // properties report *that* demuxer — measured 2026-09-22,
            // `demuxer-cache-duration` reads 0.000000 for the whole audio-only
            // phase while audio keeps playing from a cache nothing exposes. So
            // media_kit's `buffer` stops advancing and the bar freezes at
            // whatever it last saw, which claims the stream stopped buffering
            // when it did not. Drawing nothing says "not known"; leaving the
            // stale bar up says something false.
            double bufferedMs = widget.audioOnly ? 0.0 : (bufferSnapshot.data ?? Duration.zero).inMilliseconds.toDouble();

            double value = (dragging ?? positionMs).clamp(0.0, max);
            double? unplayableEndFraction;

            // The same duration `max` is built from, so the segments and the
            // thumb cannot disagree during a quality switch. A live stream has
            // neither segments nor bubble: its bar is a moving window, not a
            // timeline (§2.7).
            final live = source != null && source.durationMs == null;
            final timeline = live || durationMs <= 0 || !widget.enabled
                ? null
                : ScrubberTimeline(
                    duration: Duration(milliseconds: durationMs.round()),
                    chapters: chapters ?? const [],
                  );
            _timeline = timeline;

            if (source?.durationMs == null && source?.startTimestamp != null) {
              final start = DateTime.parse(source!.startTimestamp!).toLocal();
              final now = DateTime.now();
              final liveEdgeMs = math.max(now.difference(start).inMilliseconds.toDouble(), 1.0);

              final playheadOffsetMs = durationMs - positionMs;
              final absoluteValueMs = liveEdgeMs - playheadOffsetMs;

              max = liveEdgeMs;
              value = (dragging ?? absoluteValueMs).clamp(0.0, max);

              final bufferOffsetMs = durationMs - bufferedMs;
              bufferedMs = (liveEdgeMs - bufferOffsetMs).clamp(0.0, max);

              final unplayableEndMs = liveEdgeMs - durationMs;
              unplayableEndFraction = (unplayableEndMs / max).clamp(0.0, 1.0);
            }

            void handleDrag(double absoluteValue) {
              if (unplayableEndFraction != null) {
                final unplayableEndMs = max * unplayableEndFraction;
                final clampedAbsolute = absoluteValue.clamp(unplayableEndMs, max);
                // Convert back to relative
                final relativeValue = clampedAbsolute - unplayableEndMs;
                widget.onDrag(relativeValue);
              } else {
                widget.onDrag(absoluteValue);
              }
            }

            void handleDragEnd(double absoluteValue) {
              if (unplayableEndFraction != null) {
                final unplayableEndMs = max * unplayableEndFraction;
                final clampedAbsolute = absoluteValue.clamp(unplayableEndMs, max);
                final relativeValue = clampedAbsolute - unplayableEndMs;
                widget.onDragEnd(relativeValue);
              } else {
                widget.onDragEnd(absoluteValue);
              }
            }

            final pad = SliderTheme.of(context).padding ?? const EdgeInsets.symmetric(horizontal: 12.0);
            _padding = (pad / 1.5).resolve(Directionality.of(context));

            // The whole bar is one segment when there are no chapters, so it
            // grows on hover the same way.
            final segments = timeline == null ? null : TrackSegments(timeline.segments, _growth.values);

            return Stack(
              clipBehavior: Clip.none,
              children: [
                MouseRegion(
                  opaque: false,
                  onHover: (event) => _onPointer(event.localPosition.dx),
                  onExit: (_) => _onPointer(null),
                  // Moves and releases reach a `Listener` during a drag, when
                  // `onHover` does not.
                  child: Listener(
                    onPointerDown: (event) => _onPointer(event.localPosition.dx),
                    onPointerMove: (event) => _onPointer(event.localPosition.dx),
                    onPointerUp: _onPointerUp,
                    onPointerCancel: (_) => _onPointer(null),
                    child: ListenableBuilder(
                      listenable: _growth,
                      builder: (context, _) => SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: ScrubberMetrics.trackHeight,
                          trackShape: _RillSliderTrackShape(unplayableEndFraction: unplayableEndFraction, segments: segments),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                          // No thumb while disabled: there is no position to mark.
                          thumbShape: widget.enabled ? const RoundSliderThumbShape(enabledThumbRadius: 6) : SliderComponentShape.noThumb,
                          inactiveTrackColor: Theme.of(context).tokens.onScrim.withValues(alpha: 0.25),
                          // The same track, not the theme's default disabled grey.
                          disabledInactiveTrackColor: Theme.of(context).tokens.onScrim.withValues(alpha: 0.25),
                          disabledActiveTrackColor: Theme.of(context).tokens.onScrim.withValues(alpha: 0.25),
                          padding: pad / 1.5,
                        ),
                        child: ScrubberBar(
                          value: value,
                          max: max,
                          secondaryTrackValue: bufferedMs.clamp(value, max),
                          // The position as a duration, not "8%": the value is milliseconds.
                          semanticFormatterCallback: (v) => '${spokenDuration(Duration(milliseconds: v.round()))} of ${spokenDuration(Duration(milliseconds: max.round()))}',
                          onChanged: widget.enabled ? handleDrag : null,
                          onChangeEnd: widget.enabled ? handleDragEnd : null,
                        ),
                      ),
                    ),
                  ),
                ),
                // In-tree rather than a `Tooltip`: nothing above the `Navigator`
                // has an `Overlay` (§2.8), and a bubble that could not be drawn
                // there would throw. Painted outside the box, so the `Stack`
                // must not clip and the bubble must not be hit.
                if (timeline != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ValueListenableBuilder<double?>(
                        valueListenable: _pointerX,
                        builder: (context, pointerX, _) => _buildBubble(timeline, pointerX),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// The timestamp under the pointer — or under the thumb while it is held —
  /// and the chapter it falls in. Follows the pointer, clamped inside the bar.
  Widget _buildBubble(ScrubberTimeline timeline, double? pointerX) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final position = _shownPosition(timeline, pointerX, constraints.maxWidth);
        if (position == null) return const SizedBox.shrink();
        final track = scrubberTrackSpan(constraints.maxWidth, _padding);
        final anchorX = trackXAt(position, trackLeft: track.left, trackWidth: track.width, duration: timeline.duration);
        return CustomSingleChildLayout(
          delegate: ScrubberBubbleLayout(anchorX: anchorX),
          child: ScrubberBubble(
            key: playerScrubberBubbleKey,
            timestamp: formatClock(position),
            title: timeline.chapterTitleAt(position),
          ),
        );
      },
    );
  }
}

class _Clock extends StatelessWidget {
  const _Clock({required this.engine, required this.dragging, required this.hold, this.source});

  final PlaybackEngine engine;
  final double? dragging;

  /// See [_Scrubber.hold]. Same sources, same order — a clock reading
  /// `0:00 / 0:00` beside a scrubber holding 3:12 would be its own kind of wrong.
  final PlaybackHold? hold;
  final PlaybackSource? source;

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

        if (source?.durationMs == null && source != null) {
          Widget timeWidget;
          if (source!.startTimestamp != null) {
            final start = DateTime.parse(source!.startTimestamp!).toLocal();
            final now = DateTime.now();
            final liveEdgeUptime = now.difference(start);
            final playheadOffset = duration - position;
            final absoluteUptime = liveEdgeUptime - playheadOffset;
            timeWidget = Text(
              formatClock(absoluteUptime.isNegative ? Duration.zero : absoluteUptime),
              style: const TextStyle(fontSize: 12),
            );
          } else {
            timeWidget = Text(
              formatClock(position),
              style: const TextStyle(fontSize: 12),
            );
          }

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              timeWidget,
              const SizedBox(width: 6),
              Icon(Icons.circle, size: 6, color: Theme.of(context).tokens.liveBadge),
              const SizedBox(width: 4),
              const Text(
                'LIVE',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          );
        }

        return Text(
          '${formatClock(position)} / ${formatClock(duration)}',
          semanticsLabel: '${spokenDuration(position)} of ${spokenDuration(duration)}',
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

        // Focus opens it as the pointer does: Tab onto the speaker shows the
        // slider, and the next Tab lands on it. Without this a keyboard user
        // could never change the volume — the slider is not mounted while closed.
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          // Only for the keyboard: focus a click left behind opens nothing.
          onFocusChange: (has) => has ? (KeyboardNavigation.active ? _enter() : null) : _exit(),
          child: MouseRegion(
            // One region over the button *and* the slider, so travelling from one
            // to the other never leaves it.
            onEnter: (_) => _enter(),
            onExit: (_) => _exit(),
            child: Stack(
              fit: StackFit.loose,
              children: [
                _ControlIcon(
                  iconKey: playerMuteKey,
                  icon: volume == 0 ? Icons.volume_off : (volume < 50 ? Icons.volume_down : Icons.volume_up),
                  label: volume == 0 ? 'Unmute' : 'Mute',
                  action: PlayerAction.mute,
                  onPressed: () {
                    widget.onChanged();
                    unawaited(ref.read(playbackProvider.notifier).toggleMute());
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 42),
                  // Outside the `ClipRect`: inside it the bubble was cut to the slider's 120x40.
                  child: ShortcutTooltip(
                    silent: true,
                    announce: false, // the bar says "Volume 100%" itself
                    label: 'Volume: ${volume.round()}%',
                    child: ClipRect(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        key: playerVolumeSliderKey,
                        width: open ? 120 : 0,
                        height: 40,
                        // Not mounted while collapsed, so Tab cannot land on it. Not a
                        // Material `Slider`: that one's value-indicator `OverlayPortal`
                        // double-parents its semantics node here (§F51).
                        child: AnimatedCrossFade(
                          duration: const Duration(milliseconds: 140),
                          crossFadeState: open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                          firstChild: const SizedBox.shrink(),
                          secondChild: VolumeBar(
                            value: volume,
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
              ],
            ),
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

        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onFocusChange: (has) => has ? (KeyboardNavigation.active ? _enter() : null) : _exit(),
          child: MouseRegion(
            onEnter: (_) => _enter(),
            onExit: (_) => _exit(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The tooltip is outside the `ClipRect` (inside, it is cut to the slider) and the
                // `RotatedBox` (it would be drawn sideways), and opens to the left of the slider.
                ShortcutTooltip(
                  silent: true,
                  announce: false,
                  side: TooltipSide.left,
                  label: 'Volume: ${volume.round()}%',
                  child: ClipRect(
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
                            child: !_open
                                ? const SizedBox.shrink()
                                : VolumeBar(
                                    value: volume,
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
                  action: PlayerAction.mute,
                  onPressed: () {
                    widget.onChanged();
                    unawaited(ref.read(playbackProvider.notifier).toggleMute());
                  },
                ),
              ],
            ),
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
    required this.label,
    required this.open,
    required this.onPressed,
    this.busy = false,
    this.action,
  });

  final IconData icon;

  /// Tooltip text, and — new — the icon's `semanticLabel` too: captions,
  /// quality and settings had no accessible text at all before this, visual
  /// or otherwise.
  final String label;
  final bool open;

  /// Null draws it disabled — the quality button with an empty ladder.
  final VoidCallback? onPressed;

  final bool busy;

  /// Which keyboard shortcut does the same thing, if any. Captions is the
  /// only one of the three with one today; quality and settings have none.
  final PlayerAction? action;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).tokens;

    return ShortcutTooltip(
      silent: true, // F51
      label: label,
      action: action,
      child: IconButton(
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
            : Icon(icon, semanticLabel: label),
      ),
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
  final double? unplayableEndFraction;

  /// One segment per chapter, or the whole bar as one; null draws the plain
  /// track, which is what a live stream gets (§2.7).
  final TrackSegments? segments;
  const _RillSliderTrackShape({this.unplayableEndFraction, this.segments});

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

    if (segments != null) {
      paintSegmentedTrack(
        context.canvas,
        trackRect: trackRect,
        thumbX: thumbCenter.dx,
        bufferX: secondaryOffset?.dx,
        segments: segments!,
        played: leftTrackPaint,
        buffered: Paint()..color = sliderTheme.secondaryActiveTrackColor ?? sliderTheme.activeTrackColor!.withValues(alpha: 0.5),
        remaining: rightTrackPaint,
      );
      return;
    }

    // Draw active track
    final Rect leftTrackSegment = Rect.fromLTRB(trackRect.left, trackRect.top, thumbCenter.dx, trackRect.bottom);
    if (!leftTrackSegment.isEmpty) {
      if (unplayableEndFraction != null && unplayableEndFraction! > 0) {
        final unplayableEndX = trackRect.left + (trackRect.width * unplayableEndFraction!);
        if (unplayableEndX < thumbCenter.dx) {
          final Rect unplayableSegment = Rect.fromLTRB(trackRect.left, trackRect.top, unplayableEndX, trackRect.bottom);
          final Rect playableSegment = Rect.fromLTRB(unplayableEndX, trackRect.top, thumbCenter.dx, trackRect.bottom);
          final Paint unplayablePaint = Paint()..color = activePaint.color.withValues(alpha: 0.3);
          context.canvas.drawRect(unplayableSegment, unplayablePaint);
          context.canvas.drawRect(playableSegment, leftTrackPaint);
        } else {
          final Paint unplayablePaint = Paint()..color = activePaint.color.withValues(alpha: 0.3);
          context.canvas.drawRect(leftTrackSegment, unplayablePaint);
        }
      } else {
        context.canvas.drawRect(leftTrackSegment, leftTrackPaint);
      }
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
      final RRect rightTrackSegment = RRect.fromRectAndRadius(
        Rect.fromLTRB(
          bufferRight,
          trackRect.top,
          trackRect.right,
          trackRect.bottom,
        ),
        Radius.circular(trackRect.height / 2),
      );

      if (!rightTrackSegment.isEmpty) {
        context.canvas.drawRRect(rightTrackSegment, rightTrackPaint);
      }
    } else {
      final RRect rightTrackSegmentR = RRect.fromRectAndRadius(
        Rect.fromLTRB(
          thumbCenter.dx,
          trackRect.top,
          trackRect.right,
          trackRect.bottom,
        ),
        Radius.circular(trackRect.height / 2),
      );

      if (!rightTrackSegmentR.isEmpty) {
        context.canvas.drawRRect(rightTrackSegmentR, rightTrackPaint);
      }
    }
  }
}

/// The previous, play/pause and next buttons
class _TransportControls extends ConsumerWidget {
  const _TransportControls({
    required this.engine,
    required this.onWake,
    required this.buildHoverable,
    required this.enabled,
  });

  final PlaybackEngine engine;
  final VoidCallback onWake;
  final Widget Function(Widget child) buildHoverable;

  /// Whether play/pause does anything. Previous and next are **not** gated on
  /// this: skipping past a video that will not open is exactly when they are
  /// wanted.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPrevious = ref.watch(queueProvider.select((q) => q.hasPrevious));
    final hasNext = ref.watch(queueProvider.select((q) => q.hasNext));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasPrevious)
          buildHoverable(
            _ControlIcon(
              iconKey: playerPreviousKey,
              icon: Icons.skip_previous,
              label: 'Previous video',
              action: PlayerAction.previous,
              onPressed: () {
                onWake();
                ref.read(playbackProvider.notifier).previous();
              },
            ),
          ),
        StreamBuilder<bool>(
          stream: engine.playingStream,
          initialData: engine.playing,
          builder: (context, snapshot) {
            final playing = snapshot.data ?? false;
            return buildHoverable(
              _ControlIcon(
                iconKey: playerPlayPauseKey,
                icon: playing ? Icons.pause : Icons.play_arrow,
                label: playing ? 'Pause' : 'Play',
                action: PlayerAction.playPause,
                onPressed: enabled
                    ? () {
                        onWake();
                        unawaited(ref.read(playbackProvider.notifier).togglePlayPause());
                      }
                    : null,
              ),
            );
          },
        ),
        if (hasNext)
          buildHoverable(
            _ControlIcon(
              iconKey: playerNextKey,
              icon: Icons.skip_next,
              label: 'Next video',
              action: PlayerAction.next,
              onPressed: () {
                onWake();
                ref.read(playbackProvider.notifier).next();
              },
            ),
          ),
      ],
    );
  }
}

class _ViewControls extends ConsumerWidget {
  const _ViewControls({
    required this.onWake,
    required this.buildHoverable,
  });

  final VoidCallback onWake;
  final Widget Function(Widget child) buildHoverable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(playerViewProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        buildHoverable(
          _ControlIcon(
            iconKey: playerMiniPlayerKey,
            icon: Icons.branding_watermark_outlined,
            label: 'Miniplayer',
            action: PlayerAction.miniPlayer,
            onPressed: () {
              onWake();
              toMiniPlayer(ref);
            },
          ),
        ),
        buildHoverable(
          _ControlIcon(
            iconKey: playerTheatreKey,
            icon: view.theatre ? Icons.crop_7_5 : Icons.crop_16_9,
            label: view.theatre ? 'Default view' : 'Theatre mode',
            action: PlayerAction.theatre,
            onPressed: () {
              onWake();
              ref.read(playerViewProvider.notifier).toggleTheatre();
            },
          ),
        ),
        buildHoverable(
          _ControlIcon(
            iconKey: playerFullscreenKey,
            icon: view.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            label: view.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
            action: PlayerAction.fullscreen,
            onPressed: () {
              onWake();
              ref.read(playerViewProvider.notifier).toggleFullscreen();
            },
          ),
        ),
      ],
    );
  }
}
