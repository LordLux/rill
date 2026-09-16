import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The row of small pills under a tile's title.
///
/// One widget rather than the two near-identical `Wrap`s that used to sit in
/// `media_tile.dart` — the standard and wide layouts each had their own copy,
/// and adding the members pill to only one of them is exactly the drift that
/// invites.
///
/// **Members-only is a flag, not a string.** The sidecar keys it on
/// `BADGE_STYLE_TYPE_MEMBERS_ONLY` and keeps `"Members only"` out of
/// [badges] (`CLAUDE.md`), so this draws it from [isMembersOnly] and never by
/// matching a label — the label is localised and the style is not.
class TileBadges extends StatelessWidget {
  const TileBadges({
    super.key,
    required this.badges,
    this.isMembersOnly = false,
    this.topPadding = 8.0,
  });

  final List<String> badges;
  final bool isMembersOnly;
  final double topPadding;

  bool get _isEmpty => badges.isEmpty && !isMembersOnly;

  @override
  Widget build(BuildContext context) {
    if (_isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          // First, because it is the one that changes what the tile *is* rather
          // than describing its picture ("4K", "New").
          if (isMembersOnly) const MembersOnlyBadge(),
          // Ordinary badges stay on a surface role — §3.3 keeps the accent off
          // them, and the members pill below is a deliberate exception with a
          // colour of its own rather than the theme's.
          for (final badge in badges)
            _Pill(
              background: scheme.surfaceContainerHighest,
              foreground: scheme.onSurfaceVariant,
              label: badge,
            ),
        ],
      ),
    );
  }
}

/// The green "Members only" pill, with YouTube's own star.
///
/// **The green is a token, not a role, and that is deliberate.** Almost every
/// colour should be a `ColorScheme` role — but this one is a *brand signal*:
/// the same green YouTube uses for memberships everywhere, which is what makes
/// the pill recognisable at a glance in a grid. Painting it with `primary`
/// would re-tint it whenever the user changes the app's accent, which is the
/// one thing it must not do. So it lives in `tokens.dart`
/// (`RillTokens.membersBadge`), one copy rather than one per surface.
///
/// The star is `SPONSORSHIP_STAR`, which is the icon YouTube ships on the badge
/// itself — the sidecar reads it as one of the two membership signals.
class MembersOnlyBadge extends StatelessWidget {
  const MembersOnlyBadge({super.key, this.label = 'Members only'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    return _Pill(
      background: tokens.membersBadge,
      foreground: tokens.onMembersBadge,
      label: label,
      icon: Icons.star_rounded,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.background,
    required this.foreground,
    required this.label,
    this.icon,
  });

  final Color background;
  final Color foreground;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: foreground),
            const SizedBox(width: 3),
          ],
          Text(label, style: TextStyle(fontSize: 10, color: foreground)),
        ],
      ),
    );
  }
}
