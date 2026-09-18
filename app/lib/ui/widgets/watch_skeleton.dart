import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/screen_values.dart';
import '../../theme/tokens.dart';
import '../pages/watch_layout.dart';
import '../playback_controller.dart';
import '../player/view_mode.dart';
import '../queue_controller.dart';
import 'adaptive_meta_row.dart';

/// The watch page before there is a video to show.
///
/// **Why this exists: starting a mix is a round trip.** `mix.start` takes
/// ~0.5–1 s, and the watch route used to be pushed only *after* it returned —
/// so a click on a mix tile did nothing visible for about a second. The app was
/// never blocked, but "nothing happened" is indistinguishable from a dead click
/// from the outside, and the reported consequence was users clicking again. The
/// route is pushed immediately now and this stands in until the first item
/// arrives.
///
/// **It drives the real [WatchLayout] rather than approximating it**, which is
/// the whole point: the watch page has three shapes — two-column, theatre, and
/// the single column it collapses to under ~889 px — and a placeholder that
/// hand-rolled its own would be wrong in at least one of them the first time
/// any of it moved. The same `computeWatchGeometry` call the page makes gives
/// the same player rectangle, the same rail width and the same collapse point,
/// so the skeleton is responsive for free and stays that way. This is the same
/// trick the libass ghost overlay already uses on this layout.
///
/// The one thing assumed rather than known: **there will be a queue.** This is
/// only ever shown while a mix is loading, and a mix always fills one — so the
/// rail draws a queue as well as a related list, and the content that arrives
/// lands in the shape already on screen.
///
/// Aspect ratio is the 16:9 reference, because the real one is not known until
/// the first frame decodes (architecture §2.8: "an undecoded frame size is not
/// 16:9" — the page holds the last real ratio, and before anything has decoded
/// the reference is all there is).
class WatchSkeleton extends ConsumerStatefulWidget {
  const WatchSkeleton({super.key});

  @override
  ConsumerState<WatchSkeleton> createState() => _WatchSkeletonState();
}

class _WatchSkeletonState extends ConsumerState<WatchSkeleton>
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
    final theatre = ref.watch(
      playerViewProvider.select((view) => view.theatre),
    );
    final playback = ref.watch(playbackProvider);
    final item =
        ref.watch(queueProvider.select((q) => q.current)) ?? playback.item;

    return FadeTransition(
      opacity: _pulse,
      // The boxes are excluded — a screen reader announcing a page of empty
      // placeholders is noise — but the page is not left silent: for the second
      // a mix takes to load, it says what it is doing.
      child: Semantics(
        container: true,
        liveRegion: true,
        label: 'Loading',
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final geometry = computeWatchGeometry(
                availableWidth: constraints.maxWidth,
                viewportHeight: MediaQuery.of(context).size.height,
                aspectRatio: ScreenValues.normalAspectRatio,
                theatre: theatre,
              );

              return WatchLayout(
                geometry: geometry,
                playerSlot: _Block(radius: theatre ? 0 : 12),
                theatreBackground: theatre ? Theme.of(context).tokens.scrim : null,
                metadataSlivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 4, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _MetaBlock(),
                          if (!geometry.isTwoColumn) ...[
                            const SizedBox(height: 24),
                            const _QueueBlock(maxHeight: 400),
                            const SizedBox(height: 24),
                            const _RelatedBlock(asGrid: true),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                railSlivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(8, theatre ? 8 : 2, 16, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _QueueBlock(
                            maxHeight: geometry.playerHeight,
                            randomSeed: item.hashCode,
                          ),
                          const SizedBox(height: 24),
                          const _RelatedBlock(),
                        ],
                      ),
                    ),
                  ),
                ],
                scrollable: false,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Title, channel row, action pills — what `_Meta` occupies.
class _MetaBlock extends StatelessWidget {
  const _MetaBlock();

  @override
  Widget build(BuildContext context) {
    final metaWidget = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 436),
      child: Row(
        children: [
          // Avatar
          const _Block(height: 36, width: 36, radius: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 0.5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Channel name
                  const _Block(height: 12),
                  const SizedBox(height: 7.5),
                  // Subscribers
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: 0.58,
                    child: const _Block(height: 9.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Subscribe button
          const _Block(height: 36, width: 152, radius: 18),
        ],
      ),
    );

    final actionsWidget = Flex(
      direction: Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 8,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Actions: like, dislike, share, save, watch later, more
        const _Block(height: 18, width: 100, margin: EdgeInsets.only(right: 8)),
        const _Block(height: 18, width: 100, margin: EdgeInsets.only(right: 8)),
        const _Block(height: 36, width: 124, radius: 18),
        const _Block(height: 36, width: 36, radius: 18),
        const _Block(height: 36, width: 36, radius: 18),
        const _Block(height: 36, width: 36, radius: 18),
        const _Block(height: 36, width: 36, radius: 18),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        const SizedBox(height: 5),
        // Video Title
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: 0.45,
          child: const _Block(height: 19.5),
        ),
        const SizedBox(height: 18.5),
        // Meta + Actions
        AdaptiveMetaRow(
          spacing: 16,
          meta: metaWidget,
          actions: actionsWidget,
        ),
        const SizedBox(height: 10),
        const _Block(height: 126, radius: 12),
      ],
    );
  }
}

