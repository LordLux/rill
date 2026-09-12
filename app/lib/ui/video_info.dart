import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rpc/client.dart';
import '../domain/feed_item.dart';
import '../domain/playlist_membership.dart';
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

/// `playlist.forVideo` for one video (`protocol.md` §3.9) — the Watch Later
/// pill's and the Save dialog's shared source of truth for "is this video
/// already saved," per video.
///
/// Fetched concurrently with [videoInfoProvider] rather than folded into it,
/// the same reason `captions.list` runs alongside rather than inside the
/// watch page's open path (§3.8): `/next` carries no playlist membership at
/// all, so this is a genuinely separate call, and the watch page needs both
/// without either waiting on the other. Not `autoDispose`, to match
/// [videoInfoProvider] — a mini-player round trip should not re-fetch this
/// either.
///
/// On an anonymous session this resolves to an `AUTH_REQUIRED` error, which
/// callers should read as "membership unknown" rather than surface as a
/// watch-page error — most viewers are anonymous, and a save pill has no
/// business demanding a sign-in nobody asked for yet.
final playlistMembershipProvider =
    FutureProvider.family<List<PlaylistMembership>, String>((ref, videoId) async {
  final response = await RpcClient.instance.call('playlist.forVideo', {'videoId': videoId})
      as Map<String, dynamic>;
  return (response['playlists'] as List<dynamic>? ?? [])
      .map((p) => PlaylistMembership.fromJson(p as Map<String, dynamic>))
      .toList();
});
