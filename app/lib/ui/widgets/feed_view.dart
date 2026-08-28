import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../feed_controller.dart';
import '../open_video.dart';
import '../../data/rpc/client.dart';
import '../../domain/feed_item.dart';
import 'media_tile.dart';

/// The grid, chip bar, and every loading/error/empty state — generalised out
/// of `FeedPage` (Task 20 §1) so home, search and subscriptions share one
/// implementation rather than three copies that drift.
///
/// Every surface reads through the same [FeedController]/[FeedState] pair, so
/// this only needs the provider to watch — which surface it is shows up
/// entirely through [FeedState.surface] and [SurfaceConfig], never as a branch
/// here.
class FeedView extends ConsumerStatefulWidget {
  const FeedView({
    super.key,
    required this.provider,
    this.emptyMessage,
    this.anonymousTitle,
    this.anonymousMessage,
  });

  final NotifierProvider<FeedController, FeedState> provider;

  /// Shown when a load succeeded with zero items and nothing else explains
  /// it (not loading, not an error, not the anonymous/degraded states below).
  /// `null` falls back to a generic message.
  final String? emptyMessage;

  final String? anonymousTitle;
  final String? anonymousMessage;

  @override
  ConsumerState<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends ConsumerState<FeedView> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A filter (or query) change starts at the top, said out loud — see
    // `FeedPage`'s original comment; unchanged behaviour, now surface-agnostic.
    ref.listen(widget.provider.select((s) => (s.selectedToken, s.query)), (previous, next) {
      if (previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    });

    final state = ref.watch(widget.provider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0, left: 8.0),
            child: SizedBox(
              height: 36,
              child: SilkyListView.builder(
                padding: const EdgeInsets.only(top: 1),
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
                        ref.read(widget.provider.notifier).selectChip(chip);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        Expanded(child: _buildBody(context, state, ref)),
      ],
    );
  }

  /// The tile's Watch Later button. `AUTH_REQUIRED` gets its own line because
  /// "sign in" is actionable and the raw envelope message is not.
  Future<void> _watchLater(BuildContext context, FeedItem item) async {
    final target = watchTargetFor(item);
    if (target == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RpcClient.instance.call('action.addToWatchLater', {'videoId': target.id});
      messenger.showSnackBar(const SnackBar(content: Text('Saved to Watch Later')));
    } on RpcException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to save to Watch Later' : e.message),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
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
                  onPressed: () => ref.read(widget.provider.notifier).load(
                        chipToken: state.selectedToken,
                        query: state.query,
                        filters: state.filters,
                      ),
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (state.isAuthDegraded && state.items.isEmpty) {
      return const Center(child: Text('Authentication Degraded. Please sign in again.'));
    }

    if (state.isAnonymous && state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_circle_outlined, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              widget.anonymousTitle ?? 'You are browsing anonymously.',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              widget.anonymousMessage ?? 'Log in to see your personalized home feed.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Login flow not implemented yet')));
              },
              icon: const Icon(Icons.login),
              label: const Text('Log In'),
            ),
          ],
        ),
      );
    }

    if (state.items.isEmpty && state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // A load that finished, found nothing, and is none of the above — a real
    // "no results" rather than a degraded or anonymous session. Search is the
    // surface this actually happens on; home and subscriptions rarely go here
    // (an empty base browse is caught by `checkAuthOnEmpty` first), but the
    // check is generic rather than search-specific because "the query changed
    // and now there's nothing" is not a property of one surface.
    if (state.items.isEmpty && !state.isLoading && state.error == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 48, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                widget.emptyMessage ?? 'Nothing here yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        if (scrollInfo.metrics.pixels >= scrollInfo.metrics.maxScrollExtent - 400) {
          ref.read(widget.provider.notifier).loadMore();
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          const double maxExtent = 430.0;
          const double spacing = 32.0;
          const double hSpacing = 16.0;

          int crossAxisCount = ((constraints.maxWidth + hSpacing) / (maxExtent + hSpacing)).ceil();
          crossAxisCount = math.max(1, crossAxisCount);

          final bool hasFooter = state.items.isNotEmpty && (state.isLoading || state.error != null);
          final int gridRows = (state.items.length / crossAxisCount).ceil();
          final int rowCount = gridRows + (hasFooter ? 1 : 0);

          return Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            interactive: true,
            child: Padding(
              padding: const EdgeInsets.only(right: 13.0),
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10)),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                  child: SilkyListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 16.0, top: 8.0, left: 8.0, right: 8.0),
                    itemCount: rowCount,
                    itemBuilder: (context, rowIndex) {
                      final bool isFooter = hasFooter && rowIndex == rowCount - 1;
                      return Padding(
                        padding: EdgeInsets.only(bottom: rowIndex < rowCount - 1 ? spacing : 0),
                        child: isFooter
                            ? _FeedFooter(provider: widget.provider, state: state)
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: hSpacing,
                                children: List.generate(crossAxisCount, (colIndex) {
                                  final int itemIndex = rowIndex * crossAxisCount + colIndex;
                                  if (itemIndex >= state.items.length) {
                                    return const Expanded(child: SizedBox.shrink());
                                  }

                                  final feedItem = state.items[itemIndex];
                                  final spec = specFor(feedItem);
                                  final Widget child = spec != null
                                      ? MediaTile(
                                          spec: spec,
                                          onTap: watchTargetFor(feedItem) == null
                                              ? null
                                              : () => openFromTile(ref, feedItem),
                                          onAddToQueue: () => queueFromTile(ref, feedItem),
                                          onWatchLater: () => _watchLater(context, feedItem),
                                        )
                                      : feedItem.maybeMap(
                                          channel: (c) => ChannelTile(channel: c),
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
class _FeedFooter extends ConsumerWidget {
  const _FeedFooter({required this.provider, required this.state});

  final NotifierProvider<FeedController, FeedState> provider;
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
              onPressed: () => ref.read(provider.notifier).retryMore(),
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

class ChannelTile extends StatelessWidget {
  final ChannelItem channel;
  const ChannelTile({super.key, required this.channel});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: 48,
          // `CircleAvatar` asserts `backgroundImage != null || onBackgroundImageError
          // == null` — an empty `avatarUrl` (measured live: a search channel result
          // can carry one) must drop the error handler along with the image, not
          // just the image, or the widget throws before it ever paints.
          backgroundImage: channel.avatarUrl.isEmpty ? null : NetworkImage(channel.avatarUrl),
          onBackgroundImageError: channel.avatarUrl.isEmpty ? null : (error, stackTrace) {},
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