/// The queue panel: a header, then rows of thumbnail plus two lines.
///
/// Drawn because this is only ever shown while a mix is loading, and a mix
/// always fills a queue — so the rail should not visibly gain a whole panel a
/// second after the page appears.
class _QueueBlock extends StatelessWidget {
  const _QueueBlock({required this.maxHeight, this.randomSeed = 9});

  /// Enough to fill the rail without running past it. The real panel is
  /// scrollable; this is not, so a longer list would just be clipped.
  static const int rows = 11;
  final double maxHeight;
  final int randomSeed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final random = math.Random(randomSeed);

    return Container(
      constraints: BoxConstraints(maxHeight: math.max(0.0, maxHeight)),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: OverflowBox(
          alignment: Alignment.topCenter,
          maxHeight: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: 0.7,
                              child: const _Block(height: 14),
                            ),
                            const SizedBox(height: 11),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: 0.45,
                              child: const _Block(height: 9),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        Icons.clear_all_sharp,
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        size: 18,
                      ),
                      const SizedBox(width: 2.5),
                      const _Block(height: 14, width: 33.5, radius: 10),
                      const SizedBox(width: 22),
                      Icon(
                        Icons.keyboard_arrow_up_rounded,
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                      ),
                    ],
                  ),
                ),
              ),
              for (var i = 0; i < rows; i++)
                Stack(
                  children: [
                    Container(
                      color: i == 0
                          ? scheme.surfaceContainerHighest.withValues(
                              alpha: 0.35,
                            )
                          : null,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(12, 12, 14, 12),
                        child: Row(
                          children: [
                            // Thumbnail
                            const _Block(height: 48, width: 82, radius: 6),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 5),
                                  // Title
                                  FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor:
                                        0.8 *
                                        (random.nextDouble() * 0.6 +
                                            0.4), // Randomize width a bit
                                    child: const _Block(height: 12),
                                  ),
                                  const SizedBox(height: 10),
                                  // Channel name
                                  FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor:
                                        0.3 *
                                        (random.nextDouble() * 0.6 +
                                            0.4), // Randomize width a bit
                                    child: const _Block(height: 9),
                                  ),
                                ],
                              ),
                            ),
                            // Handle
                            const SizedBox(width: 12),
                            Icon(
                              Icons.drag_handle_rounded,
                              color: scheme.surfaceContainerHighest,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (i == 0)
                      Positioned(
                        left: -0.5,
                        top: 0,
                        bottom: 0,
                        child: Icon(
                          Icons.play_arrow,
                          color: scheme.surfaceContainerHighest,
                          size: 12,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The related list: a heading, then wide rows — or a two-up grid when the
/// page has collapsed to one column, which is the shape the real one takes
/// there.
class _RelatedBlock extends StatelessWidget {
  const _RelatedBlock({this.asGrid = false});

  final bool asGrid;

  static const int count = 5;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 7),
        const _Block(height: 13, width: 70),
        const SizedBox(height: 12),
        if (asGrid)
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1.35,
            children: [
              for (var i = 0; i < count; i++) const _GridTile(),
            ],
          )
        else
          for (var i = 0; i < count; i++)
            const Padding(
              padding: EdgeInsets.only(bottom: 12, left: 8),
              child: _WideTile(),
            ),
      ],
    );
  }
}

class _WideTile extends StatelessWidget {
  const _WideTile();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: const _Block(height: 94, radius: 8)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Block(height: 13),
              const SizedBox(height: 6),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.75,
                child: const _Block(height: 13),
              ),
              const SizedBox(height: 10),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.5,
                child: const _Block(height: 11),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
      ],
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AspectRatio(
          aspectRatio: ScreenValues.normalAspectRatio,
          child: _Block(radius: 8),
        ),
        const SizedBox(height: 8),
        const _Block(height: 12),
        const SizedBox(height: 6),
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: 0.6,
          child: const _Block(height: 10),
        ),
      ],
    );
  }
}

/// A rounded rectangle, optionally with a fixed height and/or width. The radius defaults to 6.
class _Block extends StatelessWidget {
  const _Block({this.height, this.width, this.radius = 6, this.margin});

  final double? height;
  final double? width;
  final double radius;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: margin,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
