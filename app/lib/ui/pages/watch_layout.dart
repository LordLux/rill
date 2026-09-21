import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';
import '../../theme/screen_values.dart';

const double referenceAspect = ScreenValues.normalAspectRatio;

class WatchLayoutGeometry {
  const WatchLayoutGeometry({
    required this.availableWidth,
    required this.playerWidth,
    required this.playerHeight,
    required this.theatreWidth,
    required this.theatreHeight,
    required this.mainContainerWidth,
    required this.railWidth,
    required this.isDesktop,
    required this.theatre,
    required this.aspectRatio,
  });

  final double availableWidth;
  final double playerWidth;
  final double playerHeight;
  final double theatreWidth;
  final double theatreHeight;
  final double mainContainerWidth;
  final double railWidth;
  final bool isDesktop;
  final bool theatre;
  final double aspectRatio;

  bool get isTwoColumn => isDesktop;
}

WatchLayoutGeometry computeWatchGeometry({
  required double availableWidth,
  required double viewportHeight,
  required double aspectRatio,
  required bool theatre,
}) {
  double railWidth = 0;
  double mainContainerWidth = availableWidth;
  final isDesktop = availableWidth >= 889;

  final double maxTheaterWidth = 1280.0 + 483.0 + 24.0 * 3;
  if (isDesktop) {
    final maxAllowedWidth = theatre ? maxTheaterWidth : 1950.0;
    final effectiveWidth = math.min(availableWidth, maxAllowedWidth);
    if (effectiveWidth >= 1042.0) {
      railWidth = 483.0;
    } else {
      railWidth = math.max(300.0, effectiveWidth - 559.0);
    }
    mainContainerWidth = effectiveWidth - railWidth;
  }

  final maxPlayerHeight = math.max(480.0, viewportHeight - 169.0);
  final normalPlayerWidth = mainContainerWidth - 16;
  final heightBound = aspectRatio < referenceAspect;

  final double playerWidth;
  final double playerHeight;
  if (heightBound) {
    final tallest = math.min(maxPlayerHeight, math.max(480.0, viewportHeight - 169.0));
    final widest = tallest * aspectRatio;
    if (widest <= normalPlayerWidth) {
      playerHeight = tallest;
      playerWidth = widest;
    } else {
      playerWidth = normalPlayerWidth;
      playerHeight = playerWidth / aspectRatio;
    }
  } else {
    playerWidth = normalPlayerWidth;
    playerHeight = playerWidth / aspectRatio;
  }

  double theatreWidth = availableWidth;
  double theatreHeight = theatreWidth / aspectRatio;
  if (theatreHeight > maxPlayerHeight) {
    theatreHeight = maxPlayerHeight;
    theatreWidth = theatreHeight * aspectRatio;
  }

  return WatchLayoutGeometry(
    availableWidth: availableWidth,
    playerWidth: playerWidth,
    playerHeight: playerHeight,
    theatreWidth: theatreWidth,
    theatreHeight: theatreHeight,
    mainContainerWidth: mainContainerWidth,
    railWidth: railWidth,
    isDesktop: isDesktop,
    theatre: theatre,
    aspectRatio: aspectRatio,
  );
}

class WatchLayout extends StatelessWidget {
  const WatchLayout({
    super.key,
    required this.geometry,
    required this.playerSlot,
    required this.metadataSlivers,
    this.railSlivers = const [],
    this.theatreBackground,
    this.scrollable = true,
  });

  final WatchLayoutGeometry geometry;
  final Widget playerSlot;
  final List<Widget> metadataSlivers;
  final List<Widget> railSlivers;
  final Color? theatreBackground;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final g = geometry;

    final playerWidget = Center(
      child: SizedBox(
        height: g.playerHeight,
        width: g.playerWidth,
        child: playerSlot,
      ),
    );

    final Widget? theatrePlayer = g.theatre
        ? Container(
            color: theatreBackground,
            alignment: Alignment.center,
            height: g.theatreHeight,
            child: SizedBox(
              height: g.theatreHeight,
              width: g.theatreWidth,
              child: playerSlot,
            ),
          )
        : null;

    final Widget? normalPlayer = !g.theatre
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 4, 0),
            child: playerWidget,
          )
        : null;

    final slivers = <Widget>[];

    if (theatrePlayer != null) {
      slivers.add(SliverToBoxAdapter(
        key: const ValueKey('watch-layout/theatrePlayer'),
        child: theatrePlayer,
      ));
    }

    if (g.isTwoColumn) {
      final double totalContentWidth = g.mainContainerWidth + g.railWidth;
      final double horizontalPadding = math.max(0, (g.availableWidth - totalContentWidth) / 2);

      slivers.add(
        SliverPadding(
          key: const ValueKey('watch-layout/main'),
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverCrossAxisGroup(
            slivers: [
              SliverConstrainedCrossAxis(
                maxExtent: g.mainContainerWidth,
                sliver: SliverMainAxisGroup(
                  slivers: [
                    if (normalPlayer != null) SliverToBoxAdapter(child: normalPlayer),
                    SliverMainAxisGroup(
                      key: const ValueKey('watch-layout/metadata'),
                      slivers: metadataSlivers,
                    ),
                  ],
                ),
              ),
              SliverConstrainedCrossAxis(
                maxExtent: g.railWidth,
                sliver: SliverMainAxisGroup(
                  key: const ValueKey('watch-layout/rail'),
                  slivers: railSlivers,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      // Mobile / single column layout
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.only(right: 8),
          sliver: SliverMainAxisGroup(
            key: const ValueKey('watch-layout/main'),
            slivers: [
              if (normalPlayer != null) SliverToBoxAdapter(child: normalPlayer),
              SliverMainAxisGroup(
                key: const ValueKey('watch-layout/metadata'),
                slivers: metadataSlivers,
              ),
            ],
          ),
        ),
      );
    }

    return SilkyCustomScrollView(
      key: const PageStorageKey<String>('watch_page_scroll'),
      physics: scrollable ? const AlwaysScrollableScrollPhysics() : const NeverScrollableScrollPhysics(),
      shrinkWrap: !scrollable,
      slivers: slivers,
    );
  }
}
