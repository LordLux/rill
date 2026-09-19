import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../feed_controller.dart';
import '../open_video.dart';
import '../../data/rpc/client.dart';
import '../../domain/feed_item.dart';
import '../../theme/screen_values.dart';
import '../auth_controller.dart';
import '../members_only_preference.dart';
import 'account_button.dart';
import 'channel_badge.dart';
import 'feed_grid_metrics.dart';
import 'feed_skeleton.dart';
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
    this.groupMembersOnly = false,
  });

  /// Collect members-only videos out of the grid into a shelf of their own.
  ///
  /// On for the grid surfaces (home, subscriptions), off for search — a search
  /// result is an answer in a *rank order*, and lifting some of its rows into a
  /// shelf at the top would reorder the answer rather than tidy it.
  final bool groupMembersOnly;

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
            padding: const EdgeInsets.only(
              // bottom: 8.0,
              left: 8.0,
            ),
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
    final filtered = widget.itemFilter == null ? state.items : state.items.where(widget.itemFilter!).toList();

    // **Members-only content: hidden, hoisted, or left alone.**
    //
    // Hidden first — when the preference is off nothing members-only reaches
    // any of the three paths below, including the shelf.
    //
    // Then hoisted, on the surfaces that group it: YouTube collects these into
    // one shelf rather than scattering them through the grid, and they arrive
    // scattered. Hoisting means they must also leave the grid — rendering both
    // would show every members-only video twice, which is the same reason the
    // sidecar lifts the artist panel's shelf out rather than letting the walker
    // descend into it (`protocol.md` §3.3).
    final showMembersOnly = ref.watch(membersOnlyVisibleProvider);
    final visible = showMembersOnly ? filtered : filtered.where((i) => !isMembersOnlyItem(i)).toList();

    final membersOnly = widget.groupMembersOnly ? visible.where(isMembersOnlyItem).toList() : const <FeedItem>[];
    final items = widget.groupMembersOnly ? visible.where((i) => !isMembersOnlyItem(i)).toList() : visible;

    // **The emptiness checks below count the shelf too.**
    //
    // Hoisting takes items *out* of `items`, so a page whose every video is
    // members-only leaves the grid empty with a full shelf — and the checks
    // that follow would call that "Nothing here yet" and render nothing, or
    // flash a skeleton over content that had already arrived. A subscriptions
    // feed of one heavily-membership channel is not a hypothetical.
    final isEmpty = items.isEmpty && membersOnly.isEmpty;

    if (state.error != null && isEmpty) {
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

    // **Two signed-out states, two messages** — Task 22 §3. `degraded` means a
    // session the server stopped honouring; `anonymous` means there never was
    // one. Collapsing them into "please sign in" is what makes F7 invisible:
    // the user sees the same empty page either way and has no reason to think
    // anything expired. Both offer the same button, because the same action
    // fixes both — the difference is what the reader is told happened.
    if (state.isAuthDegraded && state.items.isEmpty) {
      return _SignedOutState(
        icon: Icons.gpp_maybe_outlined,
        iconColor: scheme.error,
        title: 'Your session expired.',
        message: 'YouTube stopped honouring this login. Sign in again to get your feed back.',
        buttonLabel: 'Sign in again',
      );
    }

    if (state.isAnonymous && state.items.isEmpty) {
      return _SignedOutState(
        icon: Icons.account_circle_outlined,
        iconColor: scheme.onSurfaceVariant,
        title: widget.anonymousTitle ?? 'You are browsing anonymously.',
        message: widget.anonymousMessage ?? 'Log in to see your personalized home feed.',
        buttonLabel: 'Log In',
      );
    }

    // A skeleton, not a spinner. This is the first paint after a sign-in — the
    // login window has just closed and the user has no other signal that it
    // worked — and a grid-shaped placeholder answers "did that do anything?"
    // where a centred spinner does not. It shares its geometry with the real
    // grid below, so nothing reflows when the items arrive.
    if (isEmpty && state.isLoading) return FeedSkeleton(isWideLayout: widget.isWideLayout);

    // A load that finished, found nothing, and is none of the above — a real
    // "no results" rather than a degraded or anonymous session. Search is the
    // surface this actually happens on; home and subscriptions rarely go here
    // (an empty base browse is caught by `checkAuthOnEmpty` first), but the
    // check is generic rather than search-specific because "the query changed
    // and now there's nothing" is not a property of one surface. Checked
    // against the filtered count: a page whose every item an [itemFilter]
    // excluded should not flash the raw grid it will never render.
    if (isEmpty && !state.isLoading && state.error == null) {
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
          // Geometry lives in `FeedGridMetrics`, shared with `FeedSkeleton`.
          // The numbers themselves are unchanged; what changed is that there is
          // now exactly one copy of them, so the placeholder grid cannot drift
          // from this one and make tiles jump when real content lands.
          final double spacing = FeedGridMetrics.verticalSpacing(widget.isWideLayout);
          const double hSpacing = FeedGridMetrics.horizontalSpacing;
          final int crossAxisCount = FeedGridMetrics.columnCount(constraints.maxWidth, widget.isWideLayout);

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

          // The members shelf goes after roughly one row of grid content, which
          // is where YouTube puts its own — high enough to be seen, not so high
          // that it displaces the feed the user came for.
          //
          // **The threshold is an item count, not a row index**, and the
          // distinction is worth the sentence: it is compared against
          // `gridItemsEmitted`, which is incremented per *item*. One row's worth
          // is `crossAxisCount` items, so on a full first row the two readings
          // agree — but a short first row (the tail of a page, or a grid whose
          // first row lost slots to a Shorts shelf) simply defers the shelf to
          // the next row rather than landing early.
          //
          // It can never land *inside* a row: `maybeAddMembersShelf` appends to
          // `rows`, and every call site sits immediately after a completed
          // `rows.add(...)`.
          final int membersShelfAfterItems = crossAxisCount;
          var gridItemsEmitted = 0;
          var membersShelfEmitted = false;

          void maybeAddMembersShelf() {
            if (membersShelfEmitted || membersOnly.isEmpty) return;
            if (gridItemsEmitted < membersShelfAfterItems) return;
            membersShelfEmitted = true;
            Widget shelf = _buildMembersShelf(context, ref, membersOnly, scheme);
            if (widget.isWideLayout) {
              shelf = Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: ScreenValues.contentMaxWidth),
                  child: shelf,
                ),
              );
            }
            rows.add(shelf);
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
                                  onTap: tapHandlerFor(context, ref, feedItem),
                                  onAddToQueue: () => queueFromTile(ref, feedItem),
                                  onWatchLater: () => addToWatchLater(context, feedItem),
                                  menu: menuForTile(context, ref, feedItem, spec),
                                )
                              : MediaTile(
                                  spec: spec,
                                  onTap: tapHandlerFor(context, ref, feedItem),
                                  onAddToQueue: () => queueFromTile(ref, feedItem),
                                  onWatchLater: () => addToWatchLater(context, feedItem),
                                  menu: menuForTile(context, ref, feedItem, spec),
                                ))
                        : feedItem.maybeMap(
                            channel: (c) => widget.isWideLayout //
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
              gridItemsEmitted += rowItems.length;
              maybeAddMembersShelf();
            }
          }

          // A feed shorter than one row — or one made entirely of members-only
          // videos — still gets the shelf, at the end rather than never.
          membersShelfEmitted = membersShelfEmitted || membersOnly.isEmpty;
          if (!membersShelfEmitted) {
            gridItemsEmitted = membersShelfAfterItems;
            maybeAddMembersShelf();
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
            padding: EdgeInsets.only(right: 2), // just for a more comfortable look
            child: RawScrollbar(
              controller: _scroll,
              thumbVisibility: false,
              thickness: 7,
              radius: const Radius.circular(10),
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                ),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                  child: SilkyListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(
                      bottom: 16.0,
                      top: 10.0,
                      left: 10.0,
                      right: 10.0,
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
              ),
            ),
          );
        },
      ),
    );
  }

  /// The members-only shelf — YouTube's "Get more from memberships", ours.
  ///
  /// A horizontal strip of ordinary video tiles rather than a new tile shape:
  /// these are full-size 16:9 videos, unlike Shorts, so the shelf above is the
  /// wrong template for everything except its structure. What makes it a shelf
  /// is that the videos were *collected* out of the grid, not that they look
  /// different.
  ///
  /// The tiles keep their own green members pill. That is not redundant with
  /// the shelf header — a tile dragged out of context by a screenshot, or a
  /// shelf scrolled so its header is off screen, still has to say what it is.
  Widget _buildMembersShelf(
    BuildContext context,
    WidgetRef ref,
    List<FeedItem> members,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 9.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star_rounded, size: 20, color: scheme.onSurface),
                const SizedBox(width: 8),
                Text(
                  'From your memberships',
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
              // One column narrower than the grid, so the shelf reads as a
              // strip that continues past the edge rather than as a short row
              // that happens to be indented.
              final columns = FeedGridMetrics.columnCount(constraints.maxWidth, false) + 0.4;
              final itemWidth = (constraints.maxWidth / columns).clamp(180.0, 340.0);
              // 16:9 thumbnail plus the same caption block the grid tile uses.
              final itemHeight = itemWidth / ScreenValues.normalAspectRatio + 104.0 + 32;

              return SizedBox(
                height: itemHeight,
                child: SilkyListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: members.length,
                  itemBuilder: (context, index) {
                    final item = members[index];
                    final spec = specFor(item);
                    if (spec == null) return const SizedBox.shrink();
                    return Padding(
                      padding: EdgeInsets.only(right: 16.0, bottom: 8.0, top: 9.0, left: index == 0 ? 10.5 : 0),
                      child: SizedBox(
                        width: itemWidth,
                        child: MediaTile(
                          spec: spec,
                          onTap: tapHandlerFor(context, ref, item),
                          onAddToQueue: () => queueFromTile(ref, item),
                          onWatchLater: () => addToWatchLater(context, item),
                          menu: menuForTile(context, ref, item, spec),
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
                          onTap: tapHandlerFor(context, ref, item),
                          onAddToQueue: () => queueFromTile(ref, item),
                          onWatchLater: () => addToWatchLater(context, item),
                          menu: menuForTile(context, ref, item, spec),
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

/// The empty state for a surface nobody is signed in to — Task 22 §3.
///
/// One widget, two callers, because `degraded` and `anonymous` differ only in
/// what they say. Sharing the *layout* while keeping the *words* apart is the
/// point: the moment these two are one message with one icon, the distinction
/// the task is about stops reaching anybody.
class _SignedOutState extends ConsumerWidget {
  const _SignedOutState({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    required this.buttonLabel,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final String buttonLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final busy = ref.watch(authProvider.select((s) => s.isBusy));

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: iconColor),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              // Disabled while a sign-in is in flight rather than hidden: a
              // button that vanishes mid-click reads as the click having done
              // something else.
              onPressed: busy ? null : () => openLoginFlow(context, ref),
              icon: const Icon(Icons.login),
              label: Text(buttonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
