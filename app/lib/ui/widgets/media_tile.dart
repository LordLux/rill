import 'package:flutter/material.dart';
import '../../domain/feed_item.dart';
import '../../theme/tokens.dart';

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

class TileSpec {
  final String title;
  final String thumbnailUrl;

  // top slots
  final bool isStackedCards;
  final String? durationText;
  final DurationBadgeTone durationTone;
  final List<String> badges;
  final bool canWatchLater;
  final bool canAddToQueue;

  // bottom slots
  final String? avatarUrl;
  final String primaryLine;
  final String? secondaryLine;

  const TileSpec({
    required this.title,
    required this.thumbnailUrl,
    required this.isStackedCards,
    this.durationText,
    required this.durationTone,
    required this.badges,
    required this.canWatchLater,
    required this.canAddToQueue,
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
        isStackedCards: false,
        durationText: durText,
        durationTone: v.isLive ? DurationBadgeTone.live : DurationBadgeTone.normal,
        badges: v.badges,
        canWatchLater: v.canWatchLater,
        canAddToQueue: v.canAddToQueue,
        avatarUrl: v.channelAvatarUrl,
        primaryLine: v.channelName,
        secondaryLine: (v.viewCountText != null || v.publishedText != null) ? '${v.viewCountText ?? ''}${v.publishedText != null ? ' • ${v.publishedText}' : ''}'.trim() : null,
      );
    },
    mix: (m) => TileSpec(
      title: m.title,
      thumbnailUrl: m.thumbnailUrl,
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
                  // Duration badge
                  if (widget.spec.durationText != null || widget.spec.durationTone == DurationBadgeTone.live)
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: Container(
                        padding: EdgeInsets.only(left: 4.5, right: 4.5, bottom: .75, top: .5),
                        decoration: BoxDecoration(
                          // Both sit over an arbitrary thumbnail, so both come
                          // from the scrim family rather than a surface role.
                          color: widget.spec.durationTone == DurationBadgeTone.live
                              ? tokens.liveBadge.withValues(alpha: 0.8)
                              : tokens.scrim.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.spec.durationTone == DurationBadgeTone.live)
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
                              widget.spec.durationTone == DurationBadgeTone.live ? 'LIVE' : (widget.spec.durationText ?? ''),
                              style: TextStyle(color: tokens.onScrim, fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w400),
                            ),
                          ],
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
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: tmpProgressBarValue,
                        // The watched-progress bar is one of the places the
                        // accent belongs (§3.3).
                        child: Container(color: scheme.primary),
                      ),
                    ),

                  // Watch Later + Add to Queue buttons
                  if (widget.spec.canWatchLater || widget.spec.canAddToQueue)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: AnimatedOpacity(
                        opacity: isHovering ? 1 : 0,
                        duration: const Duration(milliseconds: 100),
                        child: IgnorePointer(
                          // Faded-out buttons must not swallow clicks meant for
                          // the tile underneath.
                          ignoring: !isHovering,
                          child: Column(
                            children: [
                              if (widget.spec.canWatchLater) ...[
                                IconButton(
                                  style: IconButton.styleFrom(
                                    // Scrim, not a surface: these buttons have to
                                    // stay readable over a thumbnail nobody chose.
                                    backgroundColor: tokens.scrim.withValues(alpha: 0.7),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6), // Matches your desired radius
                                    ),
                                  ),
                                  hoverColor: tokens.scrim,
                                  mouseCursor: SystemMouseCursors.click,
                                  icon: Icon(Icons.schedule, color: tokens.onScrim, size: 23),
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  padding: EdgeInsets.zero,
                                  onPressed: widget.onWatchLater,
                                ),
                                SizedBox(height: 8.0),
                              ],
                              if (widget.spec.canAddToQueue)
                                IconButton(
                                  style: IconButton.styleFrom(
                                    backgroundColor: tokens.scrim.withValues(alpha: 0.7),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6), // Matches your desired radius
                                    ),
                                  ),
                                  hoverColor: tokens.scrim,
                                  mouseCursor: SystemMouseCursors.click,
                                  icon: Icon(Icons.playlist_play, color: tokens.onScrim, size: 23),
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  padding: EdgeInsets.zero,
                                  onPressed: widget.onAddToQueue,
                                ),
                            ],
                          ),
                        ),
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
            ],
          ),
        ),
      ],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => isHovering = true),
      onExit: (_) => setState(() => isHovering = false),
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
