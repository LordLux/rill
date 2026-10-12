import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/rpc/client.dart';
import '../domain/feed_item.dart';
import 'auth_controller.dart';
import 'queue_controller.dart';

const Object _sentinel = Object();

@immutable
class PlaylistState {
  const PlaylistState({
    required this.playlistId,
    this.title,
    this.videoCount,
    this.header,
    this.items = const [],
    this.continuation,
    this.loading = false,
    this.error,
  });

  final String playlistId;
  final String? title;
  final int? videoCount;
  final PlaylistHeader? header;
  final List<VideoItem> items;
  final String? continuation;
  final bool loading;
  final String? error;

  PlaylistState copyWith({
    Object? title = _sentinel,
    Object? videoCount = _sentinel,
    Object? header = _sentinel,
    List<VideoItem>? items,
    Object? continuation = _sentinel,
    bool? loading,
    Object? error = _sentinel,
  }) {
    return PlaylistState(
      playlistId: playlistId,
      title: title == _sentinel ? this.title : title as String?,
      videoCount: videoCount == _sentinel ? this.videoCount : videoCount as int?,
      header: header == _sentinel ? this.header : header as PlaylistHeader?,
      items: items ?? this.items,
      continuation: continuation == _sentinel ? this.continuation : continuation as String?,
      loading: loading ?? this.loading,
      error: error == _sentinel ? this.error : error as String?,
    );
  }
}

class PlaylistController extends AsyncNotifier<PlaylistState> {
  PlaylistController(this.arg);
  final String arg;

  @override
  FutureOr<PlaylistState> build() async {
    // `isOwnedByViewer` and a private playlist's very existence are the
    // viewer's: a page read under one identity is not shown under another
    // (CLAUDE.md, account-derived state).
    ref.watch(authIdentityProvider);
    try {
      final page = await ref.read(mixServiceProvider).getPlaylist(arg);
      return PlaylistState(
        playlistId: arg,
        title: page.title,
        videoCount: page.videoCount,
        header: page.header,
        items: page.items,
        continuation: page.continuation,
        loading: false,
      );
    } catch (e) {
      final message = e is RpcException ? e.message : e.toString();
      return PlaylistState(playlistId: arg, error: message);
    }
  }

  Future<void> _load({bool next = false}) async {
    final currentState = state.value;
    if (currentState == null) return;
    if (currentState.loading && next) return;

    final token = next ? currentState.continuation : null;
    if (next && token == null) return;

    state = AsyncData(currentState.copyWith(loading: true, error: null));

    // This request's own ref, taken before the await. A re-read under another
    // identity gives the notifier a new one, so `this.ref` read afterwards is
    // mounted again and the old viewer's page landed on top of the new one's.
    final ref = this.ref;
    try {
      final page = await ref.read(mixServiceProvider).getPlaylist(arg, continuation: token);
      // The page was closed, or re-read under another identity, while this was out.
      if (!ref.mounted) return;

      final newItems = next ? [...currentState.items, ...page.items] : page.items;
      state = AsyncData(currentState.copyWith(
        title: page.title ?? currentState.title,
        videoCount: page.videoCount ?? currentState.videoCount,
        header: page.header ?? currentState.header,
        items: newItems,
        continuation: page.continuation,
        loading: false,
        // [currentState] is from before the request, so it still holds the
        // failure a retry is answering: left in, the foot kept saying it.
        error: null,
      ));
    } catch (e) {
      if (!ref.mounted) return;
      final message = e is RpcException ? e.message : e.toString();
      state = AsyncData(currentState.copyWith(loading: false, error: message));
    }
  }

  Future<void> retry() => _load(next: state.value?.items.isNotEmpty ?? false);

  /// The scroll's request for more. **Not after a failure:** the page offers a
  /// retry at its foot, and a scroll that asked again by itself sent one request
  /// per scroll event for as long as the network stayed down.
  Future<void> loadNext() async {
    if (state.value?.error != null) return;
    await _load(next: true);
  }
}

final playlistProvider = AsyncNotifierProvider.autoDispose.family<PlaylistController, PlaylistState, String>(PlaylistController.new);
