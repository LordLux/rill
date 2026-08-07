import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/playback/engine.dart';
import '../../data/rpc/client.dart';
// `Chip` here is Material's. The domain's `Chip` is the feed's filter strip and
// has no business on this page — hidden rather than aliased so a later edit that
// reaches for one gets an error instead of the wrong class.
import '../../domain/feed_item.dart' hide Chip;
import '../../domain/video_detail.dart';
import '../../theme/tokens.dart';
import '../open_video.dart';
import '../page_wrapper.dart';
import '../playback_controller.dart';
import '../queue_controller.dart';
import '../video_info.dart';
import '../widgets/media_tile.dart';
import '../widgets/queue_panel.dart';

/// The watch page (task §3).
///
/// It renders **whatever the queue is pointing at**, rather than a video handed
/// to it as a constructor argument. That is what makes "tapping a related tile
/// replaces the current video without pushing a second watch route" fall out for
/// free: the tap moves the queue's cursor, the cursor is what this page watches,
/// and the route never changes.
class WatchPage extends ConsumerStatefulWidget {
  const WatchPage({super.key});

  @override
  ConsumerState<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends ConsumerState<WatchPage> {
  bool _descriptionExpanded = false;

  /// Related pages fetched beyond the one `video.info` already returned.
  final List<FeedItem> _extraRelated = [];
  String? _relatedContinuation;
  bool _loadingRelated = false;
  String? _loadedRelatedFor;

  @override
  Widget build(BuildContext context) {
    // A related tap swaps the video under this page without a route change, so
    // the rail's own paging state has to be reset by the video changing rather
    // than by the page being built.
    ref.listen(queueProvider.select((q) => q.current?.id), (previous, next) {
      if (previous == next || next == null) return;
      setState(() {
        _loadedRelatedFor = next;
        _extraRelated.clear();
        _relatedContinuation = null;
        _descriptionExpanded = false;
        _loadingRelated = false;
      });
    });

    final playback = ref.watch(playbackProvider);
    final item = ref.watch(queueProvider.select((q) => q.current)) ?? playback.item;

    if (item == null) {
      return const PageWrapper(title: Text('Watch'), body: Center(child: Text('Nothing playing.')));
    }

    _loadedRelatedFor ??= item.id;
    final info = ref.watch(videoInfoProvider(item.id));

    return PageWrapper(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BackButton(onPressed: () => Navigator.of(context).maybePop()),
          Text(
            'Watch',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Queue',
          mouseCursor: SystemMouseCursors.click,
          icon: const Icon(Icons.queue_music),
          onPressed: () => showQueuePanel(context),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 1100;
          final detail = info.value;

          final main = ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _PlayerSurface(playback: playback),
              const SizedBox(height: 12),
              _Meta(item: item, info: info),
              const SizedBox(height: 12),
              _Actions(item: item),
              const SizedBox(height: 16),
              if (detail != null)
                _Description(
                  detail: detail,
                  expanded: _descriptionExpanded,
                  onToggle: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
                ),
              if (!wide) ...[
                const SizedBox(height: 24),
                ..._relatedSection(detail, item.id),
              ],
            ],
          );

          if (!wide) return main;

          // A third of the width, capped. A fixed 400 overflows the row on any
          // window narrow enough to still count as wide — measured at 1500 px,
          // where the rail ran off the right edge and the tiles were cut in half.
          final railWidth = math.min(400.0, constraints.maxWidth / 3);

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: main),
              SizedBox(
                key: const ValueKey('related-rail'),
                width: railWidth,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(0, 8, 16, 32),
                  children: _relatedSection(detail, item.id),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _relatedSection(VideoDetail? detail, String videoId) {
    final scheme = Theme.of(context).colorScheme;
    if (detail == null) return const [];

    final items = [...detail.related, ..._extraRelated];
    final continuation = _relatedContinuation ?? detail.relatedContinuation;

    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Related',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: scheme.onSurface),
        ),
      ),
      for (final related in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _relatedTile(related),
        ),
      if (continuation != null)
        Center(
          child: TextButton(
            onPressed: _loadingRelated ? null : () => _loadMoreRelated(videoId, continuation),
            child: Text(_loadingRelated ? 'Loading…' : 'Show more'),
          ),
        ),
    ];
  }

  Widget _relatedTile(FeedItem related) {
    final spec = specFor(related);
    if (spec == null) return const SizedBox.shrink();
    return MediaTile(
      spec: spec,
      // No route push: this replaces the video on the page it is already on.
      onTap: () => openFromTile(ref, related),
      onAddToQueue: () => queueFromTile(ref, related),
      onWatchLater: () => _addToWatchLater(watchTargetFor(related)?.id),
    );
  }

  Future<void> _loadMoreRelated(String videoId, String continuation) async {
    setState(() => _loadingRelated = true);
    try {
      final page = await fetchRelated(videoId, continuation: continuation);
      if (!mounted) return;
      setState(() {
        _extraRelated.addAll(page.items);
        _relatedContinuation = page.continuation;
      });
    } on Object catch (e) {
      if (!mounted) return;
      _toast('Could not load more: $e');
    } finally {
      if (mounted) setState(() => _loadingRelated = false);
    }
  }

  Future<void> _addToWatchLater(String? videoId) async {
    if (videoId == null) return;
    try {
      await RpcClient.instance.call('action.addToWatchLater', {'videoId': videoId});
      _toast('Saved to Watch Later');
    } on RpcException catch (e) {
      _toast(e.code == 'AUTH_REQUIRED' ? 'Sign in to save to Watch Later' : e.message);
    } on Object catch (e) {
      _toast('$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The video, or whatever is standing in for it.
///
/// The surface belongs to the shell's engine — the player is not created here,
/// it is rendered here, and the same texture renders in the mini-player once
/// this route is popped. On a fake engine (tests) the surface is a placeholder,
/// which is the point of the engine being an interface.
class _PlayerSurface extends ConsumerWidget {
  const _PlayerSurface({required this.playback});

  final PlaybackState playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final engine = ref.read(playbackEngineProvider);

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: theme.tokens.scrim,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The shell's surface, mounted here. Popping back to the feed
              // moves this same texture into the mini-player — nothing is
              // created or freed by the move.
              engine.videoSurface(),
              if (playback.isLoading)
                Center(child: CircularProgressIndicator(color: scheme.onPrimary)),
              if (playback.error != null) _Unavailable(playback: playback),
              if (playback.error == null && !playback.isLoading)
                Positioned(left: 0, right: 0, bottom: 0, child: _TransportBar(engine: engine)),
            ],
          ),
        ),
      ),
    );
  }
}

