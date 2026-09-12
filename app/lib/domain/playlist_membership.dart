import 'package:freezed_annotation/freezed_annotation.dart';

part 'playlist_membership.freezed.dart';
part 'playlist_membership.g.dart';

/// `docs/protocol.md` §3.9. A closed set mirroring the sidecar's
/// `PlaylistPrivacy` — `public` | `unlisted` | `private` — rather than the raw
/// InnerTube strings.
enum PlaylistPrivacy { public, unlisted, private }

/// One row of `playlist.forVideo`'s answer (`docs/protocol.md` §3.9): one of
/// the user's playlists — Watch Later included, at its fixed id `'WL'` — and
/// whether the video asked about is already in it.
@freezed
abstract class PlaylistMembership with _$PlaylistMembership {
  const factory PlaylistMembership({
    required String id,
    required String title,
    PlaylistPrivacy? privacy,
    required bool containsVideo,

    /// Hand this back verbatim to `action.removeFromPlaylist` to un-check this
    /// row. Opaque — nothing on this side parses it, the same rule a feed
    /// `continuation` token already follows. Present only when
    /// [containsVideo] is true.
    String? removeToken,
  }) = _PlaylistMembership;

  factory PlaylistMembership.fromJson(Map<String, Object?> json) =>
      _$PlaylistMembershipFromJson(json);
}
