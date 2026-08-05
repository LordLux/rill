import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../page_wrapper.dart';
import '../debug_player.dart';
import '../feed_controller.dart';
import '../../domain/feed_item.dart';

class FeedPage extends ConsumerStatefulWidget {
  const FeedPage({super.key});

  @override
  ConsumerState<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends ConsumerState<FeedPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A filter change starts at the top, said out loud.
    //
    // It already happens by accident: clearing `items` swaps the grid for the
    // spinner, and disposing the grid takes its scroll position with it. That
    // is not a decision anyone made, and the obvious future improvement —
    // keeping the previous results visible while the next filter loads — would
    // silently bring back landing halfway down someone else's list.
    //
    // Post-frame because the grid may not be mounted at the instant the token
    // changes; when it is (results kept visible), this is the whole mechanism.
    ref.listen(feedProvider.select((s) => s.selectedToken), (previous, next) {
      if (previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    });

    final state = ref.watch(feedProvider);

    return PageWrapper(
      title: const Text('Rill'),
      actions: [
        IconButton(
          icon: const Icon(Icons.bug_report),
          tooltip: 'Debug Player',
          onPressed: () async {
            final config = HarnessConfig.fromEnvironment();
            final source = await StreamSource.load(config);
            if (context.mounted) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => HarnessPage(config: config, source: source),
                ),
              );
            }
          },
        ),
      ],
      body: Padding(
        padding: EdgeInsets.only(left: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.chips.isNotEmpty)
              SizedBox(
                height: 36,
                child: SilkyListView.builder(
                  padding: EdgeInsets.only(top: 1),
                  scrollDirection: Axis.horizontal,
                  itemCount: state.chips.length,
                  itemBuilder: (context, index) {
                    final chip = state.chips[index];
                    final isSelected = state.selectedChip?.token == chip.token;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: FilterChip(
                        label: Text(chip.label),
                        selected: isSelected,
                        showCheckmark: false,
                        onSelected: (_) {
                          ref.read(feedProvider.notifier).selectChip(chip);
                        },
                      ),
                    );
                  },
                ),
              ),

            Expanded(child: _buildBody(context, state, ref)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, FeedState state, WidgetRef ref) {
    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                'Error loading feed:\n${state.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.read(feedProvider.notifier).loadHome(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.isAuthDegraded && state.items.isEmpty) return const Center(child: Text('Authentication Degraded. Please sign in again.'));

    if (state.isAnonymous && state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_circle_outlined, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            const Text('You are browsing anonymously.', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Log in to see your personalized home feed.', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Login flow not implemented yet')));
              },
              icon: const Icon(Icons.login),
              label: const Text('Log In'),
            ),
          ],
        ),
      );
    }

    if (state.items.isEmpty && state.isLoading) return const Center(child: CircularProgressIndicator());

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        if (scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 400) ref.read(feedProvider.notifier).loadMore();
        return false;
      },
      child: SilkyGridView.builder(
        controller: _scroll,
        padding: EdgeInsets.only(right: 16.0, top: 8.0, bottom: 16.0),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 340,
          crossAxisSpacing: 16,
          mainAxisSpacing: 24,
          childAspectRatio: 0.85,
        ),
        itemCount: state.items.length + (state.isLoading && state.items.isNotEmpty ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == state.items.length) return const Center(child: CircularProgressIndicator());

          final feedItem = state.items[index];
          return feedItem.map(
            video: (v) => _VideoTile(video: v),
            mix: (m) => _MixTile(mix: m),
            playlist: (p) => _PlaylistTile(playlist: p),
            channel: (c) => _ChannelTile(channel: c),
            unknown: (_) => const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  final VideoItem video;
  const _VideoTile({required this.video});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              video.thumbnailUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[800], child: const Icon(Icons.image)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (video.channelAvatarUrl != null)
              CircleAvatar(
                radius: 18,
                backgroundImage: NetworkImage(video.channelAvatarUrl!),
                onBackgroundImageError: (error, stackTrace) {},
              )
            else
              const CircleAvatar(radius: 18, child: Icon(Icons.person, size: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.channelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (video.viewCountText != null || video.publishedText != null)
                    Text(
                      '${video.viewCountText ?? ''} ${video.publishedText ?? ''}'.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MixTile extends StatelessWidget {
  final MixItem mix;
  const _MixTile({required this.mix});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              mix.thumbnailUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[800], child: const Icon(Icons.queue_music)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          mix.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        if (mix.subtitle != null)
          Text(
            mix.subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
      ],
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final PlaylistItem playlist;
  const _PlaylistTile({required this.playlist});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              playlist.thumbnailUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[800], child: const Icon(Icons.playlist_play)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          playlist.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        if (playlist.channelName != null)
          Text(
            playlist.channelName!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
      ],
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final ChannelItem channel;
  const _ChannelTile({required this.channel});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: 48,
          backgroundImage: NetworkImage(channel.avatarUrl),
          onBackgroundImageError: (error, stackTrace) {},
          child: channel.avatarUrl.isEmpty ? const Icon(Icons.person, size: 48) : null,
        ),
        const SizedBox(height: 16),
        Text(
          channel.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        if (channel.subscriberText != null)
          Text(
            channel.subscriberText!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
      ],
    );
  }
}
