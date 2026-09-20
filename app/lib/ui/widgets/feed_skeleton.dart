import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme/accent.dart';
import '../../theme/screen_values.dart';
import 'feed_grid_metrics.dart';

/// The feed's first-load placeholder.
///
/// Replaces the centred spinner that used to sit there. A spinner says "wait";
/// a skeleton says "a grid of videos is coming, and this is where it will be" —
/// which matters most on the path this was built for, the moment after a
/// sign-in, where the alternative is a blank page immediately after a login
/// window closes and the user has no idea whether it worked.
///
/// **It shares [FeedGridMetrics] with the real grid and nothing else.** Column
/// count, spacing and the thumbnail aspect ratio come from the same source
/// [FeedView] uses, so the placeholder tiles sit exactly where the real ones
/// will and nothing reflows when they arrive. The tile itself is a separate
/// leaf rather than a mode of `MediaTile` — see `feed_grid_metrics.dart`.
///
/// **One controller for the whole grid, never one per tile.** The same rule the
/// hover preview follows for players (`CLAUDE.md`), for the same reason: N
/// tiles each driving their own animation is N tickers and N rebuilds a frame.
/// A single [FadeTransition] over the subtree pulses in one compositor layer
/// and rebuilds nothing at all — the children below it are built once.
class FeedSkeleton extends StatefulWidget {
  const FeedSkeleton({super.key, required this.isWideLayout, this.randomSeed = 9});

  final bool isWideLayout;

  /// Seeds which tiles get a one- or two-line title, and how long the second
  /// line runs — the same seeded-`Random` idiom the watch skeleton's queue uses
  /// for its row widths.
  ///
  /// **Seeded rather than `Random()` so a rebuild draws the same skeleton.**
  /// The tiles used to roll the dice in their own `build`, and a placeholder
  /// that reshuffles whenever the window is resized reads as content changing
  /// under the user's eyes. Pass a different seed to make two surfaces look
  /// different from each other; the same one gives the same grid every time.
  final int randomSeed;

  @override
  State<FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<FeedSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  ).drive(Tween<double>(begin: 0.45, end: 1.0));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = FeedGridMetrics.columnCount(constraints.maxWidth, widget.isWideLayout);
        final rowGap = FeedGridMetrics.verticalSpacing(widget.isWideLayout);

        // Enough rows to fill the viewport and no more. A fixed count leaves a
        // short skeleton floating on a tall window, which looks like a feed
        // that finished loading with three items in it.
        final estimatedRowHeight = widget.isWideLayout ? _wideTileHeight : (constraints.maxWidth / columns) / ScreenValues.normalAspectRatio + _captionBlockHeight;
        final rows = estimatedRowHeight <= 0 ? 3 : ((constraints.maxHeight / (estimatedRowHeight + rowGap)).ceil() + 1).clamp(1, 12);

        // One generator for the whole grid, drawn from in reading order and
        // re-seeded on every build, so the same layout always gets the same
        // tiles. Each tile takes the same two draws whatever they turn out to
        // be, so one tile's line count never shifts its neighbours' widths.
        final random = Random(widget.randomSeed);

        return FadeTransition(
          opacity: _pulse,
          // Excluded from semantics, not just visually inert: a screen reader
          // announcing a dozen empty boxes is worse than announcing nothing.
          // The surface's own loading state is what should be read out.
          child: ExcludeSemantics(
            child: Padding(
              padding: EdgeInsets.only(left: 8, right: 12),
              child: SingleChildScrollView(
                // Never scrollable. It is a placeholder, and letting it scroll
                // would let a user drag it around as though it were content.
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  children: List.generate(rows, (rowIndex) {
                    final row = Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: FeedGridMetrics.horizontalSpacing,
                      children: List.generate(
                        columns,
                        (_) => Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(top: rowIndex == 0 ? 12 : 0, left: 9.0),
                            child: _SkeletonTile(
                              isWide: widget.isWideLayout,
                              twoLineTitle: random.nextBool(),
                              secondLineFactor: 0.25 + random.nextDouble() * 0.6,
                              isMix: random.nextBool(),
                            ),
                          ),
                        ),
                      ),
                    );
                    return Padding(
                      padding: EdgeInsets.only(bottom: rowGap + 8, top: rowIndex == 0 ? 4 : 0),
                      child: widget.isWideLayout
                          ? Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: ScreenValues.contentMaxWidth,
                                ),
                                child: row,
                              ),
                            )
                          : row,
                    );
                  }),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Thumbnail plus two metadata lines, roughly what `MediaTile` occupies below
