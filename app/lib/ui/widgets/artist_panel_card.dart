import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../data/rpc/client.dart';
import '../../domain/artist_panel.dart';
import '../../domain/feed_item.dart';
import '../../theme/screen_values.dart';
import '../open_video.dart';
import 'channel_badge.dart';
import 'media_tile.dart';
import 'subscribe_button.dart';

/// The "official artist channel" panel `search.query` carries above the
/// ordinary results for an artist-name query (Task 21 §3, `protocol.md`
/// §3.3) — rebuilt in Task 23 as the tinted hero YouTube itself shows: the
/// artist's own colour behind an avatar, name, metadata, action row, and the
/// panel's embedded shelf of top videos.
///
/// **The tint is YouTube's, not ours.** `officialCardViewModel` ships
/// `backgroundColor`/`baseBackgroundColor` as ARGB pairs already derived from
/// the artist's imagery server-side, so nothing here samples the avatar — no
/// decode, no palette pass, and no first frame painted in the wrong colour
/// while a sampler runs. [ArtistPanelTint] only picks which half of the pair
/// applies and what stays legible on top of it.
///
/// "View Channel" and "Mix" are still inert: this app has no channel page and
/// no `mix.start` RPC wired yet (both pre-existing gaps), so they fall back to
/// the same "Not implemented" snackbar `search_results.dart`'s own filter
/// pills use. **Subscribe and unsubscribe are both real** (Task 25) —
/// `action.subscribe`/`action.unsubscribe`, via [SubscribeButton]'s
/// `onSubscribe`/`onUnsubscribe` hooks. The dropdown's notification-level
/// picker is still a local-only stub: `protocol.md` has no notification-
/// preference endpoint.
class ArtistPanelCard extends ConsumerStatefulWidget {
  const ArtistPanelCard({super.key, required this.artist});

  final ArtistPanel artist;

  @override
  ConsumerState<ArtistPanelCard> createState() => _ArtistPanelCardState();
}

class _ArtistPanelCardState extends ConsumerState<ArtistPanelCard> {
  final ScrollController _shelfScroll = ScrollController();

  @override
  void dispose() {
    _shelfScroll.dispose();
    super.dispose();
  }

