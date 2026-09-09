import 'package:flutter/material.dart';

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
/// **The green is a literal, and that is deliberate.** `lib/ui` is lint-gated
/// against colour literals because almost every colour should be a
/// `ColorScheme` role — but this one is not a role, it is a *brand signal*: the
/// same green YouTube uses for memberships everywhere, which is what makes the
/// pill recognisable at a glance in a grid. Painting it with `primary` would
/// re-tint it whenever the user changes the app's accent, which is the one
/// thing it must not do. It is a token in `tokens.dart` for that reason, so
/// there is one copy of it rather than one per surface.
///
/// The star is `SPONSORSHIP_STAR`, which is the icon YouTube ships on the badge
/// itself — the sidecar reads it as one of the two membership signals.
class MembersOnlyBadge extends StatelessWidget {
  const MembersOnlyBadge({super.key, this.label = 'Members only'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Pill(
      background: isDark ? membersGreenSurfaceDark : membersGreenSurfaceLight,
      foreground: isDark ? membersGreenOnSurfaceDark : membersGreenOnSurfaceLight,
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

/// YouTube's membership green, as a pill background and its text colour.
///
/// Two pairs because the pill has to stay legible on both grounds: the dark
/// pair is a deep, desaturated fill with a bright glyph, the light pair the
/// reverse. Not `ColorScheme` roles — see [MembersOnlyBadge] for why this one
/// colour is allowed to be fixed.
const Color membersGreenSurfaceDark = Color(0xFF0F3D2E);
const Color membersGreenOnSurfaceDark = Color(0xFF5FD69A);
const Color membersGreenSurfaceLight = Color(0xFFD7F2E3);
const Color membersGreenOnSurfaceLight = Color(0xFF0B6B45);

/// The membership green for anything drawn **over a scrim**, in either theme.
///
/// Equal to the on-dark value, and deliberately not branched on brightness —
/// which is the opposite of what [MembersOnlyBadge] does two definitions up, so
/// it is worth saying why. `RillTokens.scrim` is opaque **black in both
/// themes** and `onScrim` white in both, because a scrim sits over an arbitrary
/// thumbnail rather than over a surface (`tokens.dart`'s own class doc). The
/// ground under the watch page's members slate is therefore dark whatever the
/// app theme is, and the light-surface green would be the wrong choice there.
///
/// A named alias rather than the raw `…OnSurfaceDark` constant at the call
/// site: reading "on scrim" at the point of use answers the question, where
/// reading "on surface dark" inside a light-themed app invites the reasonable
/// conclusion that somebody forgot a branch.
const Color membersGreenOnScrim = membersGreenOnSurfaceDark;
