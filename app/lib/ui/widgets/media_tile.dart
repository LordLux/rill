import 'dart:async';

import 'package:flutter/material.dart';
import 'tile_badges.dart';
import '../../domain/feed_item.dart';
import '../../theme/screen_values.dart';
import '../../theme/tokens.dart';
import '../hover_preview.dart';
import 'channel_badge.dart';
import '../open_video.dart';

// ---- TEMPORARY: unfed tile slots ----
// Master switch to turn off all placeholder elements at once
const bool tmpShowPlaceholders = false;

// waiting on: percentDurationWatched extracted in the sidecar parser, added to the DTO in docs/protocol.md, and a corpus re-export
const double tmpProgressBarValue = 0.65;

// waiting on: menu items data from DTO
const List<String> tmpMenuContents = [];

// The stacked-card colours moved to `theme/tokens.dart` as
// `stackedCardBack`/`stackedCardFront`, still waiting on palette extraction from
// the thumbnail, cached off the UI isolate.
// -------------------------------------

/// `mix` is the odd one out: the others describe a *duration*, and a mix has
/// none — it is a list whose length changes as it extends. It reuses this enum
/// because it occupies the same corner of the thumbnail and nothing else about
/// the badge differs.
enum DurationBadgeTone { normal, live, music, station, mix }

/// The reminder CTA on a premiere tile.
const Key tileNotifyKey = ValueKey('tile-notify');

/// `Notify me` — with the date when the card is wide enough to carry it.
///
/// Short by design: this sits under a channel name in a grid column, and the
/// long form ("Premieres 22/8/2026 at 15:00") is the watch page's job, where
/// there is room for it to be the headline rather than a button label.
String tilePremiereLabel(int premiereAtMs) {
  final at = DateTime.fromMillisecondsSinceEpoch(premiereAtMs).toLocal();
  final minute = at.minute.toString().padLeft(2, '0');
  return 'Notify me • ${at.day}/${at.month} ${at.hour}:$minute';
}

class TileSpec {
  final String title;
  final String thumbnailUrl;

  /// The video whose storyboard this tile previews on hover, or null for a tile
  /// with nothing to preview.
  ///
  /// Deliberately the same derivation as [watchTargetFor]: a mix previews its
  /// seed video because that is what the tile opens, and a playlist previews
  /// nothing because it opens nothing. A tile that previewed one video and
  /// opened another would be worse than a tile that previews nothing.
  final String? previewVideoId;

  // top slots
  final bool isStackedCards;
  final bool isShort;
  final String? durationText;
  final DurationBadgeTone durationTone;
  final List<String> badges;

  /// Members-only content — drives the green pill. A flag rather than a
  /// [badges] entry, because the label is localised and the style is not.
  final bool isMembersOnly;
  final bool canWatchLater;
  final bool canAddToQueue;

  /// When this video premieres, unix ms — null for everything already out.
  ///
  /// Drives the reminder CTA at the foot of the card. A tile carries this from
  /// the feed response itself, so a grid of premieres costs no extra request.
  final int? premiereAtMs;

  // bottom slots
  final String? avatarUrl;
  final String primaryLine;
  final String? secondaryLine;
  final String? descriptionSnippet;

  /// The uploading channel's verified checkmark, shown beside [primaryLine].
  /// Never true alongside [isArtistChannel] — YouTube ships one badge per
  /// channel.
  final bool isVerified;

  /// The uploading channel's "Official Artist Channel" badge.
  final bool isArtistChannel;

  /// The uploading channel's id, where the item has one — the key
  /// `ChannelBadge` caches the verified observation under. Null for mix and
  /// playlist tiles, whose `primaryLine` is a subtitle or an owner name with
  /// no id attached.
  final String? channelId;

  const TileSpec({
    required this.title,
    required this.thumbnailUrl,
    this.previewVideoId,
    required this.isStackedCards,
    this.isShort = false,
    this.durationText,
    required this.durationTone,
    required this.badges,
    this.isMembersOnly = false,
    required this.canWatchLater,
    required this.canAddToQueue,
    this.premiereAtMs,
    this.avatarUrl,
    required this.primaryLine,
    this.secondaryLine,
    this.descriptionSnippet,
    this.isVerified = false,
    this.isArtistChannel = false,
    this.channelId,
  });
}

