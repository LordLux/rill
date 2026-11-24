/// The player's settings menu: its state, and the panel that draws it.
///
/// **A panel in the controls `Stack`, never a route** — at the fullscreen mount
/// point the controls are above the `Navigator`, so anything that pushes has
/// nothing to push onto (architecture §2.8).
///
/// Open/closed is a provider because two things outside `controls.dart` need it:
/// `Esc` in `shortcuts.dart`, and the click-outside in `player_shell.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../domain/playback_source.dart';
import '../../domain/caption_style.dart';
import '../audio_mode_controller.dart';
import '../captions_controller.dart';
import '../focus_ring.dart';
import '../playback_controller.dart';
import '../sleep_timer.dart';
import '../video_info.dart';

const Key playerSettingsButtonKey = ValueKey('player-settings-button');
const Key playerQualityButtonKey = ValueKey('player-quality-button');
const Key playerSettingsMenuKey = ValueKey('player-settings-menu');
const Key playerSettingsMoreRowKey = ValueKey('player-settings-more-row');
const Key playerSettingsBackKey = ValueKey('player-settings-back');

/// The decoded height, on the quality page's header.
const Key playerQualityHeaderKey = ValueKey('player-quality-header');

/// The spinner on the selected quality row while a switch to it is in flight.
const Key playerQualityLoadingKey = ValueKey('player-quality-loading');

/// The caption page and its Off row — `player_captions_test.dart` finds them by
/// these rather than by label, so wording changes do not break the suite.
const Key playerCaptionsMenuKey = ValueKey('player-captions-menu');
const Key playerCaptionsOffKey = ValueKey('player-captions-off');

/// The row into the style page, and the page's *Reset*.
const Key playerCaptionStyleRowKey = ValueKey('player-caption-style');
const Key playerCaptionStyleMenuKey = ValueKey('player-caption-style-menu');
const Key playerCaptionStyleResetKey = ValueKey('player-caption-style-reset');

/// The tallest the panel may get, subpage included.
const double settingsMenuMaxHeight = 400;

/// How long the panel takes to resize between pages.
const Duration settingsMenuMorph = Duration(milliseconds: 180);

/// How long the panel takes to appear and to go away.
///
/// Shorter than the page morph on purpose. The morph is the panel *doing*
/// something and is worth watching; opening is just the panel arriving, and a
/// slow arrival is a control that feels like it did not hear the click.
const Duration settingsMenuFade = Duration(milliseconds: 120);

/// Which page the panel is showing.
///
/// **[quality] is a top level, not a subpage.** It has its own button on the
/// bar, so it is not reached *through* the root and has nothing to go back to —
/// which is why [PlayerMenuController.back] answers false for it and its header
/// carries no chevron. [moreOptions] is the only real subpage.
/// The panel's pages.
///
/// `captions` is a third *top level*, not a child of `root`: it has its own bar
/// button beside quality's, so reaching it through the gear would be a second
/// route to a place that already has a door. [_depthOf] and [back] both encode
/// that — only `moreOptions` is under anything.
///
/// The sleep timer's three pages (Task 38) are under the root: [sleepTimer] one level down, and its
/// *Custom…* and *When it ends* pages under that.
///
/// [audioTrack] (Task 39) is under the root, one level down, and is reachable only when the video
/// has more than one audio track.
enum SettingsPage { root, moreOptions, quality, captions, captionStyle, forceStyle, sleepTimer, sleepTimerCustom, sleepTimerAction, audioTrack }

@immutable
class PlayerMenuState {
  const PlayerMenuState({this.open = false, this.page = SettingsPage.root});

  final bool open;
  final SettingsPage page;

  @override
  bool operator ==(Object other) => other is PlayerMenuState && other.open == open && other.page == page;

  @override
  int get hashCode => Object.hash(open, page);
}

class PlayerMenuController extends Notifier<PlayerMenuState> {
  @override
  PlayerMenuState build() {
    // Losing the video takes the menu with it. Otherwise a menu opened on the
    // last video in a queue outlives the thing every one of its rows is about.
    // This also ensures that if a new video starts, the menu is closed, so
    // reopening it remounts the pages (like CaptionsPage) and triggers their initState.
    ref.listen(playbackProvider.select((playback) => playback.item?.id), (previous, next) {
      if (previous != next) close();
    });
    return const PlayerMenuState();
  }

  /// One press of one of the two buttons on the bar.
  ///
  /// **Closes only when it is already showing that page.** The gear pressed over
  /// an open quality panel means "show me the settings", not "go away"; the same
  /// press over the settings list means the second thing. Modelling it as
  /// toggle-per-page rather than one open flag is what keeps the two buttons
  /// from having to know about each other.
  void toggleAt(SettingsPage page) {
    if (state.open && state.page == page) {
      close();
      return;
    }
    state = PlayerMenuState(open: true, page: page);
  }

  void toggle() => toggleAt(SettingsPage.root);

  /// Always at the root — see [close] for why the reset lives here.
  void open() => state = const PlayerMenuState(open: true);

  /// **Closing does not reset the page; opening does.** The panel is still on
  /// screen and still watching this state for the length of [settingsMenuFade],
  /// so resetting here flashes the root list past on the way out.
  void close() {
    if (!state.open) return;
    state = PlayerMenuState(open: false, page: state.page);
  }

  void go(SettingsPage page) => state = PlayerMenuState(open: true, page: page);

  /// The subpage's back arrow. Returns whether there was anywhere to go, so a
  /// caller can tell "went back" from "nothing to do".
  ///
  /// Only [SettingsPage.moreOptions] is under anything. Quality is its own top
  /// level — see [SettingsPage].
  bool back() {
    final up = switch (state.page) {
      SettingsPage.moreOptions || SettingsPage.sleepTimer || SettingsPage.audioTrack => SettingsPage.root,
      SettingsPage.sleepTimerCustom || SettingsPage.sleepTimerAction => SettingsPage.sleepTimer,
      _ => null,
    };
    if (up == null) return false;
    state = PlayerMenuState(open: true, page: up);
    return true;
  }
}

final playerMenuProvider = NotifierProvider<PlayerMenuController, PlayerMenuState>(PlayerMenuController.new);

/// Where the panel is on screen, for the window-wide click-outside.
///
/// **A key rather than a flag set on pointer-down.** The alternative — the panel
/// noting "that one was mine" and the ancestor listener checking it — works only
/// because pointer events dispatch innermost-first, which is true and is exactly
/// the kind of true that stops being true after somebody reorders a `Stack`.
/// Asking the panel's own `RenderBox` whether it contains the point does not
/// depend on dispatch order at all. See [pointerIsOnSettingsMenu].
final GlobalKey settingsMenuPanelKey = GlobalKey();

/// The gear counts as part of the menu's surface, which is what makes a second
/// click close it rather than reopen it: otherwise the click-outside listener
/// closes on pointer-down and `toggle()` reopens on pointer-up.
///
/// Only one is ever mounted — the bar's buttons and the vertical column's are
/// opposite sides of the same `_isVertical`.
final GlobalKey settingsMenuAnchorKey = GlobalKey();

/// The quality button, the menu's other anchor.
///
/// It opens the same panel at a different page, so it earns the same exemption
/// for the same reason: pressing it while its own page is up has to close, and
/// it cannot if the press already closed on the way down.
final GlobalKey qualityButtonAnchorKey = GlobalKey();

/// The CC button, the menu's third anchor, for the same reason as the second.
///
/// Unlike the other two this one is **not always mounted** — it is absent on a
/// video with no caption tracks — and [_hits] answers false for an unmounted
/// key, which is the right answer: a button that is not there cannot have been
/// clicked.
final GlobalKey captionsButtonAnchorKey = GlobalKey();

/// The sleep timer's moon on the bar, which opens the timer page: an anchor for the same reason as
/// the other three (Task 38). Absent while no timer is set, and [_hits] answers false for that.
final GlobalKey sleepTimerAnchorKey = GlobalKey();

/// Whether a global pointer position landed on the menu — the panel, or either
/// of the buttons that open it.
///
/// False when none is mounted, which is the case the caller wants anyway: with
/// no menu up there is no click-outside to detect.
bool pointerIsOnSettingsMenu(Offset globalPosition) =>
    _hits(settingsMenuPanelKey, globalPosition) || //
    _hits(settingsMenuAnchorKey, globalPosition) ||
    _hits(qualityButtonAnchorKey, globalPosition) ||
    _hits(captionsButtonAnchorKey, globalPosition) ||
    _hits(sleepTimerAnchorKey, globalPosition);

bool _hits(GlobalKey key, Offset globalPosition) {
  final box = key.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return false;
  return (box.localToGlobal(Offset.zero) & box.size).contains(globalPosition);
}

