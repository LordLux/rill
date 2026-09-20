import 'package:flutter/material.dart';

/// The colours that are genuinely not `ColorScheme` roles.
///
/// A role is the right answer for almost everything, and `lib/ui/` may use
/// nothing else. These resist it, and inventing a role for them would be
/// forcing a fit:
///
/// - **`scrim` / `onScrim`.** These sit over an arbitrary thumbnail, not over a
///   surface. Their job is contrast against an image nobody chose, so they must
///   not move when the accent does. `onPaleTint` is the same job on a *light*
///   ground nobody chose — the artist panel's own tint — where [onScrim] would
///   vanish.
/// - **`liveBadge`.** Red here is a *status*, the same red every video client
///   uses for a live stream. It is not branding and it is not the accent — an
///   accent-coloured LIVE badge would say "themed", not "live".
/// - **`windowClose`.** The title bar's close button: pure red, the platform
///   convention for "this closes the app" rather than a semantic error, and
///   so not `ColorScheme.error`, which is tuned for error text and surfaces.
/// - **`membersBadge` / `onMembersBadge` / `membersOnScrim`.** YouTube's
///   membership green — a brand signal recognised at a glance in a grid, and
///   the one thing it must not do is re-tint with the accent. Unlike the
///   others it has a light and a dark pair, resolved from the scheme's
///   brightness, because the pill sits on a surface that changes with it.
/// - **`stackedCardBack` / `stackedCardFront`.** The paper edges peeking out
///   from behind a mix thumbnail. Derived from surface roles for now; waiting on
///   palette extraction from the thumbnail itself, cached off the UI isolate.
@immutable
class RillTokens extends ThemeExtension<RillTokens> {
  const RillTokens({
    required this.scrim,
    required this.onScrim,
    required this.onPaleTint,
    required this.liveBadge,
    required this.windowClose,
    required this.membersBadge,
    required this.onMembersBadge,
    required this.membersOnScrim,
    required this.stackedCardBack,
    required this.stackedCardFront,
  });

  /// Opaque black. Use `.withValues(alpha:)` at the call site so the strength of
  /// each scrim is visible where it is applied.
  final Color scrim;

  /// The foreground that is legible on [scrim] at any alpha.
  final Color onScrim;

  /// Text on a pale colour the app did not choose. Near-black rather than
  /// [scrim]'s pure black, deliberately — `artist_panel_test.dart` pins it.
  final Color onPaleTint;

  final Color liveBadge;

  /// The close button's hover fill. Pressed applies alpha at the call site.
  final Color windowClose;

  /// The "Members only" pill's fill, for the current brightness.
  final Color membersBadge;

  /// The glyph and label on [membersBadge].
  final Color onMembersBadge;

  /// The membership green for anything drawn **over a scrim**, in either theme.
  ///
  /// Deliberately not resolved from brightness, which is the opposite of
  /// [membersBadge]. [scrim] is opaque black in both themes because it sits
  /// over an arbitrary thumbnail rather than over a surface, so the ground
  /// under the watch page's members slate is dark whatever the app theme is,
  /// and the light-surface green would be the wrong choice there. Equal to the
  /// dark theme's [onMembersBadge].
  final Color membersOnScrim;

  final Color stackedCardBack;
  final Color stackedCardFront;

  // The membership green's two pairs: a deep, desaturated fill with a bright
  // glyph on dark, the reverse on light.
  static const Color _membersDark = Color(0xFF0F3D2E);
  static const Color _onMembersDark = Color(0xFF5FD69A);
  static const Color _membersLight = Color(0xFFD7F2E3);
  static const Color _onMembersLight = Color(0xFF0B6B45);

  factory RillTokens.from(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return RillTokens(
      scrim: const Color(0xFF000000),
      onScrim: const Color(0xFFFFFFFF),
      onPaleTint: const Color(0xFF0B0B0B),
      // Status, not brand. See the class doc.
      liveBadge: const Color(0xFFE53935),
      windowClose: const Color(0xFFFF0000),
      membersBadge: dark ? _membersDark : _membersLight,
      onMembersBadge: dark ? _onMembersDark : _onMembersLight,
      membersOnScrim: _onMembersDark,
      stackedCardBack: scheme.surfaceContainerHighest,
      stackedCardFront: scheme.surfaceBright,
    );
  }

  @override
  RillTokens copyWith({
    Color? scrim,
    Color? onScrim,
    Color? onPaleTint,
    Color? liveBadge,
    Color? windowClose,
    Color? membersBadge,
    Color? onMembersBadge,
    Color? membersOnScrim,
    Color? stackedCardBack,
    Color? stackedCardFront,
  }) => RillTokens(
    scrim: scrim ?? this.scrim,
    onScrim: onScrim ?? this.onScrim,
    onPaleTint: onPaleTint ?? this.onPaleTint,
    liveBadge: liveBadge ?? this.liveBadge,
    windowClose: windowClose ?? this.windowClose,
    membersBadge: membersBadge ?? this.membersBadge,
    onMembersBadge: onMembersBadge ?? this.onMembersBadge,
    membersOnScrim: membersOnScrim ?? this.membersOnScrim,
    stackedCardBack: stackedCardBack ?? this.stackedCardBack,
    stackedCardFront: stackedCardFront ?? this.stackedCardFront,
  );

  @override
  RillTokens lerp(RillTokens? other, double t) {
    if (other == null) return this;
    return RillTokens(
      scrim: Color.lerp(scrim, other.scrim, t)!,
      onScrim: Color.lerp(onScrim, other.onScrim, t)!,
      onPaleTint: Color.lerp(onPaleTint, other.onPaleTint, t)!,
      liveBadge: Color.lerp(liveBadge, other.liveBadge, t)!,
      windowClose: Color.lerp(windowClose, other.windowClose, t)!,
      membersBadge: Color.lerp(membersBadge, other.membersBadge, t)!,
      onMembersBadge: Color.lerp(onMembersBadge, other.onMembersBadge, t)!,
      membersOnScrim: Color.lerp(membersOnScrim, other.membersOnScrim, t)!,
      stackedCardBack: Color.lerp(stackedCardBack, other.stackedCardBack, t)!,
      stackedCardFront: Color.lerp(stackedCardFront, other.stackedCardFront, t)!,
    );
  }
}

extension RillTokensOf on ThemeData {
  /// Never null in this app: `buildRillTheme` always registers the extension.
  /// A `Theme` built some other way falls back to the tokens for its own scheme
  /// rather than throwing in a widget build.
  RillTokens get tokens =>
      extension<RillTokens>() ?? RillTokens.from(colorScheme);
}