  Future<bool> _subscribe(String channelId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RpcClient.instance.call('action.subscribe', {'channelId': channelId});
      return true;
    } on RpcException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to subscribe' : e.message)),
      );
      return false;
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  Future<bool> _unsubscribe(String channelId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RpcClient.instance.call('action.unsubscribe', {'channelId': channelId});
      return true;
    } on RpcException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to unsubscribe' : e.message)),
      );
      return false;
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  void _notImplemented() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not implemented')));
  }

  /// Advances the shelf by roughly one screenful, because the viewport is the
  /// only thing that knows how many tiles that is — a fixed tile count would
  /// overshoot on a narrow panel and undershoot on a wide one.
  void _nudgeShelf(int direction) {
    if (!_shelfScroll.hasClients) return;
    final position = _shelfScroll.position;
    final target = (position.pixels + direction * position.viewportDimension * 0.8)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    _shelfScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    final tint = ArtistPanelTint.of(context, artist);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ScreenValues.contentMaxWidth),
        child: Container(
          margin: const EdgeInsets.only(bottom: 16.0),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: tint.surface,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(22),
              bottomRight: Radius.circular(22),
            ),
          ),
          child: Stack(
            children: [
              // The artwork bleeding off the top-right corner. Behind
              // everything and non-interactive.
              Positioned.fill(child: _ArtworkBleed(backdropUrl: artist.backdropUrl)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    child: _Header(
                      artist: artist,
                      tint: tint,
                      onSubscribe: _subscribe,
                      onUnsubscribe: _unsubscribe,
                      onNotImplemented: _notImplemented,
                    ),
                  ),
                  if (artist.shelfItems.isNotEmpty)
                    _Shelf(
                      items: artist.shelfItems,
                      tint: tint,
                      controller: _shelfScroll,
                      onNudge: _nudgeShelf,
                    )
                  else
                    const SizedBox(height: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tint
// ---------------------------------------------------------------------------

/// Which half of YouTube's [ThemedColor] pair applies, and what stays legible
/// on top of it.
///
/// The foreground is chosen from the resolved fill's own luminance rather
/// than from the app theme's brightness. The two usually agree, but an artist
/// whose colour is a pale wash inside a dark-themed app is exactly the case
/// where following the theme would paint white on near-white and lose the
/// name entirely.
@immutable
class ArtistPanelTint {
  const ArtistPanelTint({
    required this.surface,
    required this.onSurface,
    required this.onSurfaceMuted,
    required this.outline,
  });

  final Color surface;
  final Color onSurface;
  final Color onSurfaceMuted;
  final Color outline;

  factory ArtistPanelTint.of(BuildContext context, ArtistPanel artist) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final themed = artist.backgroundColor;
    // A panel with no tint in the payload is not an error — it just reads as
    // an ordinary raised card, which is what this surface looked like before
    // Task 23.
    final surface = themed == null
        ? theme.colorScheme.surfaceContainerHigh
        : Color(isDark ? themed.dark : themed.light);

    final onSurface = ThemeData.estimateBrightnessForColor(surface) == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF0B0B0B);

    return ArtistPanelTint(
      surface: surface,
      onSurface: onSurface,
      onSurfaceMuted: onSurface.withValues(alpha: 0.72),
      outline: onSurface.withValues(alpha: 0.30),
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// The artwork strip bleeding off the panel's top-right corner.
///
/// **This is [ArtistPanel.backdropUrl], not the avatar.** They are different
/// pictures — the backdrop is a wide banner the artist chose for exactly this
/// slot, the avatar a square portrait — and a blurred copy of the second is
/// not a substitute for the first.
///
/// Sized with [FractionallySizedBox] rather than an `Align` `widthFactor`:
/// the parent is a `Positioned.fill`, so the incoming constraints are tight,
/// and a tight constraint makes `Align` ignore its factor entirely and fill
/// the box. The two fades below then have to do all the shaping, which is why
/// the earlier version rendered as very little.
///
/// **The `ClipRect` sits inside the fractional box, and that placement is
/// load-bearing.** A blurred layer paints past its own bounds, and a
/// `ShaderMask` masks only *within* its rect — so whatever the blur pushes
/// outside is composited with no mask on it at all. With the clip outside the
/// fractional box it was clipping to the whole card and containing nothing:
/// `TileMode.clamp` repeats the artwork's edge pixel outward, so the escaped
/// band was a solid, hard-edged bar of whatever colour the artwork's left
/// column happened to be. Measured in `test/probe_backdrop_edge.dart` as a
/// flat delta of 66 from the tint across every pixel outside the box, against
/// 0 once the clip is tight.
///
/// The tile mode is measured too, at the top edge where the card's own
/// boundary cuts the artwork: `decal` ramps in from 37 to 69 over ~10 px —
/// the tint showing through where artwork should be, which is the "shadow"
/// this started as — while `clamp` holds 69 from the first row.
class _ArtworkBleed extends StatelessWidget {
  const _ArtworkBleed({required this.backdropUrl});

  final String? backdropUrl;

  @override
  Widget build(BuildContext context) {
    final url = backdropUrl;
    if (url == null || url.isEmpty) return const SizedBox.shrink();

    // Extracted into a variable so we can safely stack it twice
    // without duplicating the configuration. Flutter's ImageCache
    // prevents this from actually downloading or decoding twice.
    final rawImage = Image.network(
      url,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      // A failed decode leaves the flat tint, which is a perfectly
      // good panel — never a broken-image glyph across the hero.
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    return IgnorePointer(
      child: FractionallySizedBox(
        alignment: Alignment.topRight,
        widthFactor: 0.452,
        // Only the header band, so the strip never washes over the video
        // shelf below it.
        heightFactor: 0.452,
        child: ClipRect(
          // Two nested masks, because a `ShaderMask` takes one shader and this
          // corner needs two axes: fade out downward into the tint, and fade
          // out leftward before it reaches the artist's name.
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF000000), Color(0x00000000)],
              stops: [0.45, 1.0],
            ).createShader(bounds),
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0x00000000), Color(0xB0000000)],
                stops: [0.0, 0.75],
              ).createShader(bounds),
              // Replaced the single ImageFiltered with a Stack
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // BACKGROUND: The completely blurred image
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: 4,
                      sigmaY: 4,
                      tileMode: TileMode.clamp, // Preserved to prevent edge-leakage
                    ),
                    child: rawImage,
                  ),
                  // FOREGROUND: The clear image, masked radially so it's
                  // opaque in the center and transparent at the edges.
                  ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (bounds) => const RadialGradient(
                      center: Alignment.center,
                      radius: 0.75, // Controls how far out the gradient reaches
                      colors: [Color(0xFF000000), Color(0x00000000)],
                      // Solid clear until 20%, then ramps to 100% blurred at the edge
                      stops: [0.2, 1.0], 
                    ).createShader(bounds),
                    child: rawImage,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How the header's two columns divide the space the avatar and gaps leave.
///
/// Named rather than inline so the regression test can assert the split
/// without hardcoding it a second time: these are a design dial, and a test
/// that restates their values goes red every time the dial moves, which
/// teaches everyone to edit the test rather than read it. What the test
/// actually guards is that the two are *unequal* — `Flexible` and `Expanded`
/// both default to `flex: 1`, and an even split is what forced the action
/// pills onto a second row with the panel half empty.
const int kArtistIdentityFlex = 2;
const int kArtistActionsFlex = 4;

/// The height every pill in the action row lays out at.
const double kArtistActionHeight = 44;

class _Header extends StatelessWidget {
  const _Header({
    required this.artist,
    required this.tint,
    required this.onSubscribe,
    required this.onUnsubscribe,
    required this.onNotImplemented,
  });

  final ArtistPanel artist;
  final ArtistPanelTint tint;
  final Future<bool> Function(String channelId) onSubscribe;
  final Future<bool> Function(String channelId) onUnsubscribe;
  final VoidCallback onNotImplemented;

  @override
  Widget build(BuildContext context) {
    final metadata = [
      if (artist.handle != null) artist.handle!,
      if (artist.subscriberText != null) artist.subscriberText!,
      if (artist.videoCountText != null) artist.videoCountText!,
    ].join(' • ');

    return LayoutBuilder(
      builder: (context, constraints) {
        // Below this width the description can no longer sit beside the name
        // without both truncating to uselessness, so it drops under the
        // metadata line instead.
        final isWide = constraints.maxWidth >= 720;

        final description = artist.description == null || artist.description!.isEmpty
            ? null
            : Text(
                artist.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tint.onSurfaceMuted, fontSize: 13, height: 1.35),
              );

        final identity = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                      color: tint.onSurface,
                    ),
                  ),
                ),
                ChannelBadge(
                  channelId: artist.channelId,
                  isArtistChannel: true,
                  isVerified: false,
                  size: 18,
                  paddingLeft: 8,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              metadata,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tint.onSurfaceMuted, fontSize: 13),
            ),
          ],
        );

        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SubscribeButton(
              key: ValueKey(artist.channelId),
              channelId: artist.channelId,
              initiallySubscribed: artist.isSubscribed,
              onSubscribe: onSubscribe,
              onUnsubscribe: onUnsubscribe,
              // The pill's own defaults are the app's surface roles, which
              // are invisible against an arbitrary artist tint.
              foreground: tint.onSurface,
              background: tint.onSurface.withValues(alpha: 0.16),
              unsubscribedForeground: tint.surface,
              unsubscribedBackground: tint.onSurface,
              dense: true,
              minHeight: kArtistActionHeight,
              textStyle: kArtistActionTextStyle,
            ),
            _TintedAction(tint: tint, label: 'View Channel', onPressed: onNotImplemented),
            if (artist.mixPlaylistId != null)
              _TintedAction(
                tint: tint,
                label: 'Mix',
                icon: Icons.podcasts,
                onPressed: onNotImplemented,
              ),
            _TintedAction(
              tint: tint,
              label: 'YouTube Music',
              icon: Icons.play_circle_outline,
              onPressed: onNotImplemented,
            ),
          ],
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            CircleAvatar(
              radius: 44,
              backgroundColor: tint.onSurface.withValues(alpha: 0.10),
              backgroundImage: artist.avatarUrl.isEmpty ? null : NetworkImage(artist.avatarUrl),
              onBackgroundImageError: artist.avatarUrl.isEmpty ? null : (error, stackTrace) {},
              child: artist.avatarUrl.isEmpty
                  ? Icon(Icons.person, size: 44, color: tint.onSurfaceMuted)
                  : null,
            ),
            const SizedBox(width: 20),
            if (isWide) ...[
              // **A fixed 2:3 split of whatever the avatar and gaps leave.**
              //
              // The weights are the whole point. `Flexible` and `Expanded`
              // both default to `flex: 1`, so a pair of them divides the row
              // exactly in half no matter what either side wants — which is
              // what forced the action pills onto a second row while hundreds
              // of pixels sat idle under the much narrower name block.
              //
              // 2:3 gives the actions half again what an even split would,
              // comfortably more than one row of pills needs at the panel's
              // full width, and keeps both columns at a proportion that does
              // not move with the length of an artist's name or description.
              Expanded(flex: kArtistIdentityFlex, child: identity),
              const SizedBox(width: 32),
              Expanded(
                flex: kArtistActionsFlex,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (description != null) ...[
                      description,
                      const SizedBox(height: 10),
                    ],
                    actions,
                  ],
                ),
              ),
            ] else
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    identity,
                    if (description != null) ...[
                      const SizedBox(height: 8),
                      description,
                    ],
                    const SizedBox(height: 14),
                    actions,
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// An outlined pill that reads against the artist's colour instead of the
/// app's — every action here sits on a surface the theme knows nothing about.
class _TintedAction extends StatelessWidget {
  const _TintedAction({
    required this.tint,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final ArtistPanelTint tint;
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      foregroundColor: tint.onSurface,
      side: BorderSide(color: tint.outline),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      minimumSize: const Size(0, kArtistActionHeight),
      // Material pads a button's *layout* box out to a 48 px touch target,
      // which is why these sat noticeably chunkier than the reference despite
      // asking for 36. Dropping the pad is a pointer-only concession and the
      // pill is still 36 px tall, well over what a mouse needs.
      //
      // Deliberately *not* also squeezing the density or the type scale: four
      // pills measure ~470 px with the real font, against roughly 500 on
      // youtube.com, so there was never width to claw back here. (A probe run
      // under `flutter test` says 714 — that is the Ahem test font, whose
      // glyphs are all a full em square, not the shipped metrics.)
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: kArtistActionTextStyle,
    );

    if (icon == null) {
      return OutlinedButton(onPressed: onPressed, style: style, child: Text(label));
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

/// Shared by [_TintedAction] and the panel's [SubscribeButton] so the pills in
/// one row cannot drift apart in size. See [_TintedAction] for why it is
/// tighter than the Material default.
const TextStyle kArtistActionTextStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
);

/// The panel's embedded top-videos carousel.
///
/// A fixed-height horizontal strip, sized the same way `feed_view.dart`'s
/// Shorts shelf is: [MediaTile] puts a `LayoutBuilder` at the root of its own
/// build, and a `LayoutBuilder` cannot answer an intrinsic-height query — so
/// the height here has to be computed, never measured off the children.
class _Shelf extends ConsumerWidget {
  const _Shelf({
    required this.items,
    required this.tint,
    required this.controller,
    required this.onNudge,
  });

  final List<FeedItem> items;
  final ArtistPanelTint tint;
  final ScrollController controller;
  final void Function(int direction) onNudge;

  /// Height of a standard tile's metadata block, measured rather than
  /// guessed — `test/probe_tile_height.dart` renders a real [MediaTile] under
  /// an unbounded constraint and reports it. A `LayoutBuilder` at the tile's
  /// root means this cannot be asked for at layout time, which is the whole
  /// reason it is a constant here.
  ///
  /// Two lines of title is the maximum because [MediaTile] caps it there, so
  /// this is a ceiling and not an average: 93.5 measured at every width from
  /// 180 to 320.
  static const double _metadataHeight = 93.5;

  /// What a badge row adds on top of it — measured at exactly 22.0, constant
  /// across widths. Applied only when an item actually carries badges, since
  /// reserving it unconditionally would leave dead space under every tile in
  /// the common case (the artist shelf usually carries none).
  static const double _badgeRowHeight = 22.0;

  /// Breathing room above and below the strip — and it lives **inside** the
  /// scroll viewport, as the list's own padding, rather than outside it.
  ///
  /// That is the whole point rather than a detail: a hovered [MediaTile]
  /// grows past its own bounds (measured 10 px up, 4 px down, 10 px each
  /// side), and a `ListView` clips to its viewport. Spacing the strip with an
  /// outer `Padding` therefore looks identical at rest and shears the top off
  /// every hover animation — which is exactly what it did. Inside the
  /// viewport the tile has somewhere to grow into, so this has to stay
  /// comfortably above that 10.
  static const double _shelfInset = 22.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final specs = [for (final item in items) specFor(item)];
    final hasBadges = specs.any((spec) => spec != null && spec.badges.isNotEmpty);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Roughly three tiles across, bounded so the strip turns neither into
        // thumbnails on a wide window nor a single tile on a narrow one.
        final double itemWidth = (constraints.maxWidth / 3.2).clamp(180.0, 320.0);
        final double thumbnailHeight = itemWidth / ScreenValues.normalAspectRatio;
        final double itemHeight =
            thumbnailHeight + _metadataHeight + (hasBadges ? _badgeRowHeight : 0);

        return SizedBox(
          height: itemHeight + _shelfInset * 2,
          child: Stack(
            children: [
              Positioned.fill(
                child: SilkyListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 20, right: 20, top: _shelfInset, bottom: 14.0),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final spec = specs[index];
                    if (spec == null) return const SizedBox.shrink();
        
                    return Padding(
                      padding: EdgeInsets.only(right: index == items.length - 1 ? 0 : 16),
                      child: SizedBox(
                        width: itemWidth,
                        child: MediaTile(
                          spec: spec,
                          onTap: watchTargetFor(item) == null ? null : () => openFromTile(ref, item),
                          onAddToQueue: () => queueFromTile(ref, item),
                          onWatchLater: () => addToWatchLater(context, item),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // Centred on the thumbnail, not on the strip — the metadata
              // block below the thumbnail would otherwise drag the chevron
              // visibly low.
              Positioned(
                right: 6,
                top: _shelfInset,
                height: thumbnailHeight,
                child: Center(
                  child: _ShelfChevron(tint: tint, onPressed: () => onNudge(1)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ShelfChevron extends StatelessWidget {
  const _ShelfChevron({required this.tint, required this.onPressed});

  final ArtistPanelTint tint;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tint.surface.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(Icons.chevron_right, size: 22, color: tint.onSurface),
        ),
      ),
    );
  }
}