/// Mounts [child] while [visible], and keeps it mounted — faded out and
/// pointer-dead — for exactly as long as the fade takes.
///
/// **One child instance, ever** — which is why this exists rather than an
/// `AnimatedSwitcher`. That holds the outgoing child alongside the incoming one,
/// so a second open mid-fade puts two panels in the tree both carrying
/// [settingsMenuPanelKey], and one `GlobalKey` on two widgets throws.
/// Double-clicking the gear is not an exotic input.
class SettingsMenuFade extends StatefulWidget {
  const SettingsMenuFade({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<SettingsMenuFade> createState() => _SettingsMenuFadeState();
}

class _SettingsMenuFadeState extends State<SettingsMenuFade> {
  late bool _present = widget.visible;
  Timer? _unmount;

  @override
  void didUpdateWidget(SettingsMenuFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    _unmount?.cancel();
    _unmount = null;
    if (widget.visible) {
      setState(() => _present = true);
    } else {
      _unmount = Timer(settingsMenuFade, () {
        if (mounted) setState(() => _present = false);
      });
    }
  }

  @override
  void dispose() {
    _unmount?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_present) return const SizedBox.shrink();

    return IgnorePointer(
      // Dead the instant it starts leaving. The panel is still painted for
      // another tenth of a second, and a row that answers a click while it is
      // disappearing is a row nobody meant to press.
      ignoring: !widget.visible,
      // **`TweenAnimationBuilder` with an explicit `begin`, not
      // `AnimatedOpacity`.** An implicit opacity animates only when its value
      // *changes*, so on the frame the panel is first built it is simply already
      // at 1 — the open would have no fade at all and only the close would.
      // A tween with `begin: 0` runs on that first build too.
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: widget.visible ? 1 : 0),
        duration: settingsMenuFade,
        curve: Curves.easeOut,
        child: widget.child,
        // `alwaysIncludeSemantics`: a `Slider` in here must never have its
        // semantics skipped (`architecture.md` F51).
        builder: (context, opacity, child) => Opacity(
          opacity: opacity,
          alwaysIncludeSemantics: true,
          child: child,
        ),
      ),
    );
  }
}

/// The panel.
///
/// **It changes size rather than swapping panels.** A subpage is not a different
/// menu, it is the same object showing something else, and the height it settles
/// at is the height of what it is showing — capped at
/// [settingsMenuMaxHeight] and again at whatever the player box allows, so a
/// 22-rung ladder in a short window scrolls instead of running off the top.
class PlayerSettingsMenu extends ConsumerStatefulWidget {
  const PlayerSettingsMenu({super.key, required this.onPicked, this.onPickedHeight});

  /// A quality was chosen. The caller closes the menu and wakes the controls —
  /// this widget does not reach for either.
  final ValueChanged<PlaybackVariant> onPicked;

  /// A height was chosen while the video is still opening and there is no ladder to
  /// pick a rung from (todo 98). Same contract as [onPicked].
  final ValueChanged<int>? onPickedHeight;

  @override
  ConsumerState<PlayerSettingsMenu> createState() => _PlayerSettingsMenuState();
}

class _PlayerSettingsMenuState extends ConsumerState<PlayerSettingsMenu> {
  /// The page this widget last drew, so a change can be told from a rebuild —
  /// and so the *direction* of the change is known before the transition starts.
  SettingsPage _shown = SettingsPage.root;

  /// +1 going deeper, -1 coming back, 0 sideways. Drives which edge each page
  /// enters and leaves by.
  double _direction = 0;

  /// How far a page travels, as a fraction of the panel's width.
  ///
  /// **A quarter, not the whole way.** A full-width slide is what a route
  /// transition does, and this is not a route — the panel is 248 px of chrome
  /// hanging off a button, and content flying the entire width of it reads as
  /// something much bigger than a menu changing pages. A short move plus the
  /// cross-fade says the same thing at the right volume.
  static const double _travel = 0.25;

