import 'package:freezed_annotation/freezed_annotation.dart';

import 'feed_item.dart';

part 'artist_panel.freezed.dart';
part 'artist_panel.g.dart';

/// A colour YouTube supplies for both themes, as ARGB ints (`0xAARRGGBB`).
///
/// Both halves ship because the sidecar has no idea which theme Flutter is
/// painting; [ArtistPanelColors.resolve] is where one is chosen.
@freezed
abstract class ThemedColor with _$ThemedColor {
  const ThemedColor._();
  const factory ThemedColor({
    required int light,
    required int dark,
  }) = _ThemedColor;

  factory ThemedColor.fromJson(Map<String, Object?> json) => _$ThemedColorFromJson(json);
}

/// The "official artist channel" panel a search for an artist's name returns
/// above the ordinary results (Task 21 §3, `docs/protocol.md` §3.3) —
/// `officialCardViewModel`, confirmed absent for an ordinary creator search,
/// so its presence on `search.query`'s response is itself the "is an
/// official artist channel" fact.
///
/// A field on the search response rather than a `FeedItem` kind: `FeedItem`
/// is a sealed union every grid switches over, and a panel is not a grid
/// item.
@freezed
abstract class ArtistPanel with _$ArtistPanel {
  const ArtistPanel._();
  const factory ArtistPanel({
    required String channelId,
    required String name,
    String? handle,
    required String avatarUrl,
    String? subscriberText,
    String? videoCountText,
    String? description,
    required bool isSubscribed,
    /// The `RD…` id behind the panel's own "Mix" action, or null.
    String? mixPlaylistId,

    /// The panel's own tint, derived server-side from the artist's imagery
    /// (`protocol.md` §3.3) — so nothing here samples the avatar. Null when
    /// the payload omitted it, which [ArtistPanelCard] falls back from.
    ThemedColor? backgroundColor,

    /// The much darker page wash behind [backgroundColor].
    ThemedColor? baseBackgroundColor,

    /// The wide artwork strip that bleeds off the panel's top-right corner —
    /// `cinematicContainerViewModel`'s background, and a genuinely different
    /// image from [avatarUrl] (a 600x176 banner against the avatar's square).
    String? backdropUrl,

    /// The panel's embedded "top videos" shelf: a leading [MixItem] then the
    /// artist's most-viewed [VideoItem]s, as ordinary flat DTOs the same
    /// `MediaTile` renders everywhere else.
    @Default(<FeedItem>[]) List<FeedItem> shelfItems,
  }) = _ArtistPanel;

  factory ArtistPanel.fromJson(Map<String, Object?> json) => _$ArtistPanelFromJson(json);
}
