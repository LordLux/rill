import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Where the two sizing rules meet — architecture §2.8
const double referenceAspect = 16 / 9;

/// The geometry a [WatchLayout] computed for the current frame.
///
/// Exposed so that the caller who built the layout can also read the player
/// rectangle (for example, to size a subtitle overlay to the player slot
/// without re-doing the arithmetic).
class WatchLayoutGeometry {
  const WatchLayoutGeometry({
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

/// Pure function that computes the watch page player & column geometry.
///
/// Pulled out of `WatchPage.build` so that both the real watch page and the
/// libass ghost overlay can share the exact same numbers without duplicating
/// the arithmetic.
WatchLayoutGeometry computeWatchGeometry({
  required double availableWidth,
  required double viewportHeight,
  required double aspectRatio,
  required bool theatre,
}) {
  double railWidth = 0;
  double mainContainerWidth = availableWidth;
  final isDesktop = availableWidth >= 889;

  final double maxTheaterWidth = 1280.0 + 453.0 + 24.0 * 3;
  if (isDesktop) {
    final maxAllowedWidth = theatre ? maxTheaterWidth : 1950.0;
    final effectiveWidth = math.min(availableWidth, maxAllowedWidth);
    if (effectiveWidth >= 1042.0) {
      railWidth = 453.0;
    } else {
      railWidth = math.max(300.0, effectiveWidth - 589.0);
    }
    mainContainerWidth = effectiveWidth - railWidth;
  }

  final maxPlayerHeight = math.max(480.0, viewportHeight - 169.0);
  final normalPlayerWidth = mainContainerWidth - 32;
  final heightBound = aspectRatio < referenceAspect;

  final double playerWidth;
  final double playerHeight;
  if (heightBound) {
    final tallest =
        math.min(maxPlayerHeight, math.max(480.0, viewportHeight - 169.0));
    final widest = tallest * aspectRatio;
    if (widest <= normalPlayerWidth) {
      playerHeight = tallest;
      playerWidth = widest;
    } else {
      playerWidth = normalPlayerWidth;
      playerHeight = normalPlayerWidth / aspectRatio;
    }
  } else {
    playerWidth = normalPlayerWidth;
    playerHeight = normalPlayerWidth / aspectRatio;
  }

  double theatreWidth = availableWidth;
  double theatreHeight = theatreWidth / aspectRatio;
  if (theatreHeight > maxPlayerHeight) {
    theatreHeight = maxPlayerHeight;
    theatreWidth = theatreHeight * aspectRatio;
  }

  return WatchLayoutGeometry(
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

/// Produces the same visual structure as the watch page but with pluggable
/// children.
///
/// The watch page passes real widgets for [playerSlot], [metadataSlot] and
/// [railSlot]. The libass overlay in `PlayerShell` passes [LibassLayer] for
/// [playerSlot] and empty [SizedBox.shrink] widgets for the rest — getting
/// a pixel-identical player rectangle without duplicating any layout code.
///
/// The widget is deliberately **not** a scrollable: the caller wraps it in
/// whatever scroll view (or none) it needs. It only builds the sized structure
/// for a single "page-worth" of content.
class WatchLayout extends StatelessWidget {
  const WatchLayout({
    super.key,
    required this.geometry,
    required this.playerSlot,
    required this.metadataSlot,
    this.railSlot = const SizedBox.shrink(),
    this.theatreBackground,
    this.scrollable = true,
    this.scrollView,
  });

  /// Pre-computed geometry — use [computeWatchGeometry].
  final WatchLayoutGeometry geometry;

  /// The widget placed where the video player goes.
  final Widget playerSlot;

  /// The widget placed below the player (title, description, actions, etc.).
  final Widget metadataSlot;

  /// The widget placed in the right rail (related videos / queue).
  final Widget railSlot;

  /// Optional background for theatre mode (the dark scrim behind the player).
  /// When null, no background is drawn.
  final Color? theatreBackground;

  /// Whether this layout instance is wrapped in a scroll view.
  /// When false (e.g. the ghost overlay), the content is laid out in a
  /// non-scrollable [Column] so it mirrors the scroll-position-zero state.
  final bool scrollable;

  /// If non-null, the caller provides its own scroll view builder, receiving
  /// the list of children to place. When null and [scrollable] is true, a
  /// simple [ListView] is used.
  final Widget Function(List<Widget> children)? scrollView;

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

    final metadataColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!g.theatre)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
            child: playerWidget,
          ),
        metadataSlot,
      ],
    );

    final Widget mainContent;
    if (g.isTwoColumn) {
      mainContent = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: g.mainContainerWidth, child: metadataColumn),
          SizedBox(width: g.railWidth, child: railSlot),
        ],
      );
    } else {
      mainContent = metadataColumn;
    }

    final theatrePlayer = g.theatre
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

    final children = <Widget>[
      ?theatrePlayer,
      mainContent,
    ];

    if (!scrollable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    if (scrollView != null) return scrollView!(children);

    return ListView(
      padding: EdgeInsets.zero,
      children: children,
    );
  }
}