/// `STREAM_UNAVAILABLE` and friends (§4).
///
/// A retry affordance rather than a verdict: every rung of the ladder can
/// decline for a video that is perfectly fine (F9, observed 2026-08-02), which
/// is exactly why the protocol makes this `retry: "user"` and not `no`. On a
/// `no` — a login, a cookie, a policy — the button is not drawn, because a
/// button that cannot work is worse than no button.
class _Unavailable extends ConsumerWidget {
  const _Unavailable({required this.playback});

  final PlaybackState playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ColoredBox(
      color: theme.tokens.scrim.withValues(alpha: 0.85),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: scheme.error, size: 40),
              const SizedBox(height: 12),
              Text(
                'This video would not open.',
                style: TextStyle(color: theme.tokens.onScrim, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                playback.error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.tokens.onScrim.withValues(alpha: 0.7), fontSize: 12),
              ),
              if (playback.canRetry) ...[
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.read(playbackProvider.notifier).retry(),
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Play/pause, a scrubber and a clock.
///
/// Every value here comes off `player.stream.*` (hard invariant 9). A
/// `getProperty` poll on this path is a blocking FFI call that can sit on mpv's
/// core lock through a seek — F15 recorded a 6.4 s freeze doing it.
class _TransportBar extends ConsumerStatefulWidget {
  const _TransportBar({required this.engine});

  final PlaybackEngine engine;

  @override
  ConsumerState<_TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends ConsumerState<_TransportBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.tokens;

    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.scrim.withValues(alpha: 0.55)),
      child: StreamBuilder<Duration>(
        stream: widget.engine.positionStream,
        initialData: widget.engine.position,
        builder: (context, snapshot) {
          final duration = widget.engine.duration;
          final position = snapshot.data ?? Duration.zero;
          final max = math.max(duration.inMilliseconds.toDouble(), 1.0);
          final value = (_dragging ?? position.inMilliseconds.toDouble()).clamp(0.0, max);

          return Row(
            children: [
              StreamBuilder<bool>(
                stream: widget.engine.playingStream,
                initialData: widget.engine.playing,
                builder: (context, playing) => IconButton(
                  mouseCursor: SystemMouseCursors.click,
                  icon: Icon(
                    (playing.data ?? false) ? Icons.pause : Icons.play_arrow,
                    color: tokens.onScrim,
                  ),
                  onPressed: () => ref.read(playbackProvider.notifier).togglePlayPause(),
                ),
              ),
              Expanded(
                child: Slider(
                  value: value,
                  max: max,
                  onChanged: (next) => setState(() => _dragging = next),
                  onChangeEnd: (next) {
                    setState(() => _dragging = null);
                    ref
                        .read(playbackProvider.notifier)
                        .seek(Duration(milliseconds: next.round()));
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '${_clock(position)} / ${_clock(duration)}',
                  style: TextStyle(color: tokens.onScrim, fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _clock(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(hours > 0 ? 2 : 1, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

/// Title, channel and counts. Falls back to what the tile already knew while
/// `video.info` is in flight, so opening a video never shows an empty header.
class _Meta extends ConsumerWidget {
  const _Meta({required this.item, required this.info});

  final VideoItem item;
  final AsyncValue<VideoDetail> info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final detail = info.value;

    final title = detail?.title ?? item.title;
    final channel = detail?.channelName ?? item.channelName;
    final avatar = detail?.channelAvatarUrl ?? item.channelAvatarUrl;
    final meta = detail?.metaLine ?? item.viewCountText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: scheme.onSurface),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundImage: avatar == null ? null : NetworkImage(avatar),
              onBackgroundImageError: avatar == null ? null : (_, _) {},
              child: avatar == null ? const Icon(Icons.person, size: 20) : null,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  channel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                if (detail?.subscriberText != null)
                  Text(
                    detail!.subscriberText!,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
            const Spacer(),
            if (detail?.likeText != null)
              Row(
                children: [
                  Icon(Icons.thumb_up_outlined, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    detail!.likeText!,
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
          ],
        ),
        if (meta != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(meta, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ),
        if (info.hasError)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _InfoError(videoId: item.id, error: info.error!),
          ),
      ],
    );
  }
}

/// `video.info` failed. The video may still be playing, so this is a strip
/// rather than a page — losing the description is not losing the video.
class _InfoError extends ConsumerWidget {
  const _InfoError({required this.videoId, required this.error});

  final String videoId;
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final retryable = error is! RpcException || (error as RpcException).retry != RpcRetryMode.no;

    return Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: scheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Could not load the video details: $error',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        if (retryable)
          TextButton(
            onPressed: () => ref.invalidate(videoInfoProvider(videoId)),
            child: const Text('Retry'),
          ),
      ],
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.item});

  final VideoItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => _watchLater(context),
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Watch later'),
        ),
        OutlinedButton.icon(
          onPressed: () => ref.read(queueProvider.notifier).addToQueue(item),
          icon: const Icon(Icons.playlist_add, size: 18),
          label: const Text('Add to queue'),
        ),
        OutlinedButton.icon(
          onPressed: () => ref.read(queueProvider.notifier).playNext(item),
          icon: const Icon(Icons.playlist_play, size: 18),
          label: const Text('Play next'),
        ),
        if (playback.source?.qualityDegraded ?? false)
          Chip(
            avatar: const Icon(Icons.hd_outlined, size: 16),
            label: Text('Reduced quality (${playback.source!.best?.height ?? '?'}p)'),
          ),
        // Load-bearing, so its failure is visible rather than inferred from a
        // homepage that slowly stops resembling the real one.
        if (playback.reportError != null)
          Chip(
            avatar: const Icon(Icons.history_toggle_off, size: 16),
            label: const Text('Not recording to history'),
          ),
      ],
    );
  }

  Future<void> _watchLater(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RpcClient.instance.call('action.addToWatchLater', {'videoId': item.id});
      messenger.showSnackBar(const SnackBar(content: Text('Saved to Watch Later')));
    } on RpcException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to save to Watch Later' : e.message),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _Description extends StatelessWidget {
  const _Description({required this.detail, required this.expanded, required this.onToggle});

  final VideoDetail detail;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = detail.description;
    if (description == null || description.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            description,
            maxLines: expanded ? null : 3,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: scheme.onSurface, height: 1.4),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onToggle,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                expanded ? 'Show less' : 'Show more',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