/// The duration text for a video tile's badge — `null` while live, or when
/// YouTube gave no duration at all (a mix's synthetic seed-video entry, for
/// instance).
String? formatVideoDuration(VideoItem v) {
  if (v.isLive || v.durationSeconds == null) return null;
  final d = Duration(seconds: v.durationSeconds!);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Which badge a video tile draws — station and live share a look but not a
/// label (architecture.md F22).
DurationBadgeTone durationToneFor(VideoItem v) {
  if (v.isStation) return DurationBadgeTone.station;
  if (v.isLive) return DurationBadgeTone.live;
  if (v.isMusic) return DurationBadgeTone.music;
  return DurationBadgeTone.normal;
}

TileSpec? specFor(FeedItem item) {
  return item.map(
    video: (v) {
      return TileSpec(
        title: v.title,
        thumbnailUrl: v.thumbnailUrl,
        previewVideoId: v.id.isEmpty ? null : v.id,
        isStackedCards: false,
        isShort: v.isShort,
        durationText: formatVideoDuration(v),
        durationTone: durationToneFor(v),
        badges: v.badges,
        isMembersOnly: v.isMembersOnly,
        canWatchLater: v.canWatchLater,
        canAddToQueue: v.canAddToQueue,
        premiereAtMs: v.premiereAtMs,
        avatarUrl: v.channelAvatarUrl,
        primaryLine: v.channelName,
        secondaryLine: v.isShort
            ? v.viewCountText
            : ((v.viewCountText != null || v.publishedText != null)
                  ? '${v.viewCountText ?? ''}${v.viewCountText != null && v.publishedText != null ? ' • ' : ''}${v.publishedText ?? ''}'
                        .trim()
                  : null),
        descriptionSnippet: v.descriptionSnippet,
        isVerified: v.isVerified,
        isArtistChannel: v.isArtistChannel,
        channelId: v.channelId,
      );
    },
    mix: (m) => TileSpec(
      title: m.title,
      thumbnailUrl: m.thumbnailUrl,
      // The song the tile advertises, carried rather than derived — the
      // thumbnail-URL guess (`mixSeedVideoId`) that used to fill this is gone.
      // Null only for a tile with no click target, which keeps its still.
      previewVideoId: m.seedVideoId,
      isStackedCards: true,
      isShort: false,
      // A mix tile usually carries no count at all — YouTube ships the literal
      // word "Mix" where a playlist ships "24 videos" — so the badge is drawn
      // from the tone rather than from text that is normally absent.
      durationText: m.videoCount != null ? '${m.videoCount} videos' : null,
      durationTone: DurationBadgeTone.mix,
      badges: const [],
      canWatchLater: false,
      canAddToQueue: false,
      avatarUrl: null,
      primaryLine: m.subtitle ?? '',
      secondaryLine: null,
    ),
    playlist: (p) => TileSpec(
      title: p.title,
      thumbnailUrl: p.thumbnailUrl,
      isStackedCards: true,
      isShort: false,
      durationText: p.videoCount != null ? '${p.videoCount} videos' : null,
      durationTone: DurationBadgeTone.normal,
      badges: const [],
      canWatchLater: false,
      canAddToQueue: false,
      avatarUrl: null,
      primaryLine: p.channelName ?? '',
      secondaryLine: null,
    ),
    channel: (c) => null,
    unknown: (u) => null,
  );
}

enum MediaTileLayout { standard, wide, shorts }

enum MediaTileSize { standard, large }

class MediaTile extends StatefulWidget {
  final TileSpec spec;
  final MediaTileLayout layout;
  final MediaTileSize size;

  /// Opens the tile. Null for a kind that cannot be watched — a playlist is
  /// explicitly out of scope for now, and an inert tile is better than a route
  /// to nothing.
  final VoidCallback? onTap;

  /// The two hover actions. Both sit inside `IconButton`s, which win the gesture
  /// arena against the tile behind them — so pressing one does not also navigate
  /// (task §6). That is asserted in `media_tile_tap_test.dart` as behaviour,
  /// because "the arena handles it" is exactly the kind of thing that stops
  /// being true after an innocent-looking wrapper is added.
  final VoidCallback? onWatchLater;
  final VoidCallback? onAddToQueue;

  /// The 3-dot menu (Task 25 §5: "the tile's 3-dot menu... opens this" — the
  /// save-to-playlist dialog). Null renders the icon disabled rather than
  /// absent, so a tile whose kind has nothing to offer there does not shift
  /// its neighbours' layout.
  final VoidCallback? onMore;

  const MediaTile({
    super.key,
    required this.spec,
    this.onTap,
    this.onWatchLater,
    this.onAddToQueue,
    this.onMore,
  }) : layout = MediaTileLayout.standard,
       size = MediaTileSize.standard;

  const MediaTile.wide({
    super.key,
    required this.spec,
    this.onTap,
    this.onWatchLater,
    this.onAddToQueue,
    this.onMore,
    this.size = MediaTileSize.standard,
  }) : layout = MediaTileLayout.wide;

  const MediaTile.shorts({
    super.key,
    required this.spec,
    this.onTap,
    this.onWatchLater,
    this.onAddToQueue,
    this.onMore,
  }) : layout = MediaTileLayout.shorts,
       size = MediaTileSize.standard;

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  bool isHovering = false;
  bool isHoveringThumbnail = false;

  /// This tile's preview slot. The shared [HoverPreview] writes to at most one across the grid,
  /// so a running preview rebuilds one builder rather than every tile on screen.
  final PreviewSink _slot = PreviewSink(null);

  /// Null outside a [HoverPreviewScope], which disables previews entirely.
  HoverPreview? _preview;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = HoverPreviewScope.maybeOf(context);
    if (identical(next, _preview)) return;
    _stopPreview();
    _preview = next;
  }

  @override
  void didUpdateWidget(MediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.spec.previewVideoId;
    if (previous == widget.spec.previewVideoId) return;

    // A recycled tile is a different video in the same element. Stop the **old** one by id:
    // `didUpdateWidget` runs after `widget` is swapped, so passing the new id makes `exit` bail
    // early and leaves the previous video decoding forever.
    _stopPreview(videoId: previous);

    // The pointer never left, so no `onEnter` is coming. Without this the tile under a
    // stationary cursor sits inert until the user moves off and back on.
    _wantsPreview = false;
    _updatePreviewState();
  }

  @override
  void dispose() {
    _previewStateTimer?.cancel();
    _stopPreview();
    _slot.dispose();
    super.dispose();
  }

  void _stopPreview({String? videoId}) {
    final id = videoId ?? widget.spec.previewVideoId;
    if (id != null) _preview?.exit(id);
    _slot.value = null;
  }

  bool isHoveringButtons = false;
  bool _wantsPreview = false;
  Timer? _previewStateTimer;

  void _updatePreviewState() {
    _previewStateTimer?.cancel();
    _previewStateTimer = Timer(const Duration(milliseconds: 50), () {
      if (!mounted) return;

      final bool isActuallyPlaying = _isPreviewing(_slot.value);
      final bool shouldPlay =
          isHoveringThumbnail || (isHoveringButtons && isActuallyPlaying);

      if (shouldPlay && !_wantsPreview) {
        _wantsPreview = true;
        final videoId = widget.spec.previewVideoId;
        if (videoId != null) _preview?.enter(videoId, _slot);
      } else if (!shouldPlay && _wantsPreview) {
        _wantsPreview = false;
        _stopPreview();
      }
    });
  }

  void _onEnterTile() {
    setState(() => isHovering = true);
  }

  void _onExitTile() {
    setState(() => isHovering = false);
    _wantsPreview = false;
    _stopPreview();
  }

  void _onEnterPreview() {
    isHoveringThumbnail = true;
    _updatePreviewState();
  }

  void _onExitPreview() {
    isHoveringThumbnail = false;
    _updatePreviewState();
  }

  /// A preview with a picture on screen — the state the tile's chrome reacts to.
  static bool _isPreviewing(PreviewSession? session) =>
      session != null && session.visible;

  /// One hover button. Scrim rather than a surface role: it sits over an arbitrary thumbnail.
  Widget _hoverButton({
    required RillTokens tokens,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      style: IconButton.styleFrom(
        backgroundColor: tokens.scrim.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      hoverColor: tokens.scrim,
      mouseCursor: SystemMouseCursors.click,
      tooltip: tooltip,
      icon: Icon(icon, color: tokens.onScrim, size: 23),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }

  /// The duration / LIVE / STATION pill. Scrim family rather than a surface
  /// role: it sits over an arbitrary thumbnail.
  ///
  /// STATION shares LIVE's red background and broadcast icon — a station is
  /// `isLive: true` underneath (architecture.md F22) and reads the same way
  /// at a glance — but draws its own text, since that is the one thing about
  /// it worth telling apart from an ordinary live stream.
  Widget _durationBadge(RillTokens tokens) {
    final isLive = widget.spec.durationTone == DurationBadgeTone.live;
    final isStation = widget.spec.durationTone == DurationBadgeTone.station;
    final isLiveLike = isLive || isStation;
    final isMix = widget.spec.durationTone == DurationBadgeTone.mix;
    final badgeText = _getBadgeText(isStation, isLive, isMix);
    return Container(
      padding: const EdgeInsets.only(
        left: 4.5,
        right: 4.5,
        bottom: .75,
        top: .5,
      ),
      decoration: BoxDecoration(
        color: isLiveLike
            ? tokens.liveBadge.withValues(alpha: 0.8)
            : tokens.scrim.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMix)
            Padding(
              // No right padding when the badge is icon-only, which is the
              // usual case for a mix.
              padding: EdgeInsets.only(right: badgeText.isEmpty ? 0 : 4.0),
              child: Icon(Icons.playlist_play, size: 14, color: tokens.onScrim),
            )
          else if (isLiveLike)
            Padding(
              padding: const EdgeInsets.only(right: 4.0),
              child: Icon(Icons.sensors, size: 12, color: tokens.onScrim),
            )
          else if (widget.spec.durationTone == DurationBadgeTone.music)
            Padding(
              padding: const EdgeInsets.only(right: 2.0),
              child: Transform.translate(
                offset: const Offset(-1, 0.25),
                  child: Icon(Icons.music_note, size: 11, color: tokens.onScrim,
                )
              ),
            ),
          if (badgeText.isNotEmpty)
            Text(
              badgeText,
              style: TextStyle(
                color: tokens.onScrim,
                fontSize: 11.2,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w500,
                height: 1.6,
              ),
            ),
        ],
      ),
    );
  }

  String _getBadgeText(bool isStation, bool isLive, bool isMix) {
    if (isStation) return 'STATION';
    if (isLive) return 'LIVE';
    if (isMix) return 'Mix';
    return widget.spec.durationText ?? '';
  }

  /// The top-right hover cluster: mute and CC while previewing, Watch Later and Add to
  /// queue otherwise. Not both — three buttons over a 16:9 thumbnail is a toolbar, and the
  /// previewing branch stays at two for the same reason.
  ///
  /// CC is drawn only when the preview's video has a track, which the sidecar answers from a
  /// `/player` response the preload already cached (`protocol.md` §3.8, `allowFallback: false`)
  /// — so a pointer sweeping the grid costs no request. A preview is muted, which makes
  /// captions the control that decides whether it is legible at all.
  Widget _hoverActions(RillTokens tokens, PreviewSession? session) {
    final playing = _isPreviewing(session) ? session! : null;
    final showsAnything =
        playing != null ||
        widget.spec.canWatchLater ||
        widget.spec.canAddToQueue;
    if (!showsAnything) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: isHovering ? 1 : 0,
      duration: const Duration(milliseconds: 100),
      child: IgnorePointer(
        // Faded-out buttons must not swallow clicks meant for the tile underneath.
        ignoring: !isHovering,
        child: Column(
          children: playing != null
              ? [
                  _hoverButton(
                    tokens: tokens,
                    icon: playing.muted ? Icons.volume_off : Icons.volume_up,
                    tooltip: playing.muted ? 'Unmute preview' : 'Mute preview',
                    onPressed: () => unawaited(_preview!.toggleMute()),
                  ),
                  if (playing.captionTrack != null) ...[
                    const SizedBox(height: 8.0),
                    _hoverButton(
                      tokens: tokens,
                      icon: playing.captionsOn
                          ? Icons.closed_caption
                          : Icons.closed_caption_outlined,
                      tooltip: playing.captionsOn
                          ? 'Hide captions'
                          : 'Show captions',
                      onPressed: () => unawaited(_preview!.toggleCaptions()),
                    ),
                  ],
                ]
              : [
                  if (widget.spec.canWatchLater) ...[
                    _hoverButton(
                      tokens: tokens,
                      icon: Icons.schedule,
                      tooltip: 'Watch later',
                      onPressed: widget.onWatchLater,
                    ),
                    const SizedBox(height: 8.0),
                  ],
                  if (widget.spec.canAddToQueue)
                    _hoverButton(
                      tokens: tokens,
                      icon: Icons.playlist_play,
                      tooltip: 'Add to queue',
                      onPressed: widget.onAddToQueue,
                    ),
                ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = theme.tokens;

    // Thumbnail area
    Widget topArea({bool isShort = false}) => AspectRatio(
      aspectRatio: isShort
          ? ScreenValues.shortAspectRatioSecondary
          : ScreenValues.normalAspectRatio,
      child: Padding(
        padding: EdgeInsets.zero,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Stacked cards for Mixes
            if (widget.spec.isStackedCards) ...[
              AnimatedPositioned(
                duration: const Duration(milliseconds: 100),
                top: isHovering ? -14 : -8,
                left: 24,
                right: 24,
                bottom: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: tokens.stackedCardBack,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 100),
                top: isHovering ? -7 : -4,
                left: 12,
                right: 12,
                bottom: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: tokens.stackedCardFront,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
            // Thumbnail image and overlays
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // MouseRegion for preview that covers the background
                    Positioned.fill(
                      child: MouseRegion(
                        onEnter: (_) => _onEnterPreview(),
                        onExit: (_) => _onExitPreview(),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Thumbnail image. `cover` unconditionally: YouTube's
                            // own thumbnail for a Short is a 16:9 canvas with the
                            // real 9:16 video pillarboxed inside it (coloured/
                            // blurred fill either side), and `cover` into the
                            // `shortAspectRatioSecondary` box above crops *some*
                            // of that fill — but a landscape-into-portrait cover
                            // crop alone is not tight enough to remove it (see
                            // `shortThumbnailZoom`'s doc for the measured
                            // numbers). The extra `Transform.scale` for Shorts is
                            // what actually does that — a paint-time transform,
                            // not a relayout or a second image load, and the
                            // surrounding `ClipRRect` already clips the overflow
                            // it produces.
                            Transform.scale(
                              scale: isShort
                                  ? ScreenValues.shortThumbnailZoom
                                  : 1.0,
                              child: Image.network(
                                widget.spec.thumbnailUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                      color: scheme.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.image,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                              ),
                            ),
                            // The hover preview, over the thumbnail and under the chrome (§2.6).
                            //
                            // Mounted as soon as there is a session and hidden until the first frame, rather
                            // than unmounted: media_kit sizes its native VideoOutput from the mounted
                            // texture, so a surface never in the tree can leave mpv rendering into 0×0.
                            // `Opacity` keeps the child laid out and skips only the paint.
                            Positioned.fill(
                              child: ValueListenableBuilder<PreviewSession?>(
                                valueListenable: _slot,
                                builder: (context, session, _) {
                                  if (session == null) return const SizedBox.shrink();

                                  return Opacity(
                                    opacity: session.visible ? 1 : 0,
                                    // `cover` matches the `Image.network` underneath, so the swap does not reframe the picture
                                    child: RepaintBoundary(
                                      child: session.engine.videoSurface(
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Duration badge — hidden while a preview is playing: it describes the
                    // thumbnail, and over a running video it is stale chrome.
                    if (widget.spec.durationText != null ||
                        widget.spec.durationTone == DurationBadgeTone.live ||
                        widget.spec.durationTone == DurationBadgeTone.station ||
                        widget.spec.durationTone == DurationBadgeTone.mix)
                      Positioned(
                        bottom: 6,
                        right: 6,
                        child: IgnorePointer(
                          child: ValueListenableBuilder<PreviewSession?>(
                            valueListenable: _slot,
                            builder: (context, session, child) =>
                                _isPreviewing(session)
                                ? const SizedBox.shrink()
                                : child!,
                            child: _durationBadge(tokens),
                          ),
                        ),
                      ),

                    // Progress bar
                    if (tmpShowPlaceholders && tmpProgressBarValue > 0)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 4,
                        child: IgnorePointer(
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: tmpProgressBarValue,
                            // The watched-progress bar is one of the places the
                            // accent belongs (§3.3).
                            child: Container(color: scheme.primary),
                          ),
                        ),
                      ),

                    // Watch Later + Add to Queue — or, while a preview is
                    // playing, the mute toggle that replaces them.
                    Positioned(
                      top: 8,
                      right: 8,
                      child: MouseRegion(
                        onEnter: (_) {
                          isHoveringButtons = true;
                          _updatePreviewState();
                        },
                        onExit: (_) {
                          isHoveringButtons = false;
                          _updatePreviewState();
                        },
                        child: ValueListenableBuilder<PreviewSession?>(
                          valueListenable: _slot,
                          builder: (context, session, _) =>
                              _hoverActions(tokens, session),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Metadata area
    Widget bottomArea({bool showAvatar = true}) {
      showAvatar = showAvatar && !widget.spec.isShort;
      if (widget.size == MediaTileSize.large) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // Title + 3 dot menu
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topLeft,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 28.0, top: 4.0),
                    child: Text(
                      widget.spec.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w400,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -1,
                  right: -2,
                  child: IconButton(
                    icon: Icon(
                      Icons.more_vert,
                      size: 21,
                      color: scheme.onSurface,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    mouseCursor: SystemMouseCursors.click,
                    onPressed: widget.onMore,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            // Views + date
            if (widget.spec.secondaryLine != null &&
                widget.spec.secondaryLine!.isNotEmpty)
              Text(
                widget.spec.secondaryLine!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            if (!widget.spec.isShort) ...[
              const SizedBox(height: 12),
              // Channel Avatar + Name
              Row(
                children: [
                  if (widget.spec.avatarUrl != null && showAvatar)
                    CircleAvatar(
                      radius: 12,
                      backgroundImage: NetworkImage(widget.spec.avatarUrl!),
                      onBackgroundImageError: (error, stackTrace) {},
                    )
                  else if (showAvatar)
                    const CircleAvatar(
                      radius: 12,
                      child: Icon(Icons.person, size: 16),
                    ),
                  SizedBox(width: showAvatar ? 8 : 0),
                  Flexible(
                    child: Text(
                      widget.spec.primaryLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: const Offset(0, 1),
                    child: ChannelBadge(
                      channelId: widget.spec.channelId,
                      isArtistChannel: widget.spec.isArtistChannel,
                      isVerified: widget.spec.isVerified,
                      paddingLeft: 4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            // Description snippet
            if (widget.spec.descriptionSnippet != null &&
                widget.spec.descriptionSnippet!.isNotEmpty)
              Text(
                widget.spec.descriptionSnippet!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            TileBadges(
              badges: widget.spec.badges,
              isMembersOnly: widget.spec.isMembersOnly,
            ),
          ],
        );
      }

      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Channel avatar
          if (widget.spec.avatarUrl != null && showAvatar)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: CircleAvatar(
                radius: 18,
                backgroundImage: NetworkImage(widget.spec.avatarUrl!),
                onBackgroundImageError: (error, stackTrace) {},
              ),
            )
          else if (!widget.spec.isStackedCards && showAvatar)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: const CircleAvatar(
                radius: 18,
                child: Icon(Icons.person, size: 20),
              ),
            ),

          SizedBox(
            width: widget.spec.isStackedCards || !showAvatar ? 0 : 12,
          ), // Separator if channel avatar is present
          // Title + primary/secondary lines + 3 dot menu
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title + trailing 3 dot menu
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.topLeft,
                  children: [
                    // Title text
                    SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 28.0, top: 0.0),
                        child: Text(
                          widget.spec.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: widget.spec.isShort ? 16 : 14,
                            fontWeight: widget.spec.isShort
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                    // 3-dot menu icon
                    Positioned(
                      top: -1,
                      right: -4,
                      child: IconButton(
                        icon: Icon(
                          Icons.more_vert,
                          size: 21,
                          color: scheme.onSurface,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        mouseCursor: SystemMouseCursors.click,
                        onPressed: widget.onMore,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1.5),
                // Channel name
                if (!widget.spec.isShort)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.spec.primaryLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      ChannelBadge(
                        channelId: widget.spec.channelId,
                        isArtistChannel: widget.spec.isArtistChannel,
                        isVerified: widget.spec.isVerified,
                        paddingLeft: 4,
                      ),
                    ],
                  ),
                // Secondary line (view count + published date)
                if (widget.spec.secondaryLine != null &&
                    widget.spec.secondaryLine!.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: widget.spec.isShort ? 2.0 : 2.0,
                    ),
                    child: Text(
                      widget.spec.secondaryLine!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: widget.spec.isShort ? 13 : 12,
                      ),
                    ),
                  ),
                TileBadges(
                  badges: widget.spec.badges,
                  isMembersOnly: widget.spec.isMembersOnly,
                  topPadding: 4.0,
                ),
                // **The premiere CTA, at the foot of the card.**
                //
                // Disabled, like the watch page's: the affordance is real, the
                // reminder is not wired to YouTube yet, and a button that looks
                // like it worked and did nothing is the worse of the two.
                //
                // Full width rather than tucked beside the metadata, because it is
                // the only thing on this tile that is not describing the video —
                // and because the grid's tiles are narrow enough that a button
                // sharing a row with a channel name would truncate one of them.
                if (widget.spec.premiereAtMs != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: tileNotifyKey,
                        onPressed: null,
                        icon: const Icon(Icons.notifications_none, size: 16),
                        label: Text(
                          tilePremiereLabel(widget.spec.premiereAtMs!),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    // `onExit` fires when the pointer leaves *this* region, and a nested
    // `MouseRegion` — the two action buttons are inside `IconButton`s, which
    // have one — does not trigger it. That is what keeps hovering Watch Later
    // from stopping the preview, and it is asserted rather than assumed.
    return LayoutBuilder(
      builder: (context, constraints) {
        final (Widget layout, bool isEffectiveWide) = _getTileLayout(
          constraints,
          topArea,
          bottomArea,
        );
        final bool isShort = widget.spec.isShort || widget.layout == MediaTileLayout.shorts;
        final EdgeInsets hoverExpansion = isHovering
            ? isShort
                  ? EdgeInsets.all(-10.0).copyWith(top: -9.0) // Shorts
                  : widget.layout == MediaTileLayout.standard
                      ? EdgeInsets.symmetric(horizontal: -10.0).copyWith(top: -9.0, bottom: -4.0) // Standard
                      : EdgeInsets.all(-4.0) // Wide
            : EdgeInsets.zero;

        return MouseRegion(
          onEnter: (_) => _onEnterTile(),
          onExit: (_) => _onExitTile(),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            // Opaque so the whole tile — including the gaps between its children —
            // is a target. `deferToChild` would leave the padding dead, which reads
            // as a tile that only sometimes opens.
            behavior: HitTestBehavior.opaque,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 100),
                  curve: Curves.easeInOut,
                  top: hoverExpansion.top,
                  bottom: hoverExpansion.bottom,
                  left: hoverExpansion.left,
                  right: hoverExpansion.right,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    curve: Curves.easeInOut,
                    decoration: BoxDecoration(
                      color: isHovering
                          ? scheme.surfaceContainerHighest.withValues(alpha: 0.75)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                Padding(
                  padding: isEffectiveWide
                      ? const EdgeInsets.all(8.0)
                      : const EdgeInsets.only(bottom: 8.0, top: 2.0),
                  child: layout,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  (Widget layout, bool isEffectiveWide) _getTileLayout(
    BoxConstraints constraints,
    Widget Function({bool isShort}) topArea,
    Widget Function({bool showAvatar}) bottomArea,
  ) {
    // The watch page sidebar uses standard wide tiles and needs them to stay wide
    // even in narrow spaces. The fallback is only for large tiles (search results).
    final bool isEffectiveWide =
        widget.layout == MediaTileLayout.wide &&
        (widget.size == MediaTileSize.standard || constraints.maxWidth >= 483);

    final Widget layout = switch (widget.layout) {
      MediaTileLayout.wide when isEffectiveWide => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          widget.size == MediaTileSize.large
              ? Flexible(
                  flex: 0,
                  fit: FlexFit.loose,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: widget.spec.isShort ? 250 : 400,
                    ),
                    child: topArea(isShort: widget.spec.isShort),
                  ),
                )
              : Expanded(
                  flex: widget.spec.isShort ? 2 : 5,
                  child: topArea(isShort: widget.spec.isShort),
                ),
          const SizedBox(width: 10),
          Expanded(
            flex: widget.size == MediaTileSize.large ? 1 : 5,
            // The avatar earns its place only in the one
            // layout with room for it beside the channel
            // name — wide *and* large. Every other
            // combination (wide-but-not-large included)
            // stays text-only.
            child: bottomArea(showAvatar: widget.size == MediaTileSize.large),
          ),
        ],
      ),

      MediaTileLayout.shorts => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          topArea(isShort: true),
          const SizedBox(height: 6),
          bottomArea(showAvatar: false),
        ],
      ),

      /// Standard layouts or Wide layouts where isEffectiveWide is false
      MediaTileLayout.standard || MediaTileLayout.wide => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          topArea(isShort: widget.spec.isShort),
          const SizedBox(height: 6),
          bottomArea(showAvatar: true),
        ],
      ),
    };

    return (layout, isEffectiveWide);
  }
}