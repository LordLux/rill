import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth_controller.dart';
import '../focus_ring.dart';
import 'shortcut_tooltip.dart';

/// How much of a subscribed channel's upload activity notifies the user —
/// the three-way bell menu every subscribed channel on YouTube itself
/// carries. There is no RPC for this (`docs/protocol.md` has no
/// notification-preference endpoint at all), so a level change is a
/// local-only stub everywhere it is used, not just here.
enum SubscriptionNotificationLevel {
  all,
  personalized,
  none;

  IconData get icon => switch (this) {
    SubscriptionNotificationLevel.all => Icons.notifications,
    SubscriptionNotificationLevel.personalized => Icons.notifications_none,
    SubscriptionNotificationLevel.none => Icons.notifications_off_outlined,
  };

  String get label => switch (this) {
    SubscriptionNotificationLevel.all => 'All',
    SubscriptionNotificationLevel.personalized => 'Personalized',
    SubscriptionNotificationLevel.none => 'None',
  };
}

/// The pill every subscribe affordance in the app shares (Task 22) — the
/// feed grid's channel tiles, the watch page's channel row, and the search
/// artist panel.
///
/// Unsubscribed: a plain, prominent pill labelled "Subscribe" — filled with
/// `scheme.onSurface`, the app's one "solid, demands attention" button
/// treatment. It does not open a dropdown; there is nothing to configure
/// before the user has actually subscribed.
///
/// Subscribed: a muted `scheme.surfaceContainerHighest` pill whose icon
/// mirrors the current [SubscriptionNotificationLevel], opening a dropdown
/// (`MenuAnchor`, matching `accent_debug_button.dart`'s pattern) with the
/// three notification levels plus Unsubscribe.
///
/// [onSubscribe] is the one hook wired to something real anywhere in the
/// app today (`ArtistPanelCard`'s `action.subscribe`) — it must resolve to
/// `true` on success and `false` on failure, and must not throw; a caller
/// wrapping a real RPC catches its own errors (auth, network) and reports
/// them however it already does. Its default is a local-only stub that
/// always succeeds immediately. [onUnsubscribe] and
/// [onNotificationLevelChanged] have no real endpoint to call *anywhere*
/// yet, so their defaults are the only implementation there is for now.
///
/// The widget keeps its own subscribed/level state, seeded once from
/// [initiallySubscribed] / [initialNotificationLevel]. A caller whose
/// underlying entity can change while this widget stays mounted (the watch
/// page swapping videos, the artist panel swapping artists) must key it
/// with something that changes too — e.g. `key: ValueKey(channelId)` — so
/// Flutter remounts fresh state instead of keeping the previous channel's.
class SubscribeButton extends ConsumerStatefulWidget {
  const SubscribeButton({
    super.key,
    required this.channelId,
    this.initiallySubscribed = false,
    this.initialNotificationLevel = SubscriptionNotificationLevel.personalized,
    this.onSubscribe,
    this.onUnsubscribe,
    this.onNotificationLevelChanged,
    this.minHeight = 44,
    this.foreground,
    this.background,
    this.unsubscribedForeground,
    this.unsubscribedBackground,
    this.dense = false,
    this.textStyle,
  });

  /// Null when the caller has no channel id yet (e.g. a `VideoItem` whose
  /// `channelId` is still unresolved) — the button renders disabled rather
  /// than not at all, so the layout doesn't jump once it resolves.
  final String? channelId;

  final bool initiallySubscribed;
  final SubscriptionNotificationLevel initialNotificationLevel;

  final Future<bool> Function(String channelId)? onSubscribe;

  /// Answers whether the unsubscribe landed, so a failed one can be put back —
  /// the same contract [onSubscribe] already has. `action.unsubscribe` exists
  /// now, so this is no longer a fire-and-forget local flip.
  final Future<bool> Function(String channelId)? onUnsubscribe;
  final void Function(String channelId, SubscriptionNotificationLevel level)? onNotificationLevelChanged;

  /// Match the surrounding row's button height — 36 in every feed tile, 45
  /// on the watch page's larger channel row.
  final double minHeight;

  /// Colour overrides for a caller painting on a surface the theme knows
  /// nothing about — `ArtistPanelCard`'s hero is filled with YouTube's own
  /// per-artist colour, against which `scheme.surfaceContainerHighest` and
  /// `scheme.onSurface` are arbitrary and can land invisible. Null keeps the
  /// scheme roles, which is right everywhere else.
  final Color? foreground;
  final Color? background;
  final Color? unsubscribedForeground;
  final Color? unsubscribedBackground;

  /// Drops Material's 48 px touch target so the pill lays out at the
  /// [minHeight] it was actually given, for a row of pills sized to match
  /// each other. Opt-in: every other call site is a lone button with room
  /// around it and no reason to shrink.
  final bool dense;

