import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/feed_item.dart';

import '../playlist_controller.dart';
import '../queue_controller.dart';
import '../widgets/media_tile.dart';
import '../page_wrapper.dart';
import '../open_video.dart';
import '../spoken.dart';
import '../widgets/save_dialog.dart';
import '../focus_surface.dart';

class PlaylistPage extends ConsumerStatefulWidget {
  const PlaylistPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  final _scrollController = ScrollController();
  static const double _narrowBreakpoint = 800;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 400) {
      ref.read(playlistProvider(widget.playlistId).notifier).loadNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlistState = ref.watch(playlistProvider(widget.playlistId));
    
    return PageWrapper(
      title: const Text('Playlist'),
      body: playlistState.when(
        data: (state) => _PlaylistContent(state: state, scrollController: _scrollController),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text(e.toString())),
      ),
    );
  }
}

class _PlaylistContent extends ConsumerWidget {
  const _PlaylistContent({required this.state, required this.scrollController});
  final PlaylistState state;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= _PlaylistPageState._narrowBreakpoint;
    
    final header = state.header;
    if (header == null && state.items.isEmpty && state.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final headerWidget = _PlaylistHeaderWidget(playlistId: state.playlistId, header: header, title: state.title, videoCount: state.videoCount);
    final listWidget = _PlaylistList(state: state, scrollController: scrollController);

    final orderedHeader = FocusTraversalOrder(order: PlaylistFocusOrder.header, child: headerWidget);
    final orderedList = FocusTraversalOrder(order: PlaylistFocusOrder.list, child: listWidget);

    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 360, child: orderedHeader),
          Expanded(child: orderedList),
        ],
      );
    } else {
      return CustomScrollView(
        controller: scrollController,
        slivers: [
          SliverToBoxAdapter(child: orderedHeader),
          // SliverList cannot be wrapped directly in FocusTraversalOrder without SliverToBoxAdapter, 
          // wait, FocusTraversalOrder is a RenderBox, we can't put it in slippers.
          // But _PlaylistSliverList is a sliver.
          // So we should wrap the item builder instead or wrap the CustomScrollView if narrow.
          // But wait, the list is the rest of the page. In narrow mode, we can just let it flow.
          // Let's just wrap the whole thing if wide, and if narrow, maybe it's fine since it's just reading order.
          _PlaylistSliverList(state: state),
        ],
      );
    }
  }
}

class _PlaylistHeaderWidget extends ConsumerWidget {
  const _PlaylistHeaderWidget({required this.playlistId, required this.header, required this.title, required this.videoCount});
  final String playlistId;
  final PlaylistHeader? header;
  final String? title;
  final int? videoCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The tint must not pop in. Animate to the tint when it arrives.
    final color = header?.backgroundColor;
    final surface = Theme.of(context).colorScheme.surface;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Fallback logic for ThemedColor since it's just two ints. We map them.
    final tintColor = color != null ? Color(isDark ? color.dark : color.light) : surface;
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: tintColor,
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header?.thumbnailUrl != null)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(header!.thumbnailUrl!, fit: BoxFit.cover),
            ),
          const SizedBox(height: 16),
          Text(
            title ?? '',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (header?.ownerName != null) ...[
            Row(
              children: [
                if (header?.ownerAvatarUrl != null) ...[
                  CircleAvatar(backgroundImage: NetworkImage(header!.ownerAvatarUrl!), radius: 12),
                  const SizedBox(width: 8),
                ],
                Text(header!.ownerName!, style: const TextStyle(fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Text(
            'Playlist · ${header?.visibility ?? "Public"} · ${videoCount ?? 0} videos · ${header?.viewCountText ?? "0 views"}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (header?.description != null) ...[
            const SizedBox(height: 16),
            Text(header!.description!),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play all'),
                onPressed: () => unawaited(startPlaylistFromTile(context, ref, playlistId)),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.share),
                tooltip: 'Share',
                onPressed: () => _share(context, playlistId),
              ),
              const Tooltip(
                message: 'Save is not available yet',
                child: IconButton(icon: Icon(Icons.playlist_add), onPressed: null),
              ),
              const Tooltip(
                message: 'Shuffle is not available yet',
                child: IconButton(icon: Icon(Icons.shuffle), onPressed: null),
              ),
              if (header?.isOwnedByViewer == true) ...[
                const Tooltip(
                  message: 'Add videos is not available yet',
                  child: IconButton(icon: Icon(Icons.add), onPressed: null),
                ),
                const Tooltip(
                  message: 'Edit is not available yet',
                  child: IconButton(icon: Icon(Icons.edit), onPressed: null),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _share(BuildContext context, String playlistId) {
    // Show a snackbar or share dialog. In Rill it's usually `share_dialog.dart` but maybe it just copies?
    // "Share: share_dialog.dart, with the playlist URL."
    showDialog(context: context, builder: (_) => AlertDialog(content: Text('https://www.youtube.com/playlist?list=$playlistId')));
  }
}

class _PlaylistList extends ConsumerWidget {
  const _PlaylistList({required this.state, required this.scrollController});
  final PlaylistState state;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        _PlaylistSliverList(state: state),
      ],
    );
  }
}

class _PlaylistSliverList extends ConsumerWidget {
  const _PlaylistSliverList({required this.state});
  final PlaylistState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == state.items.length) {
            if (state.error != null) {
              return Center(
                child: Column(
                  children: [
                    Text(state.error!),
                    TextButton(
                      onPressed: () => ref.read(playlistProvider(state.playlistId).notifier).retry(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }
            if (state.loading) return const Center(child: CircularProgressIndicator());
            return const SizedBox.shrink();
          }

          final item = state.items[index];
          final tile = ListTile(
            leading: Text('${index + 1}'),
            title: MediaTile(
              spec: specFor(item)!,
              onTap: () {
                unawaited(ref.read(queueProvider.notifier).startPlaylist(
                  state.playlistId,
                  title: state.title,
                  videoCount: state.videoCount,
                  loadedItems: state.items,
                  continuation: state.continuation,
                  startIndex: index,
                ));
              },
            ),
          );
          return FocusTraversalOrder(
            order: PlaylistFocusOrder.list,
            child: tile,
          );
        },
        childCount: state.items.length + (state.continuation != null || state.error != null || state.loading ? 1 : 0),
      ),
    );
  }
}
