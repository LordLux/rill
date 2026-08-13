import 'dart:async';

import 'package:flutter/material.dart';
import '../../domain/feed_item.dart';
import '../../theme/tokens.dart';
import '../hover_preview.dart';
import '../open_video.dart';

// ---- TEMPORARY: unfed tile slots ----
// Master switch to turn off all placeholder elements at once
const bool tmpShowPlaceholders = false;

// waiting on: percentDurationWatched extracted in the sidecar parser, added to the DTO in docs/protocol.md, and a corpus re-export
const double tmpProgressBarValue = 0.65;

// waiting on: verified or artist badge field extracted in the sidecar parser, added to DTO, and corpus re-export
const IconData tmpTitleTrailingIcon = Icons.check_circle;
const double tmpTitleTrailingIconSize = 14.0;

// waiting on: menu items data from DTO
const List<String> tmpMenuContents = [];

// The stacked-card colours moved to `theme/tokens.dart` as
// `stackedCardBack`/`stackedCardFront`, still waiting on palette extraction from
// the thumbnail, cached off the UI isolate.
// -------------------------------------

enum DurationBadgeTone { normal, live, music }

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
  final String? durationText;
  final DurationBadgeTone durationTone;
  final List<String> badges;
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

  const TileSpec({
    required this.title,
    required this.thumbnailUrl,
    this.previewVideoId,
    required this.isStackedCards,
    this.durationText,
    required this.durationTone,
    required this.badges,
    required this.canWatchLater,
    required this.canAddToQueue,
    this.premiereAtMs,
    this.avatarUrl,
    required this.primaryLine,
    this.secondaryLine,
  });
}