  /// Pairs with [dense]: the label style the surrounding row uses, so the
  /// pills in it cannot drift apart in size.
  final TextStyle? textStyle;

  @override
  ConsumerState<SubscribeButton> createState() => _SubscribeButtonState();
}

class _SubscribeButtonState extends ConsumerState<SubscribeButton> {
  late bool _subscribed = widget.initiallySubscribed;
  late SubscriptionNotificationLevel _level = widget.initialNotificationLevel;
  bool _subscribing = false;

  final MenuController _menuController = MenuController();
  ScrollPosition? _scrollPosition;

  /// Opening the menu moves focus to its first entry, and closing it hands focus
  /// back to the button (`MenuAnchor` does the second only when it is told which
  /// node the button is). `media_tile.dart`'s `_TileMoreButton` is the same.
  final FocusNode _buttonFocus = FocusNode(debugLabel: 'subscribed button');
  final FocusNode _firstItemFocus = FocusNode(debugLabel: 'subscribed menu first entry');

  void _toggleMenu(MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open();
    KeyboardNavigation.focusAfterOpen(_firstItemFocus, stillWanted: () => mounted && controller.isOpen);
  }

  /// Driven only by a `MouseRegion`'s own `onEnter`/`onExit` on each menu
  /// item, not by `MenuItemButton`'s built-in `WidgetState.hovered`. The
  /// built-in state stuck once a menu item was hovered and the pointer left
  /// the menu entirely - `MenuAnchor` moves keyboard focus to whatever item
  /// the mouse is over, and does not clear it when nothing else takes focus,
  /// so any style keyed off the button's own states (hovered, focused, or
  /// both) kept painting. Tracking hover ourselves, from an event source
  /// that only ever fires on real pointer enter/exit, sidesteps that
  /// regardless of which combination of button states caused it.
  SubscriptionNotificationLevel? _hoveredLevel;
  bool _unsubscribeHovered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newScrollPosition = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != newScrollPosition) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = newScrollPosition;
      _scrollPosition?.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    try {
      _scrollPosition?.removeListener(_onScroll);
    } catch (_) {}
    _buttonFocus.dispose();
    _firstItemFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_menuController.isOpen) {
      _menuController.close();
    }
  }

  /// Follow a *changed* `initiallySubscribed` from the parent.
  ///
  /// Without this the button was frozen at whatever it was first built with.
  /// The watch page builds it before `video.info` has answered — so with
  /// `false` — and when the real answer arrived a moment later the button never
  /// heard, and a subscribed channel read "Subscribe" for the whole visit (the
  /// `ValueKey` did not change either, since a feed tile already carries the
  /// channel id). Callers now also feed it the session's own record of what the
  /// user did (`subscriptionActionsProvider`), which only works if a new value
  /// is actually listened to.
  ///
  /// Ignored while a request of this button's own is out: its optimistic value
  /// is newer than anything the parent can know yet, and the parent is updated
  /// the moment that request answers.
  @override
  void didUpdateWidget(SubscribeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallySubscribed == widget.initiallySubscribed) return;
    if (_subscribing || _unsubscribing) return;
    _subscribed = widget.initiallySubscribed;
  }

  Future<void> _subscribe() async {
    final channelId = widget.channelId;
    if (channelId == null) return;

    setState(() => _subscribing = true);
    final subscribed = widget.onSubscribe == null ? true : await widget.onSubscribe!(channelId);
    if (!mounted) return;
    setState(() {
      _subscribing = false;
      if (subscribed) _subscribed = true;
    });
  }

  bool _unsubscribing = false;

  /// Update immediately, revert on failure — the same rule [_subscribe]
  /// follows. A tap here is far rarer than a like or a Watch Later save, but
  /// the account state it changes is exactly as real.
  Future<void> _unsubscribe() async {
    final channelId = widget.channelId;
    if (channelId == null || _unsubscribing) return;

    setState(() {
      _unsubscribing = true;
      _subscribed = false;
    });
    final unsubscribed = widget.onUnsubscribe == null ? true : await widget.onUnsubscribe!(channelId);
    if (!mounted) return;
    setState(() {
      _unsubscribing = false;
      if (!unsubscribed) _subscribed = true;
    });
  }

  void _setLevel(SubscriptionNotificationLevel level) {
    final channelId = widget.channelId;
    if (channelId != null) widget.onNotificationLevelChanged?.call(channelId, level);
    setState(() => _level = level);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Subscribing needs an account, and a *degraded* session is not one — the
    // cookie is there and YouTube has stopped honouring it (hard invariant 5),
    // which looks like being signed in everywhere else. The button used to be
    // pressable in both states and only said so after the call came back.
    // `signedInActionBlocker` is the same sentence the watch page's rating and
    // the comment vote buttons use.
    final blocked = signedInActionBlocker(
      ref.watch(authProvider.select((auth) => auth.status)),
      'subscribe',
    );

    // A menu already open when the account goes away must not outlive it.
    if (blocked != null && _menuController.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _menuController.isOpen) _menuController.close();
      });
    }

    if (!_subscribed) {
      final button = FilledButton(
        onPressed: widget.channelId == null || _subscribing || blocked != null ? null : _subscribe,
        style:
            FilledButton.styleFrom(
              backgroundColor: widget.unsubscribedBackground ?? scheme.onSurface,
              foregroundColor: widget.unsubscribedForeground ?? scheme.surface,
              disabledBackgroundColor: (widget.unsubscribedBackground ?? scheme.onSurface).withValues(alpha: 0.38),
              shape: const StadiumBorder(),
              padding: EdgeInsets.symmetric(horizontal: widget.dense ? 18 : 20),
              minimumSize: Size(0, widget.minHeight),
              tapTargetSize: widget.dense ? MaterialTapTargetSize.shrinkWrap : null,
              textStyle: widget.textStyle,
            ).copyWith(
              // Click while it can be pressed, the basic arrow while blocked or busy,
              // as the like and dislike pills do. A fixed `click` here pointed at a
              // disabled button.
              mouseCursor: WidgetStateMouseCursor.clickable,
            ),
        child: _subscribing
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: widget.unsubscribedForeground ?? scheme.surface,
                ),
              )
            : const Text('Subscribe'),
      );
      return blocked == null ? button : ShortcutTooltip(label: blocked, child: button);
    }

    final subscribed = MenuAnchor(
      controller: _menuController,
      childFocusNode: _buttonFocus,
      onClose: () {
        if (mounted && _firstItemFocus.hasFocus) _buttonFocus.requestFocus();
      },
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(widget.background ?? scheme.surfaceContainerHighest),
        shape: WidgetStatePropertyAll(const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)))),
        mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
      ),
      animated: true,
      builder: (context, controller, child) => FilledButton.tonal(
        focusNode: _buttonFocus,
        // The menu is the way to unsubscribe, which needs an account just as
        // subscribing does — and a degraded session reaches here looking exactly
        // like a signed-in one (Task 31 §2).
        onPressed: blocked != null ? null : () => _toggleMenu(controller),
        style:
            FilledButton.styleFrom(
              backgroundColor: widget.background ?? scheme.surfaceContainerHighest,
              foregroundColor: widget.foreground ?? scheme.onSurface,
              disabledBackgroundColor: (widget.background ?? scheme.surfaceContainerHighest).withValues(alpha: 0.38),
              disabledForegroundColor: (widget.foreground ?? scheme.onSurface).withValues(alpha: 0.38),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: Size(0, widget.minHeight),
              tapTargetSize: widget.dense ? MaterialTapTargetSize.shrinkWrap : null,
              textStyle: widget.textStyle,
            ).copyWith(
              // Click while it can be pressed, the basic arrow while blocked or busy,
              // as the like and dislike pills do. A fixed `click` here pointed at a
              // disabled button.
              mouseCursor: WidgetStateMouseCursor.clickable,
            ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_level.icon, size: 18),
            const SizedBox(width: 6),
            const Text('Subscribed'),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_down, size: 18),
          ],
        ),
      ),
      menuChildren: [
        for (final level in SubscriptionNotificationLevel.values)
          MouseRegion(
            onEnter: (_) => setState(() => _hoveredLevel = level),
            onExit: (_) => setState(() {
              if (_hoveredLevel == level) _hoveredLevel = null;
            }),
            child: FocusRingShape(inflate: -1, child: MenuItemButton(
              focusNode: level == SubscriptionNotificationLevel.values.first ? _firstItemFocus : null,
              style: MenuItemButton.styleFrom(
                overlayColor: Colors.transparent,
                backgroundColor: level == _level
                    ? (level == _hoveredLevel ? scheme.primary.withValues(alpha: 0.25) : scheme.primary.withValues(alpha: 0.2)) // selected
                    : (level == _hoveredLevel ? scheme.onSurface.withValues(alpha: 0.07) : null), // not selected
              ),
              leadingIcon: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(level.icon),
              ),
              onPressed: () => _setLevel(level),
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(level.label),
              ),
            )),
          ),
        const Divider(height: 1),
        MouseRegion(
          onEnter: (_) => setState(() => _unsubscribeHovered = true),
          onExit: (_) => setState(() => _unsubscribeHovered = false),
          child: FocusRingShape(inflate: -1, child: MenuItemButton(
            style: MenuItemButton.styleFrom(
              overlayColor: Colors.transparent,
              backgroundColor: _unsubscribeHovered ? scheme.onSurface.withValues(alpha: 0.08) : null,
            ),
            leadingIcon: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: const Icon(Icons.person_remove_outlined),
            ),
            onPressed: _unsubscribe,
            child: const Text('Unsubscribe'),
          )),
        ),
      ],
    );
    return blocked == null ? subscribed : ShortcutTooltip(label: blocked, child: subscribed);
  }
}
