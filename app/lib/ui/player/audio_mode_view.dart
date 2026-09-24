import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/feed_item.dart';
import '../../theme/tokens.dart';
import '../playback_controller.dart';
import '../hide_queue_controller.dart';
import '../now_playing_art.dart';
import '../video_info.dart';
import '../widgets/queue_panel.dart';
import '../pages/watch_layout.dart' show computeWatchGeometry;
import '../../theme/screen_values.dart';

class AudioModeView extends ConsumerWidget {
  const AudioModeView({super.key, this.visualBuilder, this.showQueue = false});

  final WidgetBuilder? visualBuilder;
  final bool showQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);
    final item = playback.item;
    final hideQueue = ref.watch(hideQueueProvider);
    if (item == null) return const SizedBox.shrink();

    final detail = ref.watch(videoInfoProvider(item.id)).value;

    final music = detail?.music.firstOrNull;

    // The same resolver the media flyout reads: the song's cover, else the
    // video's own still — never YouTube's stock no-art square, which the
    // sidecar ships as a null cover (`parser/music.ts`).
    final art = ref.watch(nowPlayingArtProvider);
    final coverUrl = art?.url ?? '';
    // Framed as what it is: a cover square, a video still 16:9. A still in a
    // square frame sat letterboxed under the square's shadow, with an empty
    // band between it and the title.
    final artAspect = (art?.isCover ?? false) ? 1.0 : 16 / 9;

    // Fallback: title and channelName
    final title = music?.title ?? detail?.title ?? item.title;
    final artist =
        music?.artist ??
        detail?.channelName ??
        item.maybeMap(
          video: (v) => v.channelName,
          playlist: (p) => p.channelName,
          orElse: () => '',
        );
    final album = music?.album;

    final tokens = Theme.of(context).tokens;

    // Sized by the frame around it in `musicContent`, which animates its shape.
    Widget cover = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: tokens.scrim.withValues(alpha: 0.5),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        // Expanded, so the image fills the frame and `BoxFit.cover` crops it.
        // The default is a loose `Stack`, in which the image keeps its own
        // shape and the frame shows around it.
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, ?current],
        ),
        child: coverUrl.isNotEmpty
            ? Image.network(
                coverUrl,
                key: ValueKey(coverUrl),
                fit: BoxFit.cover,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    child: child,
                  );
                },
                errorBuilder: (context, error, stackTrace) => ColoredBox(
                  key: const ValueKey('error'),
                  color: tokens.scrim,
                ),
              )
            : ColoredBox(
                key: const ValueKey('empty'),
                color: tokens.scrim,
              ),
      ),
    );

    Widget musicContent = LayoutBuilder(
      builder: (context, constraints) {
        final double coverVerticalPadding = (constraints.maxHeight * 0.07).clamp(8.0, 48.0);
        final double bottomPadding = (constraints.maxHeight * 0.15).clamp(32.0, 120.0);
        final double textScale = (constraints.maxWidth / 1100).clamp(0.7, 1);

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 48,vertical: coverVerticalPadding),
                child: LayoutBuilder(
                  builder: (context, slot) {
                    // The square a cover fills. A still keeps that width and
                    // gives up height rather than growing wider — it is often
                    // a 480x360 thumbnail (F40) — so the title comes up to meet
                    // it, and the column stays centred as one group.
                    final side = min(min(slot.maxWidth, slot.maxHeight), 1200.0);
                    return TweenAnimationBuilder<double>(
                      tween: Tween(end: artAspect),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      builder: (context, aspect, child) => SizedBox(width: side, height: side / aspect, child: child),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (visualBuilder != null) Positioned.fill(child: Builder(builder: visualBuilder!)),
                          cover,
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 24 * textScale,
                        fontWeight: FontWeight.bold,
                        color: tokens.onScrim,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [artist, album].whereType<String>().where((s) => s.isNotEmpty).join(' • '), // TODO marquee if too long (maybe marquee: ^2.3.0 ?)
                      style: TextStyle(
                        fontSize: 16 * textScale,
                        color: tokens.onScrim.withValues(alpha: 0.7),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: bottomPadding),
          ],
        );
      },
    );

    if (!showQueue) return Center(child: musicContent);

    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = computeWatchGeometry(
          availableWidth: constraints.maxWidth,
          viewportHeight: constraints.maxHeight,
          aspectRatio: ScreenValues.normalAspectRatio,
          theatre: false,
        );

        final isDesktop = geometry.isDesktop;

        if (!isDesktop) return Center(child: musicContent);

        final border = Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
          width: 0.5,
        );
        final borderFinal = Border.merge(Border(right: BorderSide.none), border);

        // Fullscreen desktop layout with queue panel on the right
        return Stack(
          children: [
            Positioned.fill(child: Center(child: musicContent)),

            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              right: hideQueue ? -geometry.railWidth : 0,
              curve: Curves.easeInOutCubic,
              top: 0,
              bottom: 0,
              child: ConstrainedBox(
                constraints: BoxConstraints.tightFor(width: geometry.railWidth + 30),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOutCubic,
                      top: 0,
                      bottom: 0,
                      left: 0,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints.tightFor(height: 60),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            decoration: BoxDecoration(
                              border: borderFinal,
                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                            ),
                            width: hideQueue ? 30 : 30,
                            height: 60,
                            child: Material(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                              child: Tooltip(
                                message: hideQueue ? 'Show queue' : 'Hide queue',
                                child: InkWell(
                                  mouseCursor: SystemMouseCursors.click,
                                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                                  onTap: () => ref.read(hideQueueProvider.notifier).toggle(),
                                  child: Icon(
                                    hideQueue ? Icons.chevron_left : Icons.chevron_right,
                                    color: Theme.of(context).tokens.onScrim.withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      child: Builder(
                        builder: (context) {
                          // **The panel caps its own list at `maxHeight`, defaulting to
                          // 400.** Left unset it drew four rows and a void down the rest
                          // of a fullscreen rail, which is what it looked like.
                          //
                          // The bottom inset clears the control bar: the rail runs the
                          // full height and the bar is drawn over it, so without this the
                          // last row sits underneath and cannot be clicked. The music
                          // column reserves the same strip the same way.
                          const top = 54.0;
                          const bottom = 54.0;
                          return Padding(
                            padding: const EdgeInsets.only(top: top, bottom: bottom),
                            child: SizedBox(
                              width: geometry.railWidth,
                              child: EmbeddedQueuePanel(
                                maxHeight: max(
                                  0.0,
                                  constraints.maxHeight - top - bottom - 21,
                                ),
                                borderRadius: BorderRadius.horizontal(
                                  left: Radius.circular(12),
                                ),
                                onCollapse: () => ref.read(hideQueueProvider.notifier).setMode(true),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
