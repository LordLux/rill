import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/feed_item.dart';
import '../data/rpc/client.dart';

class FeedState {
  final List<FeedItem> items;
  final List<Chip> chips;
  final Chip? selectedChip;
  final String? continuation;
  final bool isLoading;
  final String? error;
  final bool isAuthDegraded;
  final bool isAnonymous;

  FeedState({
    this.items = const [],
    this.chips = const [],
    this.selectedChip,
    this.continuation,
    this.isLoading = true,
    this.error,
    this.isAuthDegraded = false,
    this.isAnonymous = false,
  });

  FeedState copyWith({
    List<FeedItem>? items,
    List<Chip>? chips,
    Chip? selectedChip,
    String? continuation,
    bool? isLoading,
    String? error,
    bool? isAuthDegraded,
    bool? isAnonymous,
  }) {
    return FeedState(
      items: items ?? this.items,
      chips: chips ?? this.chips,
      selectedChip: selectedChip ?? this.selectedChip,
      continuation: continuation ?? this.continuation,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      isAuthDegraded: isAuthDegraded ?? this.isAuthDegraded,
      isAnonymous: isAnonymous ?? this.isAnonymous,
    );
  }
}

class FeedController extends Notifier<FeedState> {
  @override
  FeedState build() {
    Future.microtask(() => loadHome());
    return FeedState();
  }

  int? _currentRequestId;

  Future<void> loadHome({String? chipToken, bool isLoadMore = false}) async {
    if (_currentRequestId != null) {
      RpcClient.instance.cancel(_currentRequestId!);
      _currentRequestId = null;
    }

    if (!isLoadMore) {
      state = state.copyWith(
        isLoading: true,
        error: null,
        items: [],
        continuation: null,
        isAuthDegraded: false,
        isAnonymous: false,
      );
    } else {
      state = state.copyWith(isLoading: true, error: null);
    }

    try {
      final params = <String, dynamic>{};
      if (chipToken != null) params['chipToken'] = chipToken;
      if (isLoadMore && state.continuation != null) {
        params['continuation'] = state.continuation;
      }

      // Call feed.home
      final response = await RpcClient.instance.call('feed.home', params);
      
      // If we receive an empty feed, verify auth
      if ((response['items'] as List?)?.isEmpty == true && !isLoadMore && chipToken == null) {
        final authResponse = await RpcClient.instance.call('auth.verify', {});
        final stateStr = authResponse['state'] as String?;
        if (stateStr == 'degraded') {
          state = state.copyWith(isAuthDegraded: true, isLoading: false);
          return;
        } else if (stateStr == 'anonymous') {
          state = state.copyWith(isAnonymous: true, isLoading: false);
          return;
        }
      }

      final rawChips = response['chips'] as List<dynamic>? ?? [];
      final parsedChips = rawChips.map((c) => Chip.fromJson(c as Map<String, dynamic>)).toList();
      
      final rawItems = response['items'] as List<dynamic>? ?? [];
      final parsedItems = rawItems.map((i) => FeedItem.fromJson(i as Map<String, dynamic>)).toList();
      
      final nextContinuation = response['continuation'] as String?;

      state = state.copyWith(
        isLoading: false,
        chips: isLoadMore ? state.chips : parsedChips,
        items: isLoadMore ? [...state.items, ...parsedItems] : parsedItems,
        continuation: nextContinuation,
        selectedChip: chipToken != null ? parsedChips.firstWhere((c) => c.token == chipToken, orElse: () => state.chips.first) : null,
      );
    } on RpcException catch (e) {
      if (e.code == 'AUTH_DEGRADED') {
        state = state.copyWith(isAuthDegraded: true, isLoading: false);
      } else {
        state = state.copyWith(isLoading: false, error: e.message);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> loadMore() async {
    if (state.isLoading || state.continuation == null) return;
    await loadHome(chipToken: state.selectedChip?.token, isLoadMore: true);
  }

  void selectChip(Chip chip) {
    if (state.selectedChip?.token == chip.token) return;
    loadHome(chipToken: chip.token);
  }
}

final feedProvider = NotifierProvider<FeedController, FeedState>(() {
  return FeedController();
});
