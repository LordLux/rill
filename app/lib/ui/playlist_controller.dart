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
    this.errorRetry,
  });

  final String playlistId;
  final String? title;
  final int? videoCount;
  final PlaylistHeader? header;
  final List<VideoItem> items;
  final String? continuation;
  final bool loading;
  final String? error;

  /// What [error] says about asking again (`protocol.md` §4), null with no
  /// error. Kept beside the message, as `FeedState.errorRetry` is: the message
  /// alone cannot say whether a retry would be a lie.
  final RpcRetryMode? errorRetry;

  /// Whether a retry is worth offering. Not for `no`: "The playlist does not
  /// exist." is YouTube's answer, and asking again gets it again.
  bool get canRetry => error != null && errorRetry != RpcRetryMode.no;

  PlaylistState copyWith({
    Object? title = _sentinel,
    Object? videoCount = _sentinel,
    Object? header = _sentinel,
    List<VideoItem>? items,
    Object? continuation = _sentinel,
    bool? loading,
    Object? error = _sentinel,
    Object? errorRetry = _sentinel,
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
      errorRetry: errorRetry == _sentinel ? this.errorRetry : errorRetry as RpcRetryMode?,
    );
  }
}

/// What a failure says, and what it says about asking again. Anything that is
/// not an RPC error (a dropped connection inside the client) is the user's call.
(String, RpcRetryMode) _failure(Object error) => switch (error) {
      RpcException(:final message, :final retry) => (message, retry),
      _ => (error.toString(), RpcRetryMode.user),
    };

/// Changes when the viewer does, for a page that was read for one viewer.
///
/// Not [authIdentityProvider] itself, whose value is `(signed in, handle)`: the
/// handle arrives a moment after the sign-in, so that value changes twice for
/// one sign-in, and a page watching it was fetched twice and dropped back to
/// its first rows twice. The handle becoming known is the same person; the
/// flag flipping, or one handle giving way to another, is a different one.
class PlaylistViewer extends Notifier<int> {
  @override
  int build() {
    ref.listen(authIdentityProvider, (previous, next) {
      if (previous == null) return;
      final becameKnown = previous.$1 == next.$1 && previous.$2 == null;
      if (!becameKnown) state++;
    });
    return 0;
  }
}

final playlistViewerProvider = NotifierProvider<PlaylistViewer, int>(PlaylistViewer.new);

class PlaylistController extends AsyncNotifier<PlaylistState> {
  PlaylistController(this.arg);
  final String arg;

  @override
  FutureOr<PlaylistState> build() async {
    // `isOwnedByViewer` and a private playlist's very existence are the
    // viewer's: a page read under one identity is not shown under another
    // (CLAUDE.md, account-derived state).
    ref.watch(playlistViewerProvider);
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
      final (message, retry) = _failure(e);
      return PlaylistState(playlistId: arg, error: message, errorRetry: retry);
    }
  }

  Future<void> _load({bool next = false}) async {
    final currentState = state.value;
    if (currentState == null) return;
    if (currentState.loading && next) return;

    final token = next ? currentState.continuation : null;
    if (next && token == null) return;

    state = AsyncData(currentState.copyWith(loading: true, error: null, errorRetry: null));

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
        errorRetry: null,
      ));
    } catch (e) {
      if (!ref.mounted) return;
      final (message, retry) = _failure(e);
      state = AsyncData(currentState.copyWith(loading: false, error: message, errorRetry: retry));
    }
  }

  /// Ask again, for a failure that offers it. A `no` is not asked again by
  /// anything: the page shows no button for it, and this is the other guard.
  Future<void> retry() async {
    final current = state.value;
    if (current == null || !current.canRetry) return;
    await _load(next: current.items.isNotEmpty);
  }

  /// The scroll's request for more. **Not after a failure:** the page offers a
  /// retry at its foot, and a scroll that asked again by itself sent one request
  /// per scroll event for as long as the network stayed down.
  Future<void> loadNext() async {
    if (state.value?.error != null) return;
    await _load(next: true);
  }
}

final playlistProvider = AsyncNotifierProvider.autoDispose.family<PlaylistController, PlaylistState, String>(PlaylistController.new);
