import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/feed_item.dart';
import '../feed_controller.dart';
import '../page_wrapper.dart';
import '../widgets/alphabet_index.dart';
import '../widgets/feed_view.dart';

const String allSubscriptionsRouteName = 'all-subscriptions';

/// The channel list (Task 21 §4) — every channel the user is subscribed to,
/// reached from "Show all channels" on [SubscriptionsPage]. A different
/// browse endpoint from the video feed (`subscriptions.channels`, not
/// `feed.subscriptions`), backed by [subscriptionsChannelsProvider] — the
/// same generic [FeedController]/[FeedView] pair every surface uses, so this
/// page is almost entirely chrome.
///
/// The search box filters client-side over whatever page(s) have already
/// loaded — `protocol.md` §3.2 is explicit that sort order is not a request
/// parameter here, and the task's own framing puts search over the list on
/// the client, not the sidecar.
///
/// The A–Z rail (Task 22) is layered on top of the same idea: `protocol.md`
/// §3.3 says the server doesn't accept a sort *parameter*, but its default
/// order is already `#`, then A–Z (confirmed live) — so "jump to a letter"
/// is just "load more until the loaded tail reaches or passes it," never a
/// re-sort. It is hidden while a search query is active: the rail's row math
/// answers against the *unfiltered* list, which stops meaning anything once
/// the grid on screen is a filtered subset of it.
class AllSubscriptionsPage extends ConsumerStatefulWidget {
  const AllSubscriptionsPage({super.key});

  @override
  ConsumerState<AllSubscriptionsPage> createState() => _AllSubscriptionsPageState();
}

class _AllSubscriptionsPageState extends ConsumerState<AllSubscriptionsPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String _query = '';

  /// Kept in step with `FeedView`'s own grid math (`feed_view.dart`'s
  /// `crossAxisCount`) so a row index computed here lands on the same row
  /// `FeedView` actually laid out. Same `maxExtent`/`hSpacing` constants,
  /// duplicated rather than shared because reaching into `FeedView`'s
  /// private `LayoutBuilder` isn't worth it for two numbers — if either
  /// drifts from `feed_view.dart`, the rail starts landing a row or two off.
  int _crossAxisCount = 1;

  /// Bumped on every activation so a superseded jump (the user dragged to a
  /// new letter before the last one finished loading) stops rather than
  /// finishing its own stale scroll after a newer one already has.
  int _jumpGeneration = 0;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _reachedOrPast(FeedState s, String letter) {
    final channels = s.items.whereType<ChannelItem>();
    if (channels.isEmpty) return false;
    return letterBucketOf(channels.last.name).compareTo(letter) >= 0;
  }

  /// The common case, and the only path a drag takes while every letter it
  /// crosses is already covered by what's loaded: no `await`, no generation
  /// check, nothing that could let one letter's scroll get lost or delayed
  /// behind another's. Called directly and synchronously from
  /// [_onLetterActivated] so every letter a drag passes over — not just the
  /// one it started or ends on — gets its own immediate jump.
  void _scrollToLoadedLetter(List<ChannelItem> channels, String letter) {
    if (channels.isEmpty || !_scroll.hasClients) return;

    var targetIndex = channels.indexWhere((c) => letterBucketOf(c.name).compareTo(letter) >= 0);
    // Sorts after everything loaded — nearest available is the end.
    if (targetIndex == -1) targetIndex = channels.length - 1;

    final rowIndex = targetIndex ~/ _crossAxisCount;
    final totalRows = (channels.length / _crossAxisCount).ceil();
    final maxExtent = _scroll.position.maxScrollExtent;
    // `ListView.builder` estimates `maxScrollExtent` from already-built rows
    // even before the whole list has been laid out, so this average is only
    // as good as what's been built so far — an approximation the viewport
    // self-corrects once it actually builds rows near the landed offset, the
    // same way jumping to an arbitrary offset in any lazy list settles.
    final estimatedRowHeight = totalRows > 0 && maxExtent > 0 ? maxExtent / totalRows : 110.0;
    final target = (rowIndex * estimatedRowHeight).clamp(0.0, math.max(0.0, maxExtent)).toDouble();

    // A second `animateTo` while the previous one is still running redirects
    // it to the new target rather than queuing behind it — exactly what a
    // fast A→B→C drag needs: always chase the *current* letter, never the
    // ones already passed.
    _scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// The letter isn't covered by what's loaded yet — the only path that
  /// needs a network round trip, so it's the only one that's async and
  /// generation-guarded against a later letter (from the same drag)
  /// superseding it before it lands.
  Future<void> _loadThenScrollToLetter(String letter) async {
    final myGeneration = ++_jumpGeneration;
    final notifier = ref.read(subscriptionsChannelsProvider.notifier);

    var state = ref.read(subscriptionsChannelsProvider);
    // Capped defensively — this crosses a network boundary on every
    // iteration, unlike a normal in-memory loop, so a bug that stops the
    // loaded tail from ever reaching or passing the target must not turn
    // into unbounded hammering of the sidecar.
    var guard = 0;
    while (!_reachedOrPast(state, letter) && state.continuation != null && state.error == null && guard++ < 200) {
      if (state.isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      } else {
        await notifier.loadMore();
      }
      if (myGeneration != _jumpGeneration) return;
      state = ref.read(subscriptionsChannelsProvider);
    }
    if (myGeneration != _jumpGeneration) return;

    _scrollToLoadedLetter(state.items.whereType<ChannelItem>().toList(), letter);
  }

  void _onLetterActivated(String letter) {
    final state = ref.read(subscriptionsChannelsProvider);
    if (_reachedOrPast(state, letter) || state.continuation == null) {
      _scrollToLoadedLetter(state.items.whereType<ChannelItem>().toList(), letter);
    } else {
      unawaited(_loadThenScrollToLetter(letter));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = _query.trim().toLowerCase();

    return PageWrapper(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BackButton(onPressed: () => Navigator.of(context).maybePop()),
          Text(
            'All subscriptions',
            style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface, fontSize: 20),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: TextField(
                controller: _controller,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search channels',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerLowest,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Mirrors `feed_view.dart`'s own `crossAxisCount` formula —
                // see the field doc above.
                const double maxExtent = 430.0;
                const double hSpacing = 16.0;
                _crossAxisCount = math.max(1, ((constraints.maxWidth + hSpacing) / (maxExtent + hSpacing)).ceil());

                return Stack(
                  children: [
                    FeedView(
                      provider: subscriptionsChannelsProvider,
                      anonymousTitle: 'No subscriptions to show.',
                      anonymousMessage: 'Log in to see the channels you subscribe to.',
                      emptyMessage: 'No subscriptions yet.',
                      assumeChannelsSubscribed: true,
                      scrollController: _scroll,
                      itemFilter: query.isEmpty
                          ? null
                          : (item) => item is ChannelItem && item.name.toLowerCase().contains(query),
                    ),
                    if (query.isEmpty)
                      Positioned(
                        top: 8,
                        bottom: 8,
                        right: 0,
                        child: AlphabetIndex(onActivate: _onLetterActivated),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
