import 'package:flutter/material.dart';

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
  const FeedSkeleton({super.key, required this.isWideLayout});

  final bool isWideLayout;

  @override
  State<FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<FeedSkeleton>
    with SingleTickerProviderStateMixin {
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
        final columns =
            FeedGridMetrics.columnCount(constraints.maxWidth, widget.isWideLayout);
        final rowGap = FeedGridMetrics.verticalSpacing(widget.isWideLayout);

        // Enough rows to fill the viewport and no more. A fixed count leaves a
        // short skeleton floating on a tall window, which looks like a feed
        // that finished loading with three items in it.
        final estimatedRowHeight = widget.isWideLayout
            ? _wideTileHeight
            : (constraints.maxWidth / columns) / ScreenValues.normalAspectRatio +
                _captionBlockHeight;
        final rows = estimatedRowHeight <= 0
            ? 3
            : ((constraints.maxHeight / (estimatedRowHeight + rowGap)).ceil() + 1)
                .clamp(1, 12);

        return FadeTransition(
          opacity: _pulse,
          // Excluded from semantics, not just visually inert: a screen reader
          // announcing a dozen empty boxes is worse than announcing nothing.
          // The surface's own loading state is what should be read out.
          child: ExcludeSemantics(
            child: SingleChildScrollView(
              // Never scrollable. It is a placeholder, and letting it scroll
              // would let a user drag it around as though it were content.
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                children: List.generate(rows, (_) {
                  final row = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: FeedGridMetrics.horizontalSpacing,
                    children: List.generate(
                      columns,
                      (_) => Expanded(
                        child: _SkeletonTile(isWide: widget.isWideLayout),
                      ),
                    ),
                  );
                  return Padding(
                    padding: EdgeInsets.only(bottom: rowGap),
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
const double _wideTileHeight = 128.0;

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile({required this.isWide});

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // `surfaceContainerHighest` rather than a grey literal: the placeholder has
    // to read as "surface" in both themes, and `lib/ui` is lint-gated against
    // colour literals for exactly this reason.
    final block = scheme.surfaceContainerHighest;

    Widget bar(double widthFactor, double height) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: block,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );

    final thumbnail = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: ScreenValues.normalAspectRatio,
        child: ColoredBox(color: block),
      ),
    );

    if (isWide) {
      return SizedBox(
        height: _wideTileHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 200, child: thumbnail),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(0.9, 16),
                  const SizedBox(height: 10),
                  bar(0.5, 12),
                  const SizedBox(height: 8),
                  bar(0.7, 12),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        thumbnail,
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: block, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(1.0, 14),
                  const SizedBox(height: 8),
                  bar(0.55, 12),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
