import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rpc/client.dart';
import '../domain/feed_item.dart';
import '../domain/video_detail.dart';

/// `video.info` for one video (`protocol.md` §3.3).
///
/// A family rather than a single provider, and deliberately **not**
/// `autoDispose`: the mini-player → watch page → back → watch page loop would
/// otherwise refetch the whole watch page every time it is expanded, and put a
/// spinner over a video that is still playing perfectly well. What it costs is
/// one `VideoDetail` per video watched in a session.
///
/// The error is left to propagate. `AsyncValue.error` carries the `RpcException`
/// itself, so the watch page can read its `retry` field and decide between a
/// retry affordance and an honest dead end (§4).
final videoInfoProvider = FutureProvider.family<VideoDetail, String>((ref, videoId) async {
  final response = await RpcClient.instance.call('video.info', {'videoId': videoId});
  return VideoDetail.fromJson(response as Map<String, dynamic>);
});

/// One page of `video.related` (§3.3).
///
/// The watch page's rail starts from `VideoDetail.related` — the same DTOs, out
/// of the `/next` response `video.info` already paid for — and calls this only
/// when the user asks for more. Fetching page one through here as well would be
/// a second `/next` for a list already in hand.
Future<({List<FeedItem> items, String? continuation})> fetchRelated(
  String videoId, {
  String? continuation,
}) async {
  final response = await RpcClient.instance.call('video.related', {
    'videoId': videoId,
    'continuation': ?continuation,
  }) as Map<String, dynamic>;

  final items = (response['items'] as List<dynamic>? ?? [])
      .map((item) => FeedItem.fromJson(item as Map<String, dynamic>))
      .toList();

  return (items: items, continuation: response['continuation'] as String?);
}