TileSpec? specFor(FeedItem item) {
  return item.map(
    video: (v) {
      String? durText;
      if (!v.isLive && v.durationSeconds != null) {
        final d = Duration(seconds: v.durationSeconds!);
        final h = d.inHours;
        final m = d.inMinutes.remainder(60);
        final s = d.inSeconds.remainder(60);
        if (h > 0) {
          durText = '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
        } else {
          durText = '$m:${s.toString().padLeft(2, '0')}';
        }
      }
      return TileSpec(
        title: v.title,
        thumbnailUrl: v.thumbnailUrl,
        previewVideoId: v.id.isEmpty ? null : v.id,
        isStackedCards: false,
        durationText: durText,
        durationTone: v.isLive ? DurationBadgeTone.live : DurationBadgeTone.normal,
        badges: v.badges,
        canWatchLater: v.canWatchLater,
        canAddToQueue: v.canAddToQueue,
        premiereAtMs: v.premiereAtMs,
        avatarUrl: v.channelAvatarUrl,
        primaryLine: v.channelName,
        secondaryLine: (v.viewCountText != null || v.publishedText != null) ? '${v.viewCountText ?? ''}${v.publishedText != null ? ' • ${v.publishedText}' : ''}'.trim() : null,
      );
    },
    mix: (m) => TileSpec(
      title: m.title,
      thumbnailUrl: m.thumbnailUrl,
      previewVideoId: mixSeedVideoId(m),
      isStackedCards: true,
      durationText: m.videoCount != null ? '${m.videoCount} videos' : null,
      durationTone: DurationBadgeTone.normal,
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

class MediaTile extends StatefulWidget {
  final TileSpec spec;

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

  const MediaTile({
    super.key,
    required this.spec,
    this.onTap,
    this.onWatchLater,
    this.onAddToQueue,
  });

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  bool isHovering = false;

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
    if (isHovering) _onEnter();
  }

  @override
  void dispose() {
    _stopPreview();
    _slot.dispose();
    super.dispose();
  }

  void _stopPreview({String? videoId}) {
    final id = videoId ?? widget.spec.previewVideoId;
    if (id != null) _preview?.exit(id);
    _slot.value = null;
  }

  void _onEnter() {
    setState(() => isHovering = true);
    final videoId = widget.spec.previewVideoId;
    if (videoId != null) _preview?.enter(videoId, _slot);
  }

  void _onExit() {
    setState(() => isHovering = false);
    _stopPreview();
  }

  /// A preview with a picture on screen — the state the tile's chrome reacts to.
  static bool _isPreviewing(PreviewSession? session) => session != null && session.visible;

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

  /// The duration / LIVE pill. Scrim family rather than a surface role: it sits over an
  /// arbitrary thumbnail.
  Widget _durationBadge(RillTokens tokens) {
    final isLive = widget.spec.durationTone == DurationBadgeTone.live;
    return Container(
      padding: const EdgeInsets.only(left: 4.5, right: 4.5, bottom: .75, top: .5),
      decoration: BoxDecoration(
        color: isLive ? tokens.liveBadge.withValues(alpha: 0.8) : tokens.scrim.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLive)
            Padding(
              padding: const EdgeInsets.only(right: 4.0),
              child: Icon(Icons.sensors, size: 12, color: tokens.onScrim),
            )
          else if (widget.spec.durationTone == DurationBadgeTone.music)
            Padding(
              padding: const EdgeInsets.only(right: 4.0),
              child: Icon(Icons.music_note, size: 12, color: tokens.onScrim),
            ),
          Text(
            isLive ? 'LIVE' : (widget.spec.durationText ?? ''),
            style: TextStyle(color: tokens.onScrim, fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w400),
          ),
        ],
      ),
    );
  }

  /// The top-right hover cluster: the mute toggle while previewing, Watch Later and Add to
  /// queue otherwise. Not both — three buttons over a 16:9 thumbnail is a toolbar. A CC button
  /// belongs in the previewing branch once captions exist (§2.6).
  Widget _hoverActions(RillTokens tokens, PreviewSession? session) {
    final playing = _isPreviewing(session) ? session! : null;
    final showsAnything = playing != null || widget.spec.canWatchLater || widget.spec.canAddToQueue;
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
    Widget topArea = AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Stacked cards for Mixes
          if (widget.spec.isStackedCards /*&& tmpShowPlaceholders*/ ) ...[
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
                  // Thumbnail image
                  Image.network(
                    widget.spec.thumbnailUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.image, color: scheme.onSurfaceVariant),
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
                          // `cover` matches the `Image.network` underneath, so the swap does not
                          // reframe the picture.
                          child: RepaintBoundary(
                            child: session.engine.videoSurface(fit: BoxFit.cover),
                          ),
                        );
                      },
                    ),
                  ),
                  // Duration badge — hidden while a preview is playing: it describes the
                  // thumbnail, and over a running video it is stale chrome.
                  if (widget.spec.durationText != null || widget.spec.durationTone == DurationBadgeTone.live)
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: ValueListenableBuilder<PreviewSession?>(
                        valueListenable: _slot,
                        builder: (context, session, child) =>
                            _isPreviewing(session) ? const SizedBox.shrink() : child!,
                        child: _durationBadge(tokens),
                      ),
                    ),

                  // Progress bar
                  if (tmpShowPlaceholders && tmpProgressBarValue > 0)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 4,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: tmpProgressBarValue,
                        // The watched-progress bar is one of the places the
                        // accent belongs (§3.3).
                        child: Container(color: scheme.primary),
                      ),
                    ),

                  // Watch Later + Add to Queue — or, while a preview is
                  // playing, the mute toggle that replaces them.
                  Positioned(
                    top: 8,
                    right: 8,
                    child: ValueListenableBuilder<PreviewSession?>(
                      valueListenable: _slot,
                      builder: (context, session, _) => _hoverActions(tokens, session),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    // Metadata area
    Widget bottomArea = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Channel avatar
        if (widget.spec.avatarUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: CircleAvatar(
              radius: 18,
              backgroundImage: NetworkImage(widget.spec.avatarUrl!),
              onBackgroundImageError: (error, stackTrace) {},
            ),
          )
        else if (!widget.spec.isStackedCards)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: const CircleAvatar(radius: 18, child: Icon(Icons.person, size: 20)),
          ),

        SizedBox(width: widget.spec.isStackedCards ? 0 : 12), // Separator if channel avatar is present
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
                      padding: const EdgeInsets.only(right: 28.0, top: 4.0),
                      child: Text(
                        widget.spec.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: scheme.onSurface),
                      ),
                    ),
                  ),
                  // 3-dot menu icon
                  Positioned(
                    top: -1,
                    right: -4,
                    child: IconButton(
                      icon: Icon(Icons.more_vert, size: 21, color: scheme.onSurface),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      mouseCursor: SystemMouseCursors.click,
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1.5),
              // Channel name
              Text(
                widget.spec.primaryLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              // Secondary line (view count + published date)
              if (widget.spec.secondaryLine != null && widget.spec.secondaryLine!.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: 2.0),
                  child: Text(
                    widget.spec.secondaryLine!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ),
              // Badges
              if (widget.spec.badges.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: widget.spec.badges
                        .map(
                          // Badges stay on a surface role — §3.3 keeps the accent
                          // off them.
                          (b) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(b, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
                          ),
                        )
                        .toList(),
                  ),
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
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

    // `onExit` fires when the pointer leaves *this* region, and a nested
    // `MouseRegion` — the two action buttons are inside `IconButton`s, which
    // have one — does not trigger it. That is what keeps hovering Watch Later
    // from stopping the preview, and it is asserted rather than assumed.
    return MouseRegion(
      onEnter: (_) => _onEnter(),
      onExit: (_) => _onExit(),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        // Opaque so the whole tile — including the gaps between its children —
        // is a target. `deferToChild` would leave the padding dead, which reads
        // as a tile that only sometimes opens.
        behavior: HitTestBehavior.opaque,
        child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedScale(
              duration: const Duration(milliseconds: 100),
              scale: isHovering ? 1.04 : 1.0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                decoration: BoxDecoration(
                  color: isHovering ? scheme.surfaceContainerHigh : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: 8.0, top: /*3*/ 2),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 100),
              scale: /*isHovering ? 0.985 :*/ 1.0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  topArea,
                  const SizedBox(height: 6),
                  bottomArea,
                ],
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }
}
