import 'package:flutter/material.dart';

/// The colours that are genuinely not `ColorScheme` roles.
///
/// A role is the right answer for almost everything, and `lib/ui/` may use
/// nothing else. Three things resist it, and inventing a role for them would be
/// forcing a fit:
///
/// - **`scrim` / `onScrim`.** These sit over an arbitrary thumbnail, not over a
///   surface. Their job is contrast against an image nobody chose, so they must
///   not move when the accent does.
/// - **`liveBadge`.** Red here is a *status*, the same red every video client
///   uses for a live stream. It is not branding and it is not the accent — an
///   accent-coloured LIVE badge would say "themed", not "live".
/// - **`stackedCardBack` / `stackedCardFront`.** The paper edges peeking out
///   from behind a mix thumbnail. Derived from surface roles for now; waiting on
///   palette extraction from the thumbnail itself, cached off the UI isolate.
@immutable
class RillTokens extends ThemeExtension<RillTokens> {
  const RillTokens({
    required this.scrim,
    required this.onScrim,
    required this.liveBadge,
    required this.stackedCardBack,
    required this.stackedCardFront,
  });

  /// Opaque black. Use `.withValues(alpha:)` at the call site so the strength of
  /// each scrim is visible where it is applied.
  final Color scrim;

  /// The foreground that is legible on [scrim] at any alpha.
  final Color onScrim;

  final Color liveBadge;
  final Color stackedCardBack;
  final Color stackedCardFront;

  factory RillTokens.from(ColorScheme scheme) => RillTokens(
    scrim: const Color(0xFF000000),
    onScrim: const Color(0xFFFFFFFF),
    // Status, not brand. See the class doc.
    liveBadge: const Color(0xFFE53935),
    stackedCardBack: scheme.surfaceContainerHighest,
    stackedCardFront: scheme.surfaceBright,
  );

  @override
  RillTokens copyWith({
    Color? scrim,
    Color? onScrim,
    Color? liveBadge,
    Color? stackedCardBack,
    Color? stackedCardFront,
  }) => RillTokens(
    scrim: scrim ?? this.scrim,
    onScrim: onScrim ?? this.onScrim,
    liveBadge: liveBadge ?? this.liveBadge,
    stackedCardBack: stackedCardBack ?? this.stackedCardBack,
    stackedCardFront: stackedCardFront ?? this.stackedCardFront,
  );

  @override
  RillTokens lerp(RillTokens? other, double t) {
    if (other == null) return this;
    return RillTokens(
      scrim: Color.lerp(scrim, other.scrim, t)!,
      onScrim: Color.lerp(onScrim, other.onScrim, t)!,
      liveBadge: Color.lerp(liveBadge, other.liveBadge, t)!,
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
