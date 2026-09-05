import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../feed_controller.dart';
import '../open_video.dart';
import '../../data/rpc/client.dart';
import '../../domain/feed_item.dart';
import '../../theme/screen_values.dart';
import 'channel_badge.dart';
import 'media_tile.dart';
import 'subscribe_button.dart';

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
    this.isWideLayout = false,
    this.itemFilter,
    this.header,
    this.assumeChannelsSubscribed = false,
    this.scrollController,
  });

  final NotifierProvider<FeedController, FeedState> provider;
  final Widget? header;
  final bool isWideLayout;

  /// An external controller a caller needs to drive scrolling itself — e.g.
  /// `AllSubscriptionsPage`'s letter index (Task 22). `null` keeps the
  /// previous behaviour: [FeedView] owns and disposes its own.
  final ScrollController? scrollController;

  /// True on a surface whose every `ChannelItem` is, by definition of the
  /// page, already a subscription (`all_subscriptions.dart`) — see
  /// [ChannelTile.assumeSubscribed].
  final bool assumeChannelsSubscribed;

  /// Restricts the grid to items this predicate accepts, applied before every
  /// layout computation (row math, the footer, the load-more trigger) — so a
  /// caller showing "everything except X" elsewhere (a Shorts shelf, say)
  /// never double-renders X here. Generic and surface-agnostic on purpose:
  /// [FeedView] stays ignorant of *why* a caller is filtering.
  final bool Function(FeedItem item)? itemFilter;

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
  ScrollController? _ownedScroll;
  ScrollController get _scroll => widget.scrollController ?? (_ownedScroll ??= ScrollController());

  @override
  void dispose() {
    _ownedScroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A filter (or query) change starts at the top, said out loud — see
    // `FeedPage`'s original comment; unchanged behaviour, now surface-agnostic.
    ref.listen(widget.provider.select((s) => (s.selectedToken, s.query)), (
      previous,
      next,
    ) {
      if (previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    });

    final state = ref.watch(widget.provider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
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
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: ScreenValues.contentMaxWidth,
                      ),
                      child: FilterChip(
                        label: Text(chip.label),
                        selected: isSelected,
                        showCheckmark: false,
                        onSelected: (_) {
                          ref.read(widget.provider.notifier).selectChip(chip);
                        },
                      ),
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

  Widget _buildBody(BuildContext context, FeedState state, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final items = widget.itemFilter == null ? state.items : state.items.where(widget.itemFilter!).toList();

    if (state.error != null && items.isEmpty) {
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
                  onPressed: () => ref
                      .read(widget.provider.notifier)
                      .load(
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

    if (state.isAuthDegraded && state.items.isEmpty)
      return const Center(
        child: Text('Authentication Degraded. Please sign in again.'),
      );

    if (state.isAnonymous && state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.account_circle_outlined,
              size: 64,
              color: scheme.onSurfaceVariant,
            ),
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Login flow not implemented yet'),
                  ),
                );
              },
              icon: const Icon(Icons.login),
              label: const Text('Log In'),
            ),
          ],
        ),
      );
    }

    if (items.isEmpty && state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // A load that finished, found nothing, and is none of the above — a real
    // "no results" rather than a degraded or anonymous session. Search is the
    // surface this actually happens on; home and subscriptions rarely go here
    // (an empty base browse is caught by `checkAuthOnEmpty` first), but the
    // check is generic rather than search-specific because "the query changed
    // and now there's nothing" is not a property of one surface. Checked
    // against the filtered count: a page whose every item an [itemFilter]
    // excluded should not flash the raw grid it will never render.
    if (items.isEmpty && !state.isLoading && state.error == null) {
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
          // The grid (home, subscriptions, all-subscriptions) gets real breathing
          // room between rows; a wide, single-column surface (search results, and
          // any future one) sits closer to a list and stays tight instead.
          final double spacing = widget.isWideLayout ? 2.0 : 16.0;
          const double hSpacing = 16.0;

          int crossAxisCount = widget.isWideLayout ? 1 : ((constraints.maxWidth + hSpacing) / (maxExtent + hSpacing)).ceil();
          crossAxisCount = math.max(1, crossAxisCount);

          final bool hasFooter = items.isNotEmpty && (state.isLoading || state.error != null);

          List<Widget> rows = [];
          if (widget.header != null) {
            Widget headerContent = Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: widget.header!,
            );
            if (widget.isWideLayout) {
              headerContent = Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: ScreenValues.contentMaxWidth,
                  ),
                  child: headerContent,
                ),
              );
            }
            rows.add(headerContent);
          }

          int i = 0;
          while (i < items.length) {
            final current = items[i];
            if (current is VideoItem && current.isShort) {
              List<FeedItem> shorts = [];
              while (i < items.length) {
                final maybeShort = items[i];
                if (maybeShort is VideoItem && maybeShort.isShort) {
                  shorts.add(maybeShort);
                  i++;
                } else {
                  break;
                }
              }
              Widget shortsShelf = _buildShortsShelf(
                context,
                ref,
                shorts,
                scheme,
              );
              if (widget.isWideLayout) {
                shortsShelf = Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: ScreenValues.contentMaxWidth,
                    ),
                    child: shortsShelf,
                  ),
                );
              }
              rows.add(shortsShelf);
            } else {
              List<FeedItem> rowItems = [];
              while (i < items.length && rowItems.length < crossAxisCount) {
                final maybeShort = items[i];
                if (maybeShort is VideoItem && maybeShort.isShort) {
                  break;
                }
                rowItems.add(items[i]);
                i++;
              }

              // `IntrinsicHeight` only when every item in the row is a
              // channel: that's what lets `ChannelTile.small`'s bottom-pinned
              // Subscribe button (a `Spacer` in a min-size `Column`, which
              // needs a bounded height from somewhere) line up across a row.
              // `MediaTile` puts a `LayoutBuilder` at the top of its own
              // build — which cannot answer an intrinsic-height query, by
              // Flutter's design — so a row that mixes in even one video item
              // must stay a plain `Row`, sized-per-child, or `IntrinsicHeight`
              // throws while walking that subtree.
              final bool rowIsAllChannels = rowItems.every((item) => specFor(item) == null);

              Widget buildRow() {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: hSpacing,
                  children: List.generate(crossAxisCount, (colIndex) {
                    if (colIndex >= rowItems.length) return const Expanded(child: SizedBox.shrink());

                    final feedItem = rowItems[colIndex];
                    final spec = specFor(feedItem);
                    final Widget child = spec != null
                        ? (widget.isWideLayout
                              ? MediaTile.wide(
                                  spec: spec,
                                  size: MediaTileSize.large,
                                  onTap: watchTargetFor(feedItem) == null ? null : () => openFromTile(ref, feedItem),
                                  onAddToQueue: () => queueFromTile(ref, feedItem),
                                  onWatchLater: () => addToWatchLater(context, feedItem),
                                )
                              : MediaTile(
                                  spec: spec,
                                  onTap: watchTargetFor(feedItem) == null ? null : () => openFromTile(ref, feedItem),
                                  onAddToQueue: () => queueFromTile(ref, feedItem),
                                  onWatchLater: () => addToWatchLater(context, feedItem),
                                ))
                        : feedItem.maybeMap(
                            channel: (c) => widget.isWideLayout
                                ? ChannelTile(channel: c, assumeSubscribed: widget.assumeChannelsSubscribed)
                                : ChannelTile.small(channel: c, assumeSubscribed: widget.assumeChannelsSubscribed),
                            orElse: () => const SizedBox.shrink(),
                          );

                    return Expanded(child: child);
                  }),
                );
              }

              Widget rowContent = rowIsAllChannels ? IntrinsicHeight(child: buildRow()) : buildRow();

              if (widget.isWideLayout) {
                rowContent = Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: ScreenValues.contentMaxWidth,
                    ),
                    child: rowContent,
                  ),
                );
              }

              rows.add(rowContent);
            }
          }

          if (hasFooter) {
            Widget footer = _FeedFooter(
              provider: widget.provider,
              state: state,
            );
            if (widget.isWideLayout) {
              footer = Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: ScreenValues.contentMaxWidth,
                  ),
                  child: footer,
                ),
              );
            }
            rows.add(footer);
          }

          return Padding(
            padding: const EdgeInsets.only(right: 13.0),
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                topRight: Radius.circular(10),
              ),
              child: SilkyListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.only(
                  bottom: 16.0,
                  top: 8.0,
                  left: 8.0,
                  right: 8.0,
                ),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: index < rows.length - 1 ? spacing : 0,
                    ),
                    child: rows[index],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildShortsShelf(
    BuildContext context,
    WidgetRef ref,
    List<FeedItem> shorts,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.smart_display_outlined,
                  size: 20,
                  color: scheme.onSurface,
                ),
                const SizedBox(width: 8),
                Text(
                  'Shorts',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              // We want to fit around 3-4 shorts on screen if possible, but keep them reasonable.
              final double itemWidth = (constraints.maxWidth / 3.5).clamp(
                140.0,
                200.0,
              );
              // The thumbnail box itself is `shortAspectRatioSecondary` (2:3,
              // not the raw 9:16 a Short's video actually is) — measured off
              // youtube.com's own Shorts shelf, which crops a little tighter
              // than the source thumbnail's pillarboxing but not all the way
              // to 9:16. Must match `media_tile.dart`'s `topArea` exactly: a
              // mismatch here doesn't crop wrong, it just leaves dead space
              // (or overflows) below a thumbnail sized for a different ratio.
              // Add ~62.5px for the title and view count below it.
              final double itemHeight = (itemWidth * (1 / ScreenValues.shortAspectRatioSecondary)) + 85.5;

              return SizedBox(
                height: itemHeight,
                child: SilkyListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: shorts.length,
                  itemBuilder: (context, index) {
                    final item = shorts[index];
                    final spec = specFor(item);

                    if (spec == null) return const SizedBox.shrink();

                    return Padding(
                      padding: const EdgeInsets.only(right: 16.0),
                      child: SizedBox(
                        width: itemWidth,
                        child: MediaTile.shorts(
                          spec: spec,
                          onTap: watchTargetFor(item) == null ? null : () => openFromTile(ref, item),
                          onAddToQueue: () => queueFromTile(ref, item),
                          onWatchLater: () => addToWatchLater(context, item),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
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

enum ChannelTileSize { wide, small }

class ChannelTile extends StatelessWidget {
  final ChannelItem channel;
  final ChannelTileSize size;

  /// True on pages that only ever list channels the user is already
  /// subscribed to (`all_subscriptions.dart`) — the `ChannelItem` DTO itself
  /// carries no `isSubscribed` field (it's a fixed cross-process shape, per
  /// `CLAUDE.md`), so a caller with that context has to say so explicitly.
  final bool assumeSubscribed;

  const ChannelTile({
    super.key,
    required this.channel,
    this.size = ChannelTileSize.wide,
    this.assumeSubscribed = false,
  });

  const ChannelTile.small({
    super.key,
    required this.channel,
    this.size = ChannelTileSize.small,
    this.assumeSubscribed = false,
  });

  @override
  Widget build(BuildContext context) {
    switch (size) {
      case ChannelTileSize.small:
        return _buildSmall(context);
      case ChannelTileSize.wide:
        return _buildWide(context);
    }
  }

  Widget _buildWide(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            flex: 0,
            fit: FlexFit.loose,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Align(
                alignment: Alignment.center,
                child: CircleAvatar(
                  radius: 64,
                  backgroundImage: channel.avatarUrl.isEmpty ? null : NetworkImage(channel.avatarUrl),
                  onBackgroundImageError: channel.avatarUrl.isEmpty ? null : (error, stackTrace) {},
                  child: channel.avatarUrl.isEmpty ? const Icon(Icons.person, size: 64) : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 1,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 20,
                              ),
                            ),
                          ),
                          ChannelBadge(
                            channelId: channel.id,
                            isArtistChannel: channel.isArtistChannel,
                            isVerified: channel.isVerified,
                            size: 16,
                            paddingLeft: 6,
                          ),
                        ],
                      ),
                      if (channel.subscriberText != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          channel.subscriberText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      if (channel.descriptionSnippet != null && channel.descriptionSnippet!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          channel.descriptionSnippet!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SubscribeButton(
                  key: ValueKey(channel.id),
                  channelId: channel.id,
                  initiallySubscribed: assumeSubscribed,
                ),
                const SizedBox(width: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmall(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundImage: channel.avatarUrl.isEmpty ? null : NetworkImage(channel.avatarUrl),
                onBackgroundImageError: channel.avatarUrl.isEmpty ? null : (error, stackTrace) {},
                child: channel.avatarUrl.isEmpty ? const Icon(Icons.person, size: 32) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        ChannelBadge(
                          channelId: channel.id,
                          isArtistChannel: channel.isArtistChannel,
                          isVerified: channel.isVerified,
                          size: 14,
                          paddingLeft: 4,
                        ),
                      ],
                    ),
                    if (channel.subscriberText != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        channel.subscriberText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (channel.descriptionSnippet != null && channel.descriptionSnippet!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              channel.descriptionSnippet!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
          
          const SizedBox(height: 16.0),
          
          const Spacer(flex: 2),

          SizedBox(
            height: 36,
            width: double.infinity,
            child: SubscribeButton(
              key: ValueKey(channel.id),
              channelId: channel.id,
              initiallySubscribed: assumeSubscribed,
            ),
          ),
        ],
      ),
    );
  }
}
