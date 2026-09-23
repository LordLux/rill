import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/feed_item.dart';
import '../../domain/video_detail.dart';
import '../../theme/tokens.dart';
import '../playback_controller.dart';
import '../queue_controller.dart';
import '../video_info.dart';
import '../widgets/queue_panel.dart';
import '../pages/watch_layout.dart' show computeWatchGeometry;
import '../../theme/screen_values.dart';
import 'controls.dart' show playerPreviousKey, playerNextKey, playerPlayPauseKey, playerControlsVisibleProvider;

class AudioModeView extends ConsumerWidget {
  const AudioModeView({super.key, this.visualBuilder, this.showQueue = false});

  final WidgetBuilder? visualBuilder;
  final bool showQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);
    final item = playback.item;
    if (item == null) return const SizedBox.shrink();

    final detail = ref.watch(videoInfoProvider(item.id)).value;

    final music = detail?.music.firstOrNull;
    final coverUrl = music?.coverUrl ?? playback.source?.posterUrl ?? item.thumbnailUrl;

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

    Widget cover = Container(
      constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 1200),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
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
          child: coverUrl.isNotEmpty
              ? Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => ColoredBox(color: tokens.scrim),
                )
              : ColoredBox(color: tokens.scrim),
        ),
      ),
    );

    Widget musicContent = LayoutBuilder(
      builder: (context, constraints) {
        const double maxHeight = 400;
        final double bottomPadding = constraints.maxHeight < maxHeight ? max(48, 48 - (maxHeight - constraints.maxHeight) * 3.0) : 48;
        // final double bottomPadding = 48;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Padding(
                padding: EdgeInsets.only(left: 48, right: 48, top: bottomPadding, bottom: 32),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (visualBuilder != null) Positioned.fill(child: Builder(builder: visualBuilder!)),
                    cover,
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: tokens.onScrim,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    [artist, album].whereType<String>().where((s) => s.isNotEmpty).join(' • '),
                    style: TextStyle(
                      fontSize: 16,
                      color: tokens.onScrim.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            _TransportRow(item: item, detail: detail),
            const SizedBox(height: 48),
            AnimatedContainer(
              duration: ref.watch(playerControlsVisibleProvider) ? const Duration(milliseconds: 150) : const Duration(milliseconds: 400),
              curve: ref.watch(playerControlsVisibleProvider) ? Curves.easeOut : Curves.easeIn,
              height: ref.watch(playerControlsVisibleProvider) ? 50.0 : 0.0,
            ),
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

        // Fullscreen desktop layout with queue panel on the right
        return Row(
          children: [
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: Center(child: musicContent),
              ),
            ),
            Builder(
              builder: (context) {
                // **The panel caps its own list at `maxHeight`, defaulting to
                // 400.** Left unset it drew four rows and a void down the rest
                // of a fullscreen rail, which is what it looked like.
                //
                // The bottom inset clears the control bar: the rail runs the
                // full height and the bar is drawn over it, so without this the
                // last row sits underneath and cannot be clicked. The music
                // column reserves the same strip the same way.
                const top = 24.0;
                final bottom =
                    ref.watch(playerControlsVisibleProvider) ? 74.0 : 24.0;
                return Padding(
                  padding: EdgeInsets.only(top: top, bottom: bottom),
                  child: SizedBox(
                    width: geometry.railWidth,
                    child: EmbeddedQueuePanel(
                      maxHeight: max(0.0, constraints.maxHeight - top - bottom),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _TransportRow extends ConsumerWidget {
  const _TransportRow({required this.item, required this.detail});

  final VideoItem item;
  final VideoDetail? detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).tokens;
    final engine = ref.watch(playbackEngineProvider);
    final queue = ref.watch(queueProvider);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          //   _RatingButton(
          //     icon: rating == VideoRating.like ? Icons.thumb_up : Icons.thumb_up_outlined,
          //     label: cannotRate ?? (rating == VideoRating.like ? 'Remove like' : 'Like'),
          //     disabled: cannotRate != null,
          //     onTap: () => _setRating(ref, VideoRating.like),
          //   ),
          //   const SizedBox(width: 24),
          IconButton(
            key: playerPreviousKey,
            icon: const Icon(Icons.skip_previous),
            iconSize: 36,
            color: queue.hasPrevious ? tokens.onScrim : tokens.onScrim.withValues(alpha: 0.3),
            onPressed: queue.hasPrevious ? () => ref.read(playbackProvider.notifier).previous() : null,
          ),
          const SizedBox(width: 16),

          StreamBuilder<bool>(
            stream: engine.playingStream,
            initialData: engine.playing,
            builder: (context, snapshot) {
              final playing = snapshot.data ?? false;
              return IconButton(
                key: playerPlayPauseKey,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                iconSize: 64,
                color: tokens.onScrim,
                onPressed: () => ref.read(playbackProvider.notifier).togglePlayPause(),
              );
            },
          ),
          const SizedBox(width: 16),

          IconButton(
            key: playerNextKey,
            icon: const Icon(Icons.skip_next),
            iconSize: 36,
            color: queue.hasNext ? tokens.onScrim : tokens.onScrim.withValues(alpha: 0.3),
            onPressed: queue.hasNext ? () => ref.read(playbackProvider.notifier).next() : null,
          ),
          // const SizedBox(width: 24),

          // _RatingButton(
          //   icon: rating == VideoRating.dislike ? Icons.thumb_down : Icons.thumb_down_outlined,
          //   label: cannotRate ?? (rating == VideoRating.dislike ? 'Remove dislike' : 'Dislike'),
          //   disabled: cannotRate != null,
          //   onTap: () => _setRating(ref, VideoRating.dislike),
          // ),
        ],
      ),
    );
  }

}