  /// Root and Quality are both top levels — quality has its own button and is
  /// not reached through the root — so moving between them is sideways and gets
  /// no slide at all. Only *More options* is under anything.
  /// Focus is held by the menu while it is open, so Tab stays inside it and
  /// Escape (which closes it) hands focus back to the button that opened it.
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'player settings menu');

  /// Moves focus to the menu's first row — for a keyboard user only. A click that
  /// opened the menu has no use for a focused row, and one would steal focus from
  /// wherever it was.
  void _takeFocus() {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scope.requestFocus();
    });
  }

  @override
  void initState() {
    super.initState();
    _takeFocus();
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  static int _depthOf(SettingsPage page) => switch (page) {
    SettingsPage.moreOptions || SettingsPage.captionStyle || SettingsPage.sleepTimer || SettingsPage.audioTrack => 1,
    SettingsPage.sleepTimerCustom || SettingsPage.sleepTimerAction => 2,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = ref.watch(playerMenuProvider.select((menu) => menu.page));

    if (page != _shown) {
      // Derived, not stored state — the rebuild that reads it is already
      // happening, so this wants no `setState`.
      _direction = (_depthOf(page) - _depthOf(_shown)).toDouble();
      _shown = page;
      // The row that had focus is on the page that just left.
      _takeFocus();
    }

    // Keyed off the enum rather than by hand, so the key the transition compares
    // against below cannot drift from the key the page was built with.
    final Widget child = KeyedSubtree(
      key: ValueKey(page.name),
      child: switch (page) {
        SettingsPage.root => const _RootPage(),
        SettingsPage.moreOptions => const _MoreOptionsPage(),
        SettingsPage.quality => _QualityPage(onPicked: widget.onPicked, onPickedHeight: widget.onPickedHeight),
        SettingsPage.captions => const _CaptionsPage(),
        SettingsPage.captionStyle => const CaptionStylePage(),
        SettingsPage.forceStyle => const _ForceStylePage(),
        SettingsPage.sleepTimer => const _SleepTimerPage(),
        SettingsPage.sleepTimerCustom => const _SleepCustomPage(),
        SettingsPage.sleepTimerAction => const _SleepActionPage(),
        SettingsPage.audioTrack => const _AudioTrackPage(),
      },
    );

    // Every row fills the panel edge to edge, so the ring sits inside it.
    return FocusRingShape(
      inflate: -1,
      child: FocusScope(
        node: _scope,
        child: Align(
          // Bottom-aligned inside whatever height the `Positioned` allows, so the
          // panel grows upward from the button it belongs to.
          alignment: Alignment.bottomRight,
          child: MouseRegion(
            child: Stack(
              children: [
                const Positioned.fill(child: AbsorbPointer()),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {}, // Absorb taps so they don't fall through to the video
                  child: Material(
                    key: settingsMenuPanelKey,
                    elevation: 8,
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: AnimatedSize(
                      duration: settingsMenuMorph,
                      curve: Curves.easeOutCubic,
                      // From the bottom-right corner, which is the corner pinned to the
                      // button — so growing a taller page pushes the top edge up and leaves
                      // the anchor where it was.
                      alignment: Alignment.bottomRight,
                      child: AnimatedSwitcher(
                        duration: settingsMenuMorph,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        // **The box follows the incoming page, not the larger of the two.**
                        // The default `Stack` takes its biggest child's size, so coming
                        // back from the tall ladder it would hold that height and snap down
                        // at the end, leaving the `AnimatedSize` to morph after the slide
                        // instead of with it. Positioning the outgoing children takes them
                        // out of the sizing; no `bottom`, so they overflow rather than
                        // being squashed into the new page's box on the way out.
                        layoutBuilder: (currentChild, previousChildren) => Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // The outgoing page is not focusable: while it fades, focus must go to
                            // the page that replaced it, not stay on a row about to vanish.
                            for (final previous in previousChildren) Positioned(top: 0, left: 0, right: 0, child: ExcludeFocus(child: previous)),
                            ?currentChild,
                          ],
                        ),
                        transitionBuilder: (child, animation) {
                          // **`transitionBuilder` is called for both directions and is not
                          // told which**, so the child's own key is what distinguishes them.
                          // It matters: on a push the new page has to come from the right
                          // *and the old one leave to the left*. Reusing one tween — the
                          // obvious reading of the API, since the outgoing animation runs in
                          // reverse — sends the old page back out the way the new one came
                          // in, which is the gesture for a pop played over a push.
                          final entering = child.key == ValueKey(_shown.name);
                          final from = (entering ? _direction : -_direction) * _travel;
                          return FadeTransition(
                            opacity: animation,
                            alwaysIncludeSemantics: true,
                            child: SlideTransition(
                              position: Tween<Offset>(begin: Offset(from, 0), end: Offset.zero).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: child,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The rows that have nowhere to go yet — here and in [_morePlaceholders].
///
/// **Drawn as ordinary rows and inert, not disabled.** `_MenuRow` greys out on a
/// null `onTap`, and a page on which every row is grey reads as a menu that
/// broke rather than one that is unfinished — so these take `onTap: () {}` and
/// keep the full contrast, the click cursor and the ripple. The cost is the
/// obvious one and it is accepted knowingly: a click here answers and then does
/// nothing.
///
/// *Auto* on the quality page is the opposite call for the opposite reason. It
/// sits under a ladder of rows that all work, so grey is what separates it from
/// them — and it carries no `InkWell` at all, because a lone dead row among live
/// ones must not take the click that would otherwise reach the video.
///
/// Nothing here has anything behind it — *Playback speed* included, because the
/// engine has no rate control to drive it and wiring one is a
/// `data/playback/engine.dart` change rather than a menu change.
const List<({IconData icon, String label})> _rootPlaceholders = [
  (icon: Icons.slow_motion_video, label: 'Playback speed'),
];

const List<({IconData icon, String label})> _morePlaceholders = [
  (icon: Icons.speaker_outlined, label: 'Audio channel'),
  (icon: Icons.push_pin_outlined, label: 'Sticky player'),
  (icon: Icons.notes_outlined, label: 'Annotations'),
  (icon: Icons.brightness_medium_outlined, label: 'Ambient mode'),
];

/// The width the panel settles at when nothing needs more.
///
/// **One width for every page that fits in it.** The panel morphs its height
/// between pages because the pages genuinely differ in length; letting the width
/// float freely made the whole thing appear to breathe sideways on every
/// navigation, which reads as the menu being unsure of itself. So this is a
/// *floor*, not a fixed size — a page whose content does not fit grows past it
/// (see [_menuMaxWidth]) and every page that does fit still agrees on one width.
const double _menuWidth = 248;

/// How far the panel may grow to fit its content.
///
/// A caption row can carry a long language name, a sub-name and a badge —
/// "English (United Kingdom)" with *Styled* is already past the floor — and
/// truncating the language is worse than a wider menu, because the truncated
/// part is the bit that tells two rows apart.
///
/// Capped rather than unbounded so a pathological label cannot turn the menu
/// into a sheet; past this the label ellipsises as before. The real player width
/// caps it again — `ConstrainedBox` enforces against the incoming constraints —
/// so this never overflows a narrow window.
const double _menuMaxWidth = 380;

class _RootPage extends ConsumerWidget {
  const _RootPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return _MenuBody(
      children: [
        // **First, above the divider, and it is the only live row.** Everything
        // under the divider is a setting; this is a door to more of them, and
        // the divider is what says so — the group is "one of these is not like
        // the others" rather than a heading nobody reads.
        _MenuRow(
          key: playerSettingsMoreRowKey,
          icon: Icons.tune,
          label: 'More options',
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => ref.read(playerMenuProvider.notifier).go(SettingsPage.moreOptions),
        ),
        SizedBox(height: 3),
        Divider(height: 9, indent: 14, endIndent: 14, color: scheme.outlineVariant),
        SizedBox(height: 2),
        Consumer(
          builder: (context, ref, _) {
            final isAudioOnly = ref.watch(audioModeProvider);
            return _MenuRow(
              icon: isAudioOnly ? Icons.headset : Icons.headset_off,
              label: 'Audio Only',
              trailing: Switch(
                value: isAudioOnly,
                onChanged: (val) => ref.read(audioModeProvider.notifier).setMode(val),
              ),
              onTap: () => ref.read(audioModeProvider.notifier).toggle(),
            );
          },
        ),
        const _SleepTimerRow(),
        const _AudioTrackRootRow(),
        for (final row in _rootPlaceholders) _MenuRow(icon: row.icon, label: row.label, onTap: () {}),
      ],
    );
  }
}

class _MoreOptionsPage extends ConsumerWidget {
  const _MoreOptionsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MenuBody(
      header: _MenuHeader(
        title: 'More options',
        onBack: () => ref.read(playerMenuProvider.notifier).back(),
      ),
      children: [
        _MenuRow(
          icon: Icons.format_paint_outlined,
          label: 'Keep caption style',
          trailing: Switch(
            value: ref.watch(keepCaptionStyleProvider),
            onChanged: (value) => ref.read(keepCaptionStyleProvider.notifier).toggle(),
          ),
          onTap: () {
            ref.read(keepCaptionStyleProvider.notifier).toggle();
          },
        ),
        _MenuRow(
          icon: Icons.info_outline,
          label: 'About & Licenses',
          onTap: () {
            ref.read(playerMenuProvider.notifier).close();
            showAboutDialog(
              context: context,
              applicationName: 'NativeYouTube',
              applicationLegalese: 'Includes LGPL-2.1 libraries. See THIRD_PARTY_LICENSES for full compliance details.',
            );
          },
        ),
        for (final row in _morePlaceholders) _MenuRow(icon: row.icon, label: row.label, onTap: () {}),
      ],
    );
  }
}

/// Track list with the current one ticked, plus Off.
///
/// **Off is a row rather than a switch**, and it is first. The list is one
/// question — "which words, if any" — and a toggle beside a list makes it two,
/// with a state where the toggle says on and no track is ticked. Ticking Off is
/// the same gesture as ticking a language.
///
/// The page is never reachable with an empty list: the bar button that opens it
/// is not drawn at all when the video has no tracks (`protocol.md` §3.8 — an
/// empty list is settled, not pending). The empty branch below is for the video
/// changing underneath an already-open panel.
class _CaptionsPage extends ConsumerStatefulWidget {
  const _CaptionsPage();

  @override
  ConsumerState<_CaptionsPage> createState() => _CaptionsPageState();
}

class _CaptionsPageState extends ConsumerState<_CaptionsPage> {
  @override
  void initState() {
    super.initState();
    // Opening this page is what pays for the `Styled` badge: a caption document
    // per track. Deliberately here rather than on the video-open path — see
    // `CaptionsController.loadStyled`. Fired once per mount, and a no-op when
    // the answers are already cached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(captionsProvider.notifier).loadStyled());
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final captions = ref.watch(captionsProvider);
    final controller = ref.read(captionsProvider.notifier);

    return _MenuBody(
      key: playerCaptionsMenuKey,
      // No back arrow, for the same reason quality has none: this is a top
      // level with its own button. The header carries the current language so
      // the answer is readable without scanning the list for a tick.
      header: _MenuHeader(
        title: 'Subtitles',
        value: captions.selected?.label ?? 'Off',
      ),
      children: [
        if (captions.tracks.isEmpty)
          _MenuRow(
            icon: Icons.closed_caption_disabled_outlined,
            label: captions.error != null ? 'Unavailable' : 'None for this video',
            onTap: null,
          )
        else ...[
          for (final track in captions.tracks)
            _CaptionRow(
              label: track.label,
              // Null for `plain`, for "not asked yet", and for a category this
              // build does not know — see `CaptionTrack.styleBadge`. A row that
              // flickers a badge in as the answers land would be worse than one
              // that never had it.
              badge: track.styleBadge,
              trackName: track.trackName,
              selected: captions.selectedId == track.id,
              onTap: () => controller.select(track.id),
            ),
          // **Last, under a divider, exactly where quality puts *Auto*.** The
          // languages above are the choices; turning them off is the end of the
          // list rather than a language above the first one.
          Divider(height: 9, indent: 12, endIndent: 12, color: scheme.outlineVariant),
          _CaptionRow(
            key: playerCaptionsOffKey,
            label: 'Off',
            selected: !captions.isOn,
            onTap: () => controller.select(null),
          ),
        ],
        // **Under the list, and reachable with captions off.** The style is a
        // session preference (`CaptionsState.style`), so setting it up before
        // turning captions on is a reasonable thing to do — and the page's
        // *Reset* is the one control a user goes looking for when something
        // looks wrong, which is exactly when captions might be off.
        Divider(height: 9, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        _MenuRow(
          key: playerCaptionStyleRowKey,
          icon: Icons.format_paint_outlined,
          // **'Style', not 'Caption style'.** The panel takes the width of its
          // widest row and holds it for every page (see [_menuWidth]); the
          // longer label pushed the subtitle page past the shared floor, so the
          // menu would have been visibly wider on this page than on every other
          // one. The page it opens says 'Caption style' in its header, where
          // there is room and no context to supply the noun.
          label: 'Style',
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => ref.read(playerMenuProvider.notifier).go(SettingsPage.captionStyle),
        ),
      ],
    );
  }
}

/// A tick and a label — deliberately the same shape as `_QualityRow`.
///
/// Not shared with it: `_QualityRow` carries a resolution badge and a nullable
/// variant, and generalising the two into one widget would mean a row that knows
/// about both. Two small widgets that look alike beat one that has to ask which
/// menu it is in.
class _CaptionRow extends StatelessWidget {
  const _CaptionRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
    this.trackName = '',
  });

  final String label;
  final bool selected;

  /// *Styled* or *Karaoke*, already decided — see `CaptionTrack.styleBadge`.
  /// Null draws nothing, which covers plain, not-yet-asked and unrecognised.
  final String? badge;

  /// YouTube's sub-name, or `''`. Worn like a quality row's `4K`.
  final String trackName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.check,
            size: 16,
            // Transparent rather than absent, so the marked row is the one that
            // does not move — same reasoning as `_QualityRow`.
            color: selected ? scheme.primary : Colors.transparent,
          ),
          const SizedBox(width: 8),
          // `Flexible`, so the badges sit exactly after the text rather than
          // being pushed to the right edge. Under `IntrinsicWidth` it still reports the
          // label's full width, which is what lets the panel grow to fit.
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
          ),
          // **The derived qualifier wears what a resolution wears** — raised,
          // small, muted — because it is the same kind of thing as `4K`: not
          // part of the track's name, but something read off it.
          // `_QualityRow._badge` is the other half of that pairing.
          //
          // **Shown only when there is no `trackName`.** The badge is *our*
          // guess at how this track differs from the others — styled,
          // karaoke — for when the uploader never said. A `trackName` is the
          // uploader's own answer to that same question ("Commentary",
          // "Director's cut"), and it wins: showing both would be the app's
          // inference sitting next to the source's own label, disagreeing or
          // redundant either way.
          if (badge != null && trackName.isEmpty) ...[
            const SizedBox(width: 4),
            Transform.translate(
              offset: const Offset(0, -5),
              child: Text(
                badge!,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          // The sub-name gets the chip, because it *is* part of the name — a
          // second label rather than a note about the first, and a chip reads as
          // its own thing where a superscript reads as an annotation.
          if (trackName.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                trackName,
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    // The tick is colour only, so a screen reader is told which row is the current choice
    // (`selected`), the way `ListTile` says it: one merged node per row.
    return MergeSemantics(
      child: Semantics(selected: selected, button: true, child: InkWell(onTap: onTap, child: row)),
    );
  }
}

/// The heights offered while a video is still opening, before its ladder exists. Not
/// every video has all of them: the open takes the best rung at or under the one picked.
const List<int> openingHeights = [2160, 1440, 1080, 720, 480, 360, 240, 144];

class _QualityPage extends ConsumerWidget {
  const _QualityPage({required this.onPicked, this.onPickedHeight});

  final ValueChanged<PlaybackVariant> onPicked;
  final ValueChanged<int>? onPickedHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(playbackProvider);
    final engine = ref.watch(playbackEngineProvider);
    final variants = distinctQualities(playback.variants);
    // A quality picked during an audio track switch is ticked at once too, and shown busy: it is
    // switched to once the track has landed (Task 39).
    final picked = playback.qualityAfterAudioSwitch;
    final current = picked ?? playback.variant;

    return _MenuBody(
      // **No back arrow: there is nothing above this.** Quality has its own bar
      // button, so a chevron would offer a journey nobody made. The header
      // carries the *decoded* height instead — mpv can be asked for one height
      // and serve another, so a control reporting the request is confident
      // exactly when it is wrong.
      header: StreamBuilder<int?>(
        stream: engine.heightStream,
        initialData: engine.height,
        builder: (context, snapshot) {
          final actual = snapshot.data ?? playback.variant?.height;
          return _MenuHeader(
            title: 'Quality',
            // Height only, no fps: it is mpv's number, and mpv reports a height.
            value: actual == null ? null : '${actual}p', //TODO add fps when it is not 30
            valueKey: playerQualityHeaderKey,
          );
        },
      ),
      children: [
        // No ladder yet: the heights it could have, applied when the video opens.
        if (variants.isEmpty && playback.isLoading) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Text(
              'Applies when the video opens',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          for (final height in openingHeights)
            _QualityRow(
              key: ValueKey('player-quality-opening-$height'),
              variant: null,
              height: height,
              label: '${height}p',
              selected: playback.preferredHeight == height,
              onTap: () => onPickedHeight?.call(height),
            ),
        ],
        for (final variant in variants)
          _QualityRow(
            variant: variant,
            // Matched on what the row *says*, not on identity: the open variant
            // may be the second 1080p60 of three, and ticking nothing because
            // the menu is showing the first would be a menu with no current
            // entry at all.
            selected: current != null && variant.height == current.height && variant.fps == current.fps,
            // The tick moves to the picked row at once, before that quality has loaded.
            loading: playback.isChangingQuality || picked != null,
            onTap: () => onPicked(variant),
          ),
        // **Last, and deliberately dead** (task §3): automatic stepping needs a
        // threshold over a window and hysteresis, and is out of scope. At the
        // bottom because the ladder above is best-first, so "let the player
        // decide" reads as the end of the list rather than a rung above 2160p.
        Divider(height: 9, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        Opacity(
          key: playerQualityAutoKey,
          opacity: 0.4,
          child: const _QualityRow(variant: null, selected: false, onTap: null, label: 'Auto'),
        ),
      ],
    );
  }
}

/// The shape every page has: an optional sticky header, then a scrollable list,
/// inside one fixed width and under one height cap.
///
/// Factored out because the three pages disagreed about their own padding the
/// first time they were written separately, and a menu whose rows sit at three
/// different insets depending on which page you are on is a menu that looks
/// broken without anything being wrong.
class _MenuBody extends StatefulWidget {
  const _MenuBody({
    super.key,
    this.header,
    required this.children,
    EdgeInsetsGeometry? padding,
  }) : _padding = padding ?? const EdgeInsets.symmetric(vertical: 6);

  final Widget? header;
  final List<Widget> children;
  final EdgeInsetsGeometry _padding;

  @override
  State<_MenuBody> createState() => _MenuBodyState();
}

class _MenuBodyState extends State<_MenuBody> {
  late final ScrollController _controller;
  late final PageStorageBucket _bucket;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(keepScrollOffset: false);
    // silky_scroll forces keepScrollOffset to true under the hood, making
    // the ScrollController(keepScrollOffset: false) alone insufficient.
    // By providing a completely isolated PageStorageBucket, we guarantee
    // this menu cannot accidentally restore a scroll offset from the
    // watch page's bucket, which was the root cause of the crash.
    _bucket = PageStorageBucket();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // A floor and a ceiling rather than a fixed width. `enforce` against the
      // incoming constraints happens for free, so a player narrower than
      // [_menuMaxWidth] clamps this without anyone measuring the window.
      constraints: const BoxConstraints(
        minWidth: _menuWidth,
        maxWidth: _menuMaxWidth,
        maxHeight: settingsMenuMaxHeight,
      ),
      // **Measured, not calculated.** The alternative is adding up a label's
      // `TextPainter` width plus the icon, the gaps, the sub-name and the badge
      // — a second copy of the row's layout, in a different file, that goes
      // wrong the first time anyone adds a widget to the row and reports it by
      // truncating text rather than by failing. `IntrinsicWidth` asks the rows
      // themselves, so a new element is accounted for by existing.
      //
      // The cost is a second layout pass over the page's rows, on a menu of at
      // most a couple of dozen; the panel's `AnimatedSize` is what turns the
      // resulting width change into a movement instead of a jump, and it is
      // anchored bottom-**right**, so a wider panel grows to the left.
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // **Sticky by construction: it is outside the scroll view.** A
            // header pinned *inside* one is a sliver and a stack of extra
            // machinery; a header that is simply not in the scrollable cannot
            // scroll away.
            if (widget.header != null) widget.header!,
            Flexible(
              // **The `Silky…` prefix is the whole fix** for a wheel over the
              // menu also scrolling the page: only a `SilkyScroll` joins the
              // library's hover stack (architecture §2.8), and a plain
              // `SingleChildScrollView` is invisible to it.
              //
              // `pointerSignalResolver` cannot do this job — `SilkyScroll`
              // handles a vertical wheel in its own `Listener` and only
              // registers there for horizontal ownership — so it silently
              // half-works, which is why the attempt is recorded.
              child: PageStorage(
                bucket: _bucket,
                child: SilkySingleChildScrollView(
                  controller: _controller,
                  // The breathing room at both ends of every list: 12 here plus a
                  // row's own 10 puts the first and last line 22 off the panel
                  // edge. It is inside the scrollable rather than around it, so a
                  // long ladder scrolls *through* the gap instead of stopping
                  // short of one.
                  padding: widget._padding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.children,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.title, this.onBack, this.value, this.valueKey, this.valueLabel});

  final String title;
  final VoidCallback? onBack;
  final String? value;
  final Key? valueKey;

  /// What a screen reader says for [value], where the text on screen is not words (a time left).
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget content = Padding(
      // 16 above, 10 below: the root page's first row sits 16 from the panel
      // edge (6 scroll padding + 10), so a header taking only its own 10 started
      // 6 higher than every other page. Inside the padding rather than a gap
      // above the `InkWell`, so the whole header stays tappable.
      padding: EdgeInsets.fromLTRB(onBack == null ? 14 : 8, 10, 14, 10),
      child: Row(
        children: [
          if (onBack != null) ...[
            Icon(Icons.chevron_left, size: 20, color: scheme.onSurface),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface),
            ),
          ),
          if (value != null)
            Semantics(
              label: valueLabel,
              excludeSemantics: valueLabel != null,
              child: Text(
                value!,
                key: valueKey,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );

    if (onBack != null) {
      content = Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: InkWell(key: playerSettingsBackKey, onTap: onBack, child: content),
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.only(top: 3, bottom: 3),
        child: content,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        content,
        Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }
}

/// Kept from the old menu so the tests that name it still mean something.
const Key playerQualityAutoKey = ValueKey('player-quality-auto');

/// A row on the root page: icon, label, optional trailing value and chevron.
class _MenuRow extends StatelessWidget {
  const _MenuRow({super.key, required this.icon, required this.label, this.trailing, required this.onTap});

  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final foreground = enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38);

    return InkWell(
      onTap: onTap,
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: foreground),
              ),
            ),
            SizedBox(
              child: trailing,
            ),
          ],
        ),
      ),
    );
  }
}

/// A rung, with the badge the resolution earns.
///
/// `16K`, `8K`, `4K` and `HD` are derived from the height here rather than sent by the
/// sidecar — they are a *rendering* of a number the DTO already carries, and a
/// badge field on `PlaybackVariant` would be the UI asking the protocol to hold
/// its opinions for it.
class _QualityRow extends StatelessWidget {
  const _QualityRow({
    super.key,
    required this.variant,
    required this.selected,
    required this.onTap,
    this.label,
    this.loading = false,
    this.height,
  });

  final PlaybackVariant? variant;

  /// The height a row without a [variant] stands for, for its badge.
  final int? height;
  final bool selected;

  /// A switch to this quality is still in flight: the selected row shows a spinner
  /// where its tick is, so it does not claim a quality that is not playing yet.
  final bool loading;
  final VoidCallback? onTap;

  /// For the rows that are not a variant at all — currently only *Auto*.
  final String? label;

  static String? _badge(int height) {
    if (height >= 8640) return '16K';
    if (height >= 4320) return '8K';
    if (height >= 2160) return '4K';
    if (height >= 720) return 'HD';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badgeHeight = variant?.height ?? height;
    final badge = badgeHeight == null ? null : _badge(badgeHeight);

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          if (selected && loading)
            // The same 16 px slot as the tick, so the label does not move.
            ExcludeSemantics(
              child: SizedBox.square(
                key: playerQualityLoadingKey,
                dimension: 16,
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                ),
              ),
            )
          else
            Icon(
              Icons.check,
              size: 16,
              // Transparent rather than absent: a tick that appears and
              // disappears shifts every label sideways, so the marked row is the
              // one that does not move.
              color: selected ? scheme.primary : Colors.transparent,
            ),
          const SizedBox(width: 8),
          Text(
            label ?? describeVariant(variant!),
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
          ),
          if (badge != null) ...[
            const SizedBox(width: 4),
            // Raised and small, the way the resolution list in the mock wears
            // it — a qualifier on the number, not a second column.
            Transform.translate(
              offset: const Offset(0, -5),
              child: Text(
                badge,
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );

    // **No `InkWell` at all when there is nothing to tap**, rather than one with
    // a null `onTap`. The two look identical until a pointer arrives: a disabled
    // `InkWell` is still a hit target, so it takes the click that would
    // otherwise have reached the video, and *Auto* would silently absorb clicks
    // for a feature it does not implement. `player_controls_test.dart` pins this
    // by asserting there is no `InkWell` under the row at all — the miss is the
    // assertion.
    if (onTap == null) return row;
    // Selected for a screen reader too: the tick alone is colour (see `_CaptionRow`).
    return MergeSemantics(
      child: Semantics(selected: selected, button: true, child: InkWell(onTap: onTap, child: row)),
    );
  }
}

/// `1080p60`, or `1080p` at 30. The codec is deliberately absent: `transport`
/// and the ladder tier are telemetry the UI must not be able to read off (§3.5),
/// and a codec name in a quality menu is an invitation to treat it as a choice.
String describeVariant(PlaybackVariant variant) => variant.fps > 30 ? '${variant.height}p${variant.fps}' : '${variant.height}p';

/// One row per height+fps, best-ranked first.
///
/// **Measured:** a real ladder for `aqz-KE-bpKQ` is 22 rungs with four distinct
/// labels, because the same resolution ships in several codecs — picking between
/// two rows reading "1080p60" is a coin flip the user cannot inform.
///
/// The *menu* collapses them and the ladder does not: `variants` stays as the
/// sidecar ranked it (§3.5), and the first of each pair is its preference.
List<PlaybackVariant> distinctQualities(List<PlaybackVariant> variants) {
  final seen = <String>{};
  return [
    for (final variant in variants)
      if (seen.add('${variant.height}x${variant.fps}')) variant,
  ];
}

/// The caption style menu — Task 19.
///
/// **Every control here works on every track, and that is the whole reason it
/// is shaped this way.** The obvious implementation is mpv's live properties —
/// `sub-color`, `sub-font`, `sub-back-color` — and they cannot be used: they act
/// on the ASS `Style`, and `sub-ass-override=force`, the switch that is supposed
/// to make them win, overrides the `Style` too and **not** the inline override
/// tags a styled track is made of. A user setting a font colour would see it
/// apply to plain tracks and silently do nothing on the styled ones, which is
/// exactly the class of failure this project keeps finding. So every value here
/// is sent to the sidecar and folded into the ASS document as it is generated:
/// one mechanism, no track on which a control is a no-op. `captions/style.ts`
/// carries the measurement.
///
/// Two of YouTube's entries are missing rather than faked. **Raised** and
/// **Depressed** edge styles are one result in ASS (`\bord` and `\shad`, no
/// bevel), and the background's **rounded corners** are not expressible at all —
/// both ASS boxes are rectangles. Recorded in `architecture.md` §2.9 as
/// knowingly dropped.
class _ForceStylePage extends ConsumerStatefulWidget {
  const _ForceStylePage();

  @override
  ConsumerState<_ForceStylePage> createState() => _ForceStylePageState();
}

class _ForceStylePageState extends ConsumerState<_ForceStylePage> {
  String _hoverProperty = 'style';
  bool? _hoverActive;

  @override
  Widget build(BuildContext context) {
    final captions = ref.watch(captionsProvider);
    final controller = ref.read(captionsProvider.notifier);
    final style = captions.style;
    final scheme = Theme.of(context).colorScheme;

    // Its own field, independent of the nine tiles — see CaptionStyle.
    // forceStyleEnabled's doc. A switch derived from the nine (their AND)
    // used to read false the moment any single tile did, which both looked
    // like a switch nobody touched had turned itself off and, downstream,
    // collapsed the whole grid away for the same reason.
    final masterSwitch = style.forceStyleEnabled;

    Widget buildTile(String label, IconData icon, bool active, ValueChanged<bool> onChanged) {
      final isHovered = _hoverProperty == label;
      // Gated on the (now independent) master too: a tile the master has
      // disabled should not look selectable, whatever its own flag says.
      final isEnabled = masterSwitch && active;
      final backgroundColor = isHovered ? (isEnabled ? scheme.primary : scheme.secondaryContainer) : (isEnabled ? scheme.primaryContainer : scheme.surfaceContainerHighest);
      final foregroundColor = isHovered ? (isEnabled ? scheme.onPrimary : scheme.onSecondaryContainer) : (isEnabled ? scheme.onPrimaryContainer : scheme.onSurfaceVariant);
      // The label reads too close to full contrast when disabled — the icon
      // stays as-is, just the text underneath it dims further.
      final labelColor = isEnabled ? foregroundColor : foregroundColor.withValues(alpha: 0.6);
      // No hover, no click, while the master is off — the tiles depend on
      // it rather than the other way around.
      return IgnorePointer(
        ignoring: !masterSwitch,
        child: MouseRegion(
          onEnter: (_) => setState(() {
            _hoverProperty = label;
            _hoverActive = active;
          }),
          onExit: (_) => setState(() {
            _hoverProperty = 'style';
            _hoverActive = null;
          }),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              onChanged(!active);
              if (_hoverProperty == label) setState(() => _hoverActive = !active);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isHovered ? scheme.outline : scheme.outlineVariant,
                  width: isHovered ? 1.5 : 0,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: foregroundColor,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.1,
                      fontWeight: FontWeight.w500,
                      color: labelColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // The hovered tile's own state when one is hovered — not gated on
    // `masterSwitch` too, for the same reason `isEnabled` above isn't: the
    // explanation is about *this* property, not about whether all nine
    // happen to agree.
    final isActive = _hoverActive ?? masterSwitch;
    final prefix = isActive ? 'Overrides all subtitle ' : 'Allows for a different subtitle ';
    final suffix = isActive ? ', even if a different value is specified by the video.' : ' specified by the video.';

    return _MenuBody(
      header: _MenuHeader(
        title: 'Video overrides',
        onBack: () => ref.read(playerMenuProvider.notifier).go(SettingsPage.captionStyle),
      ),
      children: [
        SizedBox(
          height: 50,
          child: _MenuRow(
            icon: Icons.auto_fix_high,
            label: 'Force Style',
            trailing: Switch(
              value: masterSwitch,
              onChanged: (v) => onForceStyleChanged(v, controller, style),
            ),
            onTap: () => onForceStyleChanged(!masterSwitch, controller, style),
          ),
        ),
        // Always shown — this is the page a user reaches specifically to set
        // these nine, and it used to collapse away (behind an
        // `AnimatedCrossFade`) the moment any one of them stopped matching
        // the other eight, since `masterSwitch` reads false then by
        // construction. That's what made turning off a single tile look like
        // the whole feature had switched off.
        SizedBox(
          width: _menuMaxWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Font', Icons.font_download_outlined, style.forceFontFamily, (v) => controller.setStyle(style.copyWith(forceFontFamily: v), immediate: true))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Size', Icons.format_size, style.forceFontSize, (v) => controller.setStyle(style.copyWith(forceFontSize: v), immediate: true))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Text Color', Icons.format_color_text, style.forceTextColor, (v) => controller.setStyle(style.copyWith(forceTextColor: v), immediate: true))),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Text Opacity', Icons.opacity, style.forceTextOpacity, (v) => controller.setStyle(style.copyWith(forceTextOpacity: v), immediate: true))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Background Color', Icons.format_color_fill, style.forceBackgroundColor, (v) => controller.setStyle(style.copyWith(forceBackgroundColor: v), immediate: true))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Background Opacity', Icons.blur_on, style.forceBackgroundOpacity, (v) => controller.setStyle(style.copyWith(forceBackgroundOpacity: v), immediate: true))),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Window Color', Icons.picture_in_picture, style.forceWindowColor, (v) => controller.setStyle(style.copyWith(forceWindowColor: v), immediate: true))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Window Opacity', Icons.picture_in_picture_alt, style.forceWindowOpacity, (v) => controller.setStyle(style.copyWith(forceWindowOpacity: v), immediate: true))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(height: 54, child: buildTile('Edge', Icons.border_style, style.forceEdgeStyle, (v) => controller.setStyle(style.copyWith(forceEdgeStyle: v), immediate: true))),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: _menuMaxWidth - 28,
            // Sized to which string is showing (the "Overrides…" one is the
            // longer of the two and wraps), not to `masterSwitch` — the box
            // used to double as "is the grid even open", which it no longer
            // needs to answer.
            height: isActive ? 48 : 28,
            alignment: Alignment.center,
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                children: [
                  TextSpan(text: prefix),
                  TextSpan(
                    text: _hoverProperty,
                    style: TextStyle(fontWeight: isActive ? FontWeight.bold : FontWeight.normal),
                  ),
                  TextSpan(text: suffix),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Just the one field now — the nine tiles are untouched, forced or not,
  /// so turning the master back on restores exactly what they said before.
  void onForceStyleChanged(bool v, CaptionsController controller, CaptionStyle style) {
    controller.setStyle(style.copyWith(forceStyleEnabled: v), immediate: true);
  }
}

/// The caption style submenu: font, size, and colours.
///
/// Public because `player_caption_style_test.dart` builds it directly; nothing
/// else outside this file mounts it.
class CaptionStylePage extends ConsumerWidget {
  const CaptionStylePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final captions = ref.watch(captionsProvider);
    final controller = ref.read(captionsProvider.notifier);
    final style = captions.style;

    void apply(CaptionStyle next, {bool immediate = true}) {
      unawaited(controller.setStyle(next, immediate: immediate));
    }

    return _MenuBody(
      key: playerCaptionStyleMenuKey,
      header: _MenuHeader(
        title: 'Caption style',
        onBack: () => ref.read(playerMenuProvider.notifier).go(SettingsPage.captions),
      ),
      children: [
        _MenuRow(
          icon: Icons.auto_fix_high,
          label: 'Video overrides',
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => ref.read(playerMenuProvider.notifier).go(SettingsPage.forceStyle),
        ),
        SizedBox(height: 6),
        Divider(height: 1, color: scheme.outlineVariant),
        _StyleSection(label: 'Font'),
        _StyleChoices<String?>(
          value: style.fontFamily,
          options: _fontOptions,
          onPicked: (family) => apply(style.copyWith(fontFamily: family)),
        ),
        _StyleSlider(
          label: 'Size',
          value: style.fontSizePercent ?? 100,
          min: 50,
          max: 300,
          divisions: 50, // (300 - 50) / 5% per tick
          format: (value) => '${value.round()}%',
          // A slider fires per frame and every change is a round trip plus a
          // `sub-add`; the controller debounces trailing so a drag commits a
          // handful of times instead of sixty.
          onChanged: (value) => apply(style.copyWith(fontSizePercent: value), immediate: false),
        ),
        // Colour and opacity are independent fields on CaptionStyle
        // (textColor / textOpacity) precisely so that resetting either one
        // to "Default" here does not clear the other.
        _StyleColors(
          label: 'Colour',
          value: style.textColor,
          onPicked: (colour) => apply(style.copyWith(textColor: colour)),
        ),
        _StyleSlider(
          label: 'Opacity',
          value: style.textOpacity != null ? style.textOpacity! * 100 : -25,
          min: -25,
          max: 100,
          divisions: 5,
          format: (value) => value < 0 ? 'Default' : '${value.round()}%',
          onChanged: (value) {
            apply(
              style.copyWith(textOpacity: value < 0 ? null : value / 100),
              immediate: false,
            );
          },
        ),

        Divider(height: 13, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        _StyleSection(label: 'Background'),
        _StyleColors(
          label: 'Colour',
          value: style.background,
          onPicked: (colour) => apply(style.copyWith(background: colour)),
        ),
        _StyleSlider(
          label: 'Opacity',
          value: style.backgroundOpacity != null ? style.backgroundOpacity! * 100 : -25,
          min: -25,
          max: 100,
          divisions: 5,
          format: (value) => value < 0 ? 'Default' : '${value.round()}%',
          onChanged: (value) {
            apply(
              style.copyWith(backgroundOpacity: value < 0 ? null : value / 100),
              immediate: false,
            );
          },
        ),

        Divider(height: 13, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        // The *window* is the rectangle around every caption on screen at once,
        // as distinct from the per-line background above. YouTube draws both and
        // ships this one at zero opacity, which is why it looks absent until
        // someone turns it up.
        _StyleSection(label: 'Window'),
        _StyleColors(
          label: 'Colour',
          value: style.window,
          onPicked: (colour) => apply(style.copyWith(window: colour)),
        ),
        _StyleSlider(
          label: 'Opacity',
          value: style.windowOpacity != null ? style.windowOpacity! * 100 : -25,
          min: -25,
          max: 100,
          divisions: 5,
          format: (value) => value < 0 ? 'Default' : '${value.round()}%',
          onChanged: (value) {
            apply(
              style.copyWith(windowOpacity: value < 0 ? null : value / 100),
              immediate: false,
            );
          },
        ),

        Divider(height: 13, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        _StyleSection(label: 'Character edge'),
        _StyleChoices<CaptionEdgeStyle?>(
          value: style.edgeStyle,
          options: _edgeOptions,
          onPicked: (edge) => apply(style.copyWith(edgeStyle: edge)),
        ),

        Divider(height: 13, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        // **Resets the drag as well as the style**, which is why it lives here
        // rather than beside the caption: those are the two things a user can
        // put into a state they cannot easily undo by hand.
        _MenuRow(
          key: playerCaptionStyleResetKey,
          icon: Icons.restart_alt,
          label: 'Reset',
          onTap: style.isDefault && captions.offset.isZero ? null : () => unawaited(controller.resetStyle()),
        ),
      ],
    );
  }
}

/// `null` is "the track decides", which is a real choice and the first one.
const List<({String label, String? value})> _fontOptions = [
  (label: 'Default', value: null),
  (label: 'Arial', value: 'Arial'),
  (label: 'Georgia', value: 'Georgia'),
  (label: 'Courier New', value: 'Courier New'),
  (label: 'Comic Sans MS', value: 'Comic Sans MS'),
];

/// Three, not five. See the class doc for the two that ASS cannot tell apart.
const List<({String label, CaptionEdgeStyle? value})> _edgeOptions = [
  (label: 'Default', value: null),
  (label: 'None', value: CaptionEdgeStyle.none),
  (label: 'Drop shadow', value: CaptionEdgeStyle.dropShadow),
  (label: 'Outline', value: CaptionEdgeStyle.outline),
];

class _StyleSection extends StatelessWidget {
  const _StyleSection({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A wrapping row of chips — the menu is 248 px wide and a `DropdownButton`
/// inside a panel that is itself an overlay is a second overlay to position.
class _StyleChoices<T> extends StatelessWidget {
  const _StyleChoices({required this.value, required this.options, required this.onPicked});

  final T value;
  final List<({String label, T value})> options;
  final ValueChanged<T> onPicked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final option in options)
            InkWell(
              onTap: () => onPicked(option.value),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: option.value == value ? scheme.primary : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  option.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: option.value == value ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Swatches, with the first one struck through for "leave it to the track".
class _StyleColors extends StatelessWidget {
  const _StyleColors({required this.label, required this.value, required this.onPicked});

  final String label;
  final Color? value;
  final ValueChanged<Color?> onPicked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Compared on RGB alone: the opacity slider owns the alpha channel, and a
    // swatch that stopped looking selected when the user moved the slider would
    // read as the colour having been forgotten.
    bool isPicked(Color? swatch) {
      if (swatch == null || value == null) return swatch == null && value == null;
      return swatch.r == value!.r && swatch.g == value!.g && swatch.b == value!.b;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 12, 6),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final swatch in captionPalette)
                  InkWell(
                    onTap: () => onPicked(swatch),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: swatch ?? scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isPicked(swatch) ? scheme.primary : scheme.outlineVariant,
                          width: isPicked(swatch) ? 2 : 1,
                        ),
                      ),
                      child: swatch == null ? Icon(Icons.remove, size: 12, color: scheme.onSurfaceVariant) : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleSlider extends StatelessWidget {
  const _StyleSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 2),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(
              format(value),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// --- The sleep timer (Task 38, `architecture.md` §2.18) ---

const Key playerSleepTimerRowKey = ValueKey('player-sleep-timer-row');
const Key playerAudioTrackRowKey = ValueKey('player-audio-track-row');
const Key playerAudioTrackMenuKey = ValueKey('player-audio-track-menu');
const Key playerSleepTimerMenuKey = ValueKey('player-sleep-timer-menu');
const Key playerSleepCustomRowKey = ValueKey('player-sleep-custom-row');
const Key playerSleepActionRowKey = ValueKey('player-sleep-action-row');
const Key playerSleepCustomMenuKey = ValueKey('player-sleep-custom-menu');
const Key playerSleepActionMenuKey = ValueKey('player-sleep-action-menu');
const Key sleepCustomMinutesKey = ValueKey('sleep-custom-minutes');
const Key sleepCustomSecondsKey = ValueKey('sleep-custom-seconds');
const Key sleepCustomStartKey = ValueKey('sleep-custom-start');
const Key sleepCustomChaptersStartKey = ValueKey('sleep-custom-chapters-start');
const Key sleepCustomVideosStartKey = ValueKey('sleep-custom-videos-start');

/// The timer page's fixed lengths, in minutes.
const List<int> sleepPresetMinutes = [1, 2, 5, 10, 15, 30, 45, 60];

/// The root page's row: the state, read at a glance — `Off`, `12:34`, `End of video`, and the
/// action after it when there is one.
class _SleepTimerRow extends ConsumerWidget {
  const _SleepTimerRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final timer = ref.watch(sleepTimerProvider);
    final action = ref.watch(sleepEndActionProvider);
    return _MenuRow(
      key: playerSleepTimerRowKey,
      icon: timer.isOn ? Icons.bedtime : Icons.bedtime_outlined,
      label: 'Sleep timer',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Said in words, not digits (`spoken.dart`): `12:34` read aloud is "twelve colon thirty-four".
          Semantics(
            label: sleepTimerSpokenSummary(timer, action),
            child: ExcludeSemantics(
              child: Text(sleepTimerSummary(timer, action), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: () => ref.read(playerMenuProvider.notifier).go(SettingsPage.sleepTimer),
    );
  }
}

/// Whether the video open now is a live stream: it has no end for *End of video* to wait for.
bool _isLive(PlaybackState playback) => playback.item?.isLive == true || (playback.source != null && playback.source!.durationMs == null);

/// Off, the lengths, the two endings, *Custom…*, and what happens after. The current choice is
/// ticked, as on the quality page. Picking anything replaces the timer running now, which is how a
/// timer is stopped (decided: no warning, no "+10 min").
class _SleepTimerPage extends ConsumerWidget {
  const _SleepTimerPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final timer = ref.watch(sleepTimerProvider);
    final action = ref.watch(sleepEndActionProvider);
    final playback = ref.watch(playbackProvider);
    final item = playback.item;
    final chapters = item == null ? const <Object>[] : (ref.watch(videoInfoProvider(item.id)).value?.chapters ?? const <Object>[]);
    final controller = ref.read(sleepTimerProvider.notifier);
    final menu = ref.read(playerMenuProvider.notifier);

    void pick(void Function() start) {
      start();
      menu.close();
    }

    final preset = timer.kind == SleepKind.duration && sleepPresetMinutes.any((m) => timer.total == Duration(minutes: m));
    final custom = timer.kind == SleepKind.chapters || timer.kind == SleepKind.videos || (timer.kind == SleepKind.duration && !preset);

    return _MenuBody(
      key: playerSleepTimerMenuKey,
      header: _MenuHeader(
        title: 'Sleep timer',
        onBack: menu.back,
        value: timer.isOn ? timer.waitsFor : null,
        valueLabel: timer.isOn ? sleepTimerSpokenSummary(timer, SleepEndAction.nothing) : null,
      ),
      children: [
        _CaptionRow(label: 'Off', selected: !timer.isOn, onTap: () => pick(controller.off)),
        for (final minutes in sleepPresetMinutes)
          _CaptionRow(
            label: minutes == 1 ? '1 minute' : '$minutes minutes',
            selected: timer.kind == SleepKind.duration && timer.total == Duration(minutes: minutes),
            onTap: () => pick(() => controller.startDuration(Duration(minutes: minutes))),
          ),
        // Only when the video has chapters: without them there is no chapter to end.
        if (chapters.isNotEmpty) _CaptionRow(label: 'End of chapter', selected: timer.kind == SleepKind.chapterEnd, onTap: () => pick(controller.endOfChapter)),
        // Not for a live stream, which has no end.
        if (!_isLive(playback)) _CaptionRow(label: 'End of video', selected: timer.kind == SleepKind.videoEnd, onTap: () => pick(controller.endOfVideo)),
        _SleepChoiceRow(key: playerSleepCustomRowKey, label: 'Custom…', selected: custom, onTap: () => menu.go(SettingsPage.sleepTimerCustom)),
        Divider(height: 9, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        _MenuRow(
          key: playerSleepActionRowKey,
          icon: Icons.power_settings_new,
          label: 'When it ends: ${action.label}',
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => menu.go(SettingsPage.sleepTimerAction),
        ),
      ],
    );
  }
}

/// A ticked row with a chevron: *Custom…*, which is a choice and a door at once.
class _SleepChoiceRow extends StatelessWidget {
  const _SleepChoiceRow({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        button: true,
        child: _sleepChoiceInk(scheme),
      ),
    );
  }

  Widget _sleepChoiceInk(ColorScheme scheme) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            Icon(Icons.check, size: 16, color: selected ? scheme.primary : Colors.transparent),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurface))),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }
}

/// *When it ends*: **Do nothing** first and the default. Sleep and Hibernate are offered only when
/// Windows allows them. The choice lasts while Rill runs and is not remembered across a restart.
class _SleepActionPage extends ConsumerWidget {
  const _SleepActionPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final power = ref.watch(systemPowerProvider);
    final choice = ref.watch(sleepEndActionProvider);
    final menu = ref.read(playerMenuProvider.notifier);
    final actions = [
      SleepEndAction.nothing,
      SleepEndAction.closeRill,
      if (power.canSleep) SleepEndAction.sleep,
      if (power.canHibernate) SleepEndAction.hibernate,
      SleepEndAction.shutDown,
      SleepEndAction.restart,
    ];
    return _MenuBody(
      key: playerSleepActionMenuKey,
      header: _MenuHeader(title: 'When it ends', onBack: menu.back),
      children: [
        for (final action in actions)
          _CaptionRow(
            key: ValueKey('sleep-action-${action.name}'),
            label: action.label,
            selected: choice == action,
            onTap: () {
              ref.read(sleepEndActionProvider.notifier).set(action);
              menu.back();
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
          child: Text(
            'Sleep, hibernate, shut down and restart wait 30 s first, with a Cancel.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// *Custom…*: a duration, *After N chapters* (when the video has chapters) and *After N videos*.
/// It opens on the values last started here.
///
/// The fields take focus, and while one has it no player shortcut fires (`textEntryHasFocus`).
/// Enter starts; Escape goes back a page — here and from the global handler (`shortcuts.dart`).
class _SleepCustomPage extends ConsumerStatefulWidget {
  const _SleepCustomPage();

  @override
  ConsumerState<_SleepCustomPage> createState() => _SleepCustomPageState();
}

class _SleepCustomPageState extends ConsumerState<_SleepCustomPage> {
  final TextEditingController _minutes = TextEditingController(text: '30');
  final TextEditingController _seconds = TextEditingController(text: '00');
  int _chapters = 2;
  int _videos = 2;
  bool _invalid = false;

  /// The viewer has typed or stepped already: the remembered values, read asynchronously, must not
  /// land on top of that.
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      SleepCustomValues.read().then((values) {
        if (!mounted || _edited) return;
        setState(() {
          _minutes.text = '${values.seconds ~/ 60}';
          _seconds.text = (values.seconds % 60).toString().padLeft(2, '0');
          _chapters = values.chapters;
          _videos = values.videos;
        });
      }),
    );
  }

  @override
  void dispose() {
    _minutes.dispose();
    _seconds.dispose();
    super.dispose();
  }

  void _started() => ref.read(playerMenuProvider.notifier).close();

  void _startDuration() {
    final minutes = int.tryParse(_minutes.text.trim().isEmpty ? '0' : _minutes.text.trim());
    final seconds = int.tryParse(_seconds.text.trim().isEmpty ? '0' : _seconds.text.trim());
    final total = minutes == null || seconds == null || seconds > 59 ? 0 : minutes * 60 + seconds;
    if (total < 1 || total > SleepCustomValues.maxSeconds) {
      setState(() => _invalid = true);
      return;
    }
    ref.read(sleepTimerProvider.notifier).startDuration(Duration(seconds: total));
    unawaited(SleepCustomValues.write(seconds: total));
    _started();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      ref.read(playerMenuProvider.notifier).back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = ref.watch(playbackProvider.select((p) => p.item));
    final chapters = item == null ? const <Object>[] : (ref.watch(videoInfoProvider(item.id)).value?.chapters ?? const <Object>[]);
    final timer = ref.read(sleepTimerProvider.notifier);
    final menu = ref.read(playerMenuProvider.notifier);

    Widget field(Key key, TextEditingController controller, String label, int maxLength) => SizedBox(
      width: 72,
      child: TextField(
        key: key,
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(maxLength)],
        // No context menu: it is an overlay, and this panel fades and unmounts (CLAUDE.md, Accessibility).
        contextMenuBuilder: null,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(isDense: true, labelText: label, border: const OutlineInputBorder()),
        onChanged: (_) {
          _edited = true;
          if (_invalid) setState(() => _invalid = false);
        },
        onSubmitted: (_) => _startDuration(),
      ),
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: _MenuBody(
        key: playerSleepCustomMenuKey,
        header: _MenuHeader(title: 'Custom', onBack: menu.back),
        children: [
          const _StyleSection(label: 'Duration'),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 12, 4),
            child: Row(
              children: [
                field(sleepCustomMinutesKey, _minutes, 'Minutes', 4),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text(':')),
                field(sleepCustomSecondsKey, _seconds, 'Seconds', 2),
                const Spacer(),
                FilledButton.tonal(key: sleepCustomStartKey, onPressed: _startDuration, child: const Text('Start')),
              ],
            ),
          ),
          if (_invalid)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
              child: Semantics(
                liveRegion: true,
                child: Text('From 0:01 to 23:59:59', style: TextStyle(fontSize: 11, color: scheme.error)),
              ),
            ),
          if (chapters.isNotEmpty) ...[
            const _StyleSection(label: 'After chapters'),
            _SleepStepper(
              noun: 'chapters',
              value: _chapters,
              onChanged: (value) => setState(() {
                _edited = true;
                _chapters = value;
              }),
              startKey: sleepCustomChaptersStartKey,
              onStart: () {
                timer.afterChapters(_chapters);
                unawaited(SleepCustomValues.write(chapters: _chapters));
                _started();
              },
            ),
          ],
          const _StyleSection(label: 'After videos'),
          _SleepStepper(
            noun: 'videos',
            value: _videos,
            onChanged: (value) => setState(() {
              _edited = true;
              _videos = value;
            }),
            startKey: sleepCustomVideosStartKey,
            onStart: () {
              timer.afterVideos(_videos);
              unawaited(SleepCustomValues.write(videos: _videos));
              _started();
            },
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// N from 1 to 99, with a minus and a plus, and *Start*.
class _SleepStepper extends StatelessWidget {
  const _SleepStepper({required this.noun, required this.value, required this.onChanged, required this.onStart, required this.startKey});

  final String noun;
  final int value;
  final ValueChanged<int> onChanged;
  final VoidCallback onStart;
  final Key startKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 12, 4),
      child: Row(
        children: [
          IconButton(
            key: ValueKey('sleep-$noun-fewer'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.remove, size: 18, semanticLabel: 'Fewer $noun'),
            // Never disabled at the limit: a disabled button cannot hold focus, and a keyboard user
            // stepping down to 1 would lose it (CLAUDE.md). At the limit the press does nothing.
            onPressed: () {
              if (value > 1) onChanged(value - 1);
            },
          ),
          SizedBox(
            width: 28,
            child: Semantics(
              liveRegion: true,
              label: '$value $noun',
              child: ExcludeSemantics(
                child: Text('$value', key: ValueKey('sleep-$noun-value'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('sleep-$noun-more'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.add, size: 18, semanticLabel: 'More $noun'),
            onPressed: () {
              if (value < 99) onChanged(value + 1);
            },
          ),
          const Spacer(),
          FilledButton.tonal(key: startKey, onPressed: onStart, child: const Text('Start')),
        ],
      ),
    );
  }
}

/// *Audio track* on the root page (Task 39): only when the video has more than one, reading the
/// track that plays (or is being switched to).
class _AudioTrackRootRow extends ConsumerWidget {
  const _AudioTrackRootRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = ref.watch(playbackProvider.select((p) => p.audioTracks));
    final currentId = ref.watch(playbackProvider.select((p) => p.audioTrackId));
    if (tracks.length < 2) return const SizedBox.shrink();
    final current = tracks.where((track) => track.id == currentId).firstOrNull;
    return _MenuRow(
      key: playerAudioTrackRowKey,
      icon: Icons.multitrack_audio,
      label: 'Audio track',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (current != null)
            Text(current.displayName, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: () => ref.read(playerMenuProvider.notifier).go(SettingsPage.audioTrack),
    );
  }
}

/// The video's audio tracks, the original first, the one playing ticked (Task 39).
///
/// The rows use YouTube's names, without the word "original" (the sidecar removes YouTube's own
/// wording for it, `protocol.md` §3.5), and the markers become badges: *Original*, and *AI dub* for
/// YouTube's automatic dubs. A dub the creator uploaded is a plain row. Picking one switches the
/// audio where the video is, through the second player, with the video stopped and the spinner up
/// until the new track is in.
class _AudioTrackPage extends ConsumerWidget {
  const _AudioTrackPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);
    final controller = ref.read(playbackProvider.notifier);
    final menu = ref.read(playerMenuProvider.notifier);
    final tracks = playback.audioTracks;
    final currentId = playback.audioTrackId;
    final current = tracks.where((track) => track.id == currentId).firstOrNull;

    return _MenuBody(
      key: playerAudioTrackMenuKey,
      header: _MenuHeader(title: 'Audio track', onBack: menu.back, value: current?.displayName),
      children: [
        // The video changed under an open page and has one track: nothing to choose.
        if (tracks.length < 2)
          const _MenuRow(icon: Icons.multitrack_audio, label: 'Only one for this video', onTap: null)
        else
          for (final track in tracks)
            AudioTrackOptionRow(
              key: ValueKey('player-audio-track-${track.id}'),
              track: track,
              selected: track.id == currentId,
              switching: track.id == playback.switchingAudioTrackId,
              // Always enabled: a disabled control cannot hold focus (Task 32), and the row just
              // pressed is the one the reopen fallback makes busy. A press while the player is busy
              // is ticked and waits its turn; one after the switch has started is ignored.
              onTap: () => unawaited(controller.chooseAudioTrack(track.id)),
            ),
      ],
    );
  }
}

/// One audio track: a tick, YouTube's name, and a badge for the original or an AI dub.
///
/// **One spoken name per row** (CLAUDE.md, Accessibility): the badge is drawn, and said once as
/// part of the label — "Hindi, AI dub" — with `selected` for the tick, the way [_CaptionRow] does.
class AudioTrackOptionRow extends StatelessWidget {
  const AudioTrackOptionRow({super.key, required this.track, required this.selected, required this.onTap, this.switching = false});

  final AudioTrackOption track;
  final bool selected;

  /// The pick is being switched to: the tick is already here, quieter until the track is in (the
  /// spinner is the player's own, over the stopped video).
  final bool switching;
  final VoidCallback? onTap;

  /// The badge, or null for a plain row (a creator's own dub, a track with no marker).
  String? get badge => track.isOriginal ? 'Original' : (track.isAutoDubbed ? 'AI dub' : null);

  /// What a screen reader says: the name, then the badge in words ("AI" kept in capitals, so it is
  /// spelled out rather than read as a word).
  String get spokenLabel => switch (badge) {
        null => track.displayName,
        'Original' => '${track.displayName}, original',
        final other => '${track.displayName}, $other',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badge = this.badge;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.check,
            size: 16,
            // Transparent rather than absent, so the ticked row is the one that does not move.
            color: selected ? (switching ? scheme.primary.withValues(alpha: 0.5) : scheme.primary) : Colors.transparent,
          ),
          const SizedBox(width: 8),
          // Expanded, so the badge sits at the row's right edge and the badges line up in a column.
          Expanded(
            child: Text(
              track.displayName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: onTap == null && !selected ? scheme.onSurfaceVariant : scheme.onSurface),
            ),
          ),
          // The same chip a caption track's sub-name wears: part of what tells two rows apart.
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
              child: Text(badge, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
            ),
          ],
        ],
      ),
    );
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        button: true,
        enabled: onTap != null,
        label: spokenLabel,
        // The drawn name and badge are excluded, so the label above is said once; the `InkWell`
        // stays outside the exclusion, so the row keeps its tap action and its focus.
        child: onTap == null ? ExcludeSemantics(child: row) : InkWell(onTap: onTap, child: ExcludeSemantics(child: row)),
      ),
    );
  }
}

@Preview(name: 'Audio track rows')
Widget audioTrackRowsPreview() => MaterialApp(
      home: Material(
        child: SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AudioTrackOptionRow(
                track: const AudioTrackOption(id: 'en-US.4', displayName: 'English (US)', isOriginal: true),
                selected: false,
                onTap: () {},
              ),
              AudioTrackOptionRow(
                track: const AudioTrackOption(id: 'hi.10', displayName: 'Hindi', isAutoDubbed: true),
                selected: false,
                onTap: () {},
              ),
              AudioTrackOptionRow(
                track: const AudioTrackOption(id: 'es.3', displayName: 'Spanish', isDubbed: true),
                selected: true,
                switching: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
