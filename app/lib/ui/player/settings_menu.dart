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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../domain/playback_source.dart';
import '../widgets/silky_scroll_absorber.dart';
import '../../domain/caption_style.dart';
import '../captions_controller.dart';
import '../playback_controller.dart';

const Key playerSettingsButtonKey = ValueKey('player-settings-button');
const Key playerQualityButtonKey = ValueKey('player-quality-button');
const Key playerSettingsMenuKey = ValueKey('player-settings-menu');
const Key playerSettingsMoreRowKey = ValueKey('player-settings-more-row');
const Key playerSettingsBackKey = ValueKey('player-settings-back');

/// The decoded height, on the quality page's header.
const Key playerQualityHeaderKey = ValueKey('player-quality-header');

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
enum SettingsPage { root, moreOptions, quality, captions, captionStyle, forceStyle }

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
    if (state.page != SettingsPage.moreOptions) return false;
    state = const PlayerMenuState(open: true, page: SettingsPage.root);
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

/// Whether a global pointer position landed on the menu — the panel, or either
/// of the buttons that open it.
///
/// False when none is mounted, which is the case the caller wants anyway: with
/// no menu up there is no click-outside to detect.
bool pointerIsOnSettingsMenu(Offset globalPosition) =>
    _hits(settingsMenuPanelKey, globalPosition) || //
    _hits(settingsMenuAnchorKey, globalPosition) ||
    _hits(qualityButtonAnchorKey, globalPosition) ||
    _hits(captionsButtonAnchorKey, globalPosition);

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
        builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
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
  const PlayerSettingsMenu({super.key, required this.onPicked});

  /// A quality was chosen. The caller closes the menu and wakes the controls —
  /// this widget does not reach for either.
  final ValueChanged<PlaybackVariant> onPicked;

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
  static int _depthOf(SettingsPage page) => page == SettingsPage.moreOptions || page == SettingsPage.captionStyle ? 1 : 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = ref.watch(playerMenuProvider.select((menu) => menu.page));

    if (page != _shown) {
      // Derived, not stored state — the rebuild that reads it is already
      // happening, so this wants no `setState`.
      _direction = (_depthOf(page) - _depthOf(_shown)).toDouble();
      _shown = page;
    }

    // Keyed off the enum rather than by hand, so the key the transition compares
    // against below cannot drift from the key the page was built with.
    final Widget child = KeyedSubtree(
      key: ValueKey(page.name),
      child: switch (page) {
        SettingsPage.root => const _RootPage(),
        SettingsPage.moreOptions => const _MoreOptionsPage(),
        SettingsPage.quality => _QualityPage(onPicked: widget.onPicked),
        SettingsPage.captions => const _CaptionsPage(),
        SettingsPage.captionStyle => const CaptionStylePage(),
        SettingsPage.forceStyle => const _ForceStylePage(),
      },
    );

    return Align(
      // Bottom-aligned inside whatever height the `Positioned` allows, so the
      // panel grows upward from the button it belongs to.
      alignment: Alignment.bottomRight,
      // **The whole panel goes on the hover stack, not just its list.** The
      // `SilkySingleChildScrollView` below covers the rows; the sticky header,
      // the padding and the panel's edges are outside it, and a wheel over those
      // reached the page. See `SilkyScrollAbsorber`.
      child: SilkyScrollAbsorber(
        child: GestureDetector(
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
                    for (final previous in previousChildren) Positioned(top: 0, left: 0, right: 0, child: previous),
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
      ),
    );
  }
}

/// The rows that have nowhere to go yet.
///
/// Present and **disabled**, the same call the captions button and the premiere
/// slate's *Notify me* make: a row that says "later" is honest, and a row that
/// opens an empty subpage is a bug report waiting to be filed. Nothing here has
/// anything behind it — *Playback speed* included, because the engine has no
/// rate control to drive it and wiring one is a `data/playback/engine.dart`
/// change rather than a menu change.
const List<({IconData icon, String label})> _rootPlaceholders = [
  (icon: Icons.bedtime_outlined, label: 'Sleep timer'),
  (icon: Icons.multitrack_audio, label: 'Audio track'),
  (icon: Icons.subtitles_outlined, label: 'Subtitle track / CC'),
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
    return InkWell(onTap: onTap, child: row);
  }
}

class _QualityPage extends ConsumerWidget {
  const _QualityPage({required this.onPicked});

  final ValueChanged<PlaybackVariant> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(playbackProvider);
    final engine = ref.watch(playbackEngineProvider);
    final variants = distinctQualities(playback.variants);
    final current = playback.variant;

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
          final actual = snapshot.data ?? current?.height;
          return _MenuHeader(
            title: 'Quality',
            // Height only, no fps: it is mpv's number, and mpv reports a height.
            value: actual == null ? null : '${actual}p', //TODO add fps when it is not 30
            valueKey: playerQualityHeaderKey,
          );
        },
      ),
      children: [
        for (final variant in variants)
          _QualityRow(
            variant: variant,
            // Matched on what the row *says*, not on identity: the open variant
            // may be the second 1080p60 of three, and ticking nothing because
            // the menu is showing the first would be a menu with no current
            // entry at all.
            selected: current != null && variant.height == current.height && variant.fps == current.fps,
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
class _MenuBody extends StatelessWidget {
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
            ?header,
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
              child: SilkySingleChildScrollView(
                // The breathing room at both ends of every list: 12 here plus a
                // row's own 10 puts the first and last line 22 off the panel
                // edge. It is inside the scrollable rather than around it, so a
                // long ladder scrolls *through* the gap instead of stopping
                // short of one.
                padding: _padding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
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
  const _MenuHeader({required this.title, this.onBack, this.value, this.valueKey});

  final String title;
  final VoidCallback? onBack;
  final String? value;
  final Key? valueKey;

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
            Text(
              value!,
              key: valueKey,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
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
  const _QualityRow({required this.variant, required this.selected, required this.onTap, this.label});

  final PlaybackVariant? variant;
  final bool selected;
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
    final badge = variant == null ? null : _badge(variant!.height);

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
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
    return InkWell(onTap: onTap, child: row);
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
      final backgroundColor = isHovered
          ? (isEnabled ? scheme.primary : scheme.secondaryContainer)
          : (isEnabled ? scheme.primaryContainer : scheme.surfaceContainerHighest);
      final foregroundColor = isHovered
          ? (isEnabled ? scheme.onPrimary : scheme.onSecondaryContainer)
          : (isEnabled ? scheme.onPrimaryContainer : scheme.onSurfaceVariant);
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