/// its image. Approximate on purpose — what has to match is the *height*, so
/// the grid does not reflow; the bars inside it are decoration.
const double _captionBlockHeight = 76.0;

/// A wide (search-layout) row is a fixed-height horizontal tile.
const double _wideTileHeight = 225.0;

/// Marks the second title line, so a test can tell a one-line tile from a
/// two-line one without measuring pixels.
@visibleForTesting
const Key feedSkeletonSecondTitleLineKey = Key('feed-skeleton-second-title-line');

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile({
    required this.isWide,
    required this.twoLineTitle,
    required this.secondLineFactor,
    required this.isMix,
  });

  final bool isWide;

  /// Whether the title wraps onto a second line. Decided by the grid's seeded
  /// generator, never here: a tile that rolled its own dice re-rolled them on
  /// every rebuild.
  final bool twoLineTitle;

  /// How much of the width the second line fills, when there is one.
  final double secondLineFactor;

  /// Whether the channel icon is shown. (Video vs Mix)
  final bool isMix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // `surfaceContainerHighest` rather than a grey literal: the placeholder has
    // to read as "surface" in both themes, and `lib/ui` is lint-gated against
    // colour literals for exactly this reason.
    final block = scheme.surfaceContainerHighest;
    final extra = isWide ? 8.0 : 0.0; // Extra space for the second line.

    Widget rect(double height) => Container(
      height: height,
      decoration: BoxDecoration(
        color: block,
        borderRadius: BorderRadius.circular(4),
      ),
    );

    // A fraction of the column's width. Only for a child of something that
    // bounds its width — a `Column`, not a `Row`, which hands non-flex children
    // unbounded width and makes this assert "forces an infinite width".
    Widget bar(double widthFactor, double height, {Key? key}) => FractionallySizedBox(
      key: key,
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: rect(height),
    );

    final thumbnail = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: ScreenValues.normalAspectRatio,
        child: ColoredBox(color: block),
      ),
    );

    final meta = [
      bar(1.0, 14),
      if (twoLineTitle) ...[
        const SizedBox(height: 8),
        bar(secondLineFactor, 14, key: feedSkeletonSecondTitleLineKey),
      ],
      const SizedBox(height: 8),
      // channel name
      bar(0.25, 12),
      if (!isMix) ...[
        const SizedBox(height: 8),
        // views • age
        bar(0.45, 12),
      ],
    ];

    final wideMeta = [
      const SizedBox(height: 12),
      bar(twoLineTitle ? 1.0 : secondLineFactor, 14),
      if (twoLineTitle) ...[
        const SizedBox(height: 8),
        bar(secondLineFactor, 14, key: feedSkeletonSecondTitleLineKey),
      ],
      
      const SizedBox(height: 12),
      // views • age
      bar(0.45, 12),
      
      // Avatar + channel name
      const SizedBox(height: 13),
      Row(
        children: [
          // Avatar
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: block,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          // channel name
          Expanded(child: bar(0.12 + secondLineFactor * 0.2 - 0.1, 12),),
        ],
      ),
      const SizedBox(height: 13),
      bar(0.85 + secondLineFactor * 0.15, 12),
    ];

    if (isWide) {
      return SizedBox(
        height: _wideTileHeight + extra,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 400, child: thumbnail),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: wideMeta,
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Stacked cards for Mixes
        if (isMix) ...[
          AnimatedPositioned(
            duration: const Duration(milliseconds: 100),
            top: -8,
            left: 24,
            right: 24,
            bottom: 108,
            child: Container(
              decoration: BoxDecoration(
                color: block.darken(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 100),
            top: -4,
            left: 12,
            right: 12,
            bottom: 104,
            child: Container(
              decoration: BoxDecoration(
                color: block.darken(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            thumbnail,
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMix) ...[
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: block, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: meta,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.more_vert, size: 25, color: block),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
