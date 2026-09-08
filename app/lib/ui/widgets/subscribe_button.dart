import 'package:flutter/material.dart';

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
class SubscribeButton extends StatefulWidget {
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
  final void Function(String channelId)? onUnsubscribe;
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
  State<SubscribeButton> createState() => _SubscribeButtonState();
}

class _SubscribeButtonState extends State<SubscribeButton> {
  late bool _subscribed = widget.initiallySubscribed;
  late SubscriptionNotificationLevel _level = widget.initialNotificationLevel;
  bool _subscribing = false;

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

  void _unsubscribe() {
    final channelId = widget.channelId;
    if (channelId == null) return;
    widget.onUnsubscribe?.call(channelId);
    setState(() => _subscribed = false);
  }

  void _setLevel(SubscriptionNotificationLevel level) {
    final channelId = widget.channelId;
    if (channelId != null) widget.onNotificationLevelChanged?.call(channelId, level);
    setState(() => _level = level);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (!_subscribed) {
      return FilledButton(
        onPressed: widget.channelId == null || _subscribing ? null : _subscribe,
        style: FilledButton.styleFrom(
          backgroundColor: widget.unsubscribedBackground ?? scheme.onSurface,
          foregroundColor: widget.unsubscribedForeground ?? scheme.surface,
          disabledBackgroundColor: (widget.unsubscribedBackground ?? scheme.onSurface).withValues(alpha: 0.38),
          shape: const StadiumBorder(),
          padding: EdgeInsets.symmetric(horizontal: widget.dense ? 18 : 20),
          minimumSize: Size(0, widget.minHeight),
          tapTargetSize: widget.dense ? MaterialTapTargetSize.shrinkWrap : null,
          textStyle: widget.textStyle,
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
    }

    return MenuAnchor(
      builder: (context, controller, child) => FilledButton.tonal(
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        style: FilledButton.styleFrom(
          backgroundColor: widget.background ?? scheme.surfaceContainerHighest,
          foregroundColor: widget.foreground ?? scheme.onSurface,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          minimumSize: Size(0, widget.minHeight),
          tapTargetSize: widget.dense ? MaterialTapTargetSize.shrinkWrap : null,
          textStyle: widget.textStyle,
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
          MenuItemButton(
            leadingIcon: Icon(level.icon),
            trailingIcon: level == _level ? const Icon(Icons.check) : null,
            onPressed: () => _setLevel(level),
            child: Text(level.label),
          ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.person_remove_outlined),
          onPressed: _unsubscribe,
          child: const Text('Unsubscribe'),
        ),
      ],
    );
  }
}
