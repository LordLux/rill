import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../page_wrapper.dart';
import '../debug_player.dart';
import '../feed_controller.dart';
import '../widgets/accent_debug_button.dart';
import '../widgets/media_tile.dart';
import '../../data/rpc/client.dart';
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
      title: Text(
        'Rill',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 23,
        ),
      ),
      actions: [
        const AccentDebugButton(),
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.chips.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: 8.0, left: 8.0),
              child: SizedBox(
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
            ),
      
          Expanded(child: _buildBody(context, state, ref)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, FeedState state, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: scheme.error, size: 48),
              const SizedBox(height: 16),
              Text(
                'Error loading feed:\n${state.error}',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error),
              ),
              // No retry button on a `no`: protocol.md §4 says retrying changes
              // nothing there until a login or a policy changes first, and a
              // button that cannot work is worse than no button.
              if (state.errorRetry != RpcRetryMode.no) ...[
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.read(feedProvider.notifier).loadHome(),
                  child: const Text('Retry'),
                ),
              ],
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
            Icon(Icons.account_circle_outlined, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('You are browsing anonymously.', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Log in to see your personalized home feed.', style: TextStyle(color: scheme.onSurfaceVariant)),
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          const double maxExtent = 430.0;
          const double spacing = 32.0;
          const double hSpacing = 16.0;

          int crossAxisCount = ((constraints.maxWidth + hSpacing) / (maxExtent + hSpacing)).ceil();
          crossAxisCount = math.max(1, crossAxisCount);

          // A footer row under a populated grid: the spinner while the next page
          // loads, or the failure that stopped it. It gets its own full-width
          // row rather than the next free cell, because an error plus a retry
          // button does not fit in a tile-sized slot — and a failed page the
          // user cannot see is how the retry storm stayed invisible.
          final bool hasFooter =
              state.items.isNotEmpty && (state.isLoading || state.error != null);
          final int gridRows = (state.items.length / crossAxisCount).ceil();
          final int rowCount = gridRows + (hasFooter ? 1 : 0);

          return Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            interactive: true,
            child: Padding(
              padding: EdgeInsets.only(right: 13.0),
              child: ClipRRect(
                borderRadius: BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10)),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false), // hide original scrollbar
                    child: SilkyListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 16.0, top: 8.0, left: 8.0, right: 8.0),
                    itemCount: rowCount,
                    itemBuilder: (context, rowIndex) {
                      final bool isFooter = hasFooter && rowIndex == rowCount - 1;
                      return Padding(
                        padding: EdgeInsets.only(bottom: rowIndex < rowCount - 1 ? spacing : 0),
                        child: isFooter
                            ? _FeedFooter(state: state)
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: hSpacing,
                                children: List.generate(crossAxisCount, (colIndex) {
                                  final int itemIndex = rowIndex * crossAxisCount + colIndex;
                                  // Handles empty spaces in the final row
                                  if (itemIndex >= state.items.length) return const Expanded(child: SizedBox.shrink());

                                  final feedItem = state.items[itemIndex];
                                  final spec = specFor(feedItem);
                                  final Widget child = spec != null
                                      ? MediaTile(spec: spec)
                                      : feedItem.maybeMap(
                                          channel: (c) => _ChannelTile(channel: c),
                                          orElse: () => const SizedBox.shrink(),
                                        );

                                  return Expanded(child: child);
                                }),
                              ),
                      );
                    },
                                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}


/// The row under the grid: loading the next page, or the failure that stopped
/// it.
///
/// Its whole reason for existing is that `loadMore` now refuses to run again
/// after a failure. Something has to say so, or the feed just quietly stops
/// growing and the user is left scrolling into nothing.
class _FeedFooter extends ConsumerWidget {
  const _FeedFooter({required this.state});

  final FeedState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    if (state.error == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24.0),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, color: scheme.error, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              "Couldn't load more: ${state.error}",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          if (state.errorRetry != RpcRetryMode.no) ...[
            const SizedBox(width: 16),
            TextButton(
              onPressed: () => ref.read(feedProvider.notifier).retryMore(),
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final ChannelItem channel;
  const _ChannelTile({required this.channel});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
      ],
    );
  }
}
