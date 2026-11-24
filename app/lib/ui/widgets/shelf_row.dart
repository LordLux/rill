import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/feed_item.dart';
import '../../domain/shelf.dart';
import '../../theme/screen_values.dart';
import '../focus_surface.dart';
import '../members_only_preference.dart';
import '../open_video.dart';
import '../promoted_preference.dart';
import 'feed_grid_metrics.dart';
import 'media_tile.dart';

/// What a shelf is called when YouTube sent no header for it.
String shelfFallbackTitle(ShelfCategory category) => switch (category) {
      ShelfCategory.members => 'From your memberships',
      ShelfCategory.shorts => 'Shorts',
      ShelfCategory.posts => 'Latest posts',
      ShelfCategory.other => 'More to watch',
    };

IconData _iconFor(ShelfCategory category) => switch (category) {
      ShelfCategory.members => Icons.star_rounded,
      ShelfCategory.shorts => Icons.smart_display_outlined,
      ShelfCategory.posts => Icons.forum_outlined,
      ShelfCategory.other => Icons.video_library_outlined,
    };

/// A titled row of the home feed with its own horizontal scroll — YouTube's shelf
/// (`todo.md` 111, `architecture.md` F62).
///
/// **One Tab group per row** (`FocusSurface`): Tab walks the tiles of a row left to
/// right and then on to the next row, instead of the row being part of one flat walk of
/// the whole feed. Every tile is built, not lazily — a lazily built tile past the cache
/// extent cannot be Tabbed to, and a row holds a dozen at most.
///
/// Geometry is borrowed from the two shelves `FeedView` already had (the members row's
/// 16:9 tiles, the Shorts row's tall ones) so a tile looks the same here as it did there.
class ShelfRow extends ConsumerWidget {
  const ShelfRow({super.key, required this.shelf});

  final Shelf shelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final title = shelf.title ?? shelfFallbackTitle(shelf.category);
    final showPromoted = ref.watch(promotedVisibleProvider);
    final showMembersOnly = ref.watch(membersOnlyVisibleProvider);
    final entries = [
      for (final entry in shelf.items)
        if (entry is! ShelfTile ||
            ((showPromoted || !isPromotedItem(entry.item)) && (showMembersOnly || !isMembersOnlyItem(entry.item))))
          entry,
    ];
    // A row whose every tile was hidden has nothing left to show.
    if (entries.isEmpty) return const SizedBox.shrink();
    final kind = _GeometryKind.of(shelf);

    return FocusSurface(
      child: Padding(
        padding: const EdgeInsets.only(top: 8.0, bottom: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 9.0),
              child: Semantics(
                header: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(child: Icon(_iconFor(shelf.category), size: 20, color: scheme.onSurface)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: scheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final geometry = kind.geometry(constraints.maxWidth);
                return SizedBox(
                  height: geometry.height,
                  child: SilkyListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: entries.length,
                    // Wide enough that every tile of a row is built (see the class comment).
                    cacheExtent: 100000,
                    itemBuilder: (context, index) => Padding(
                      padding: EdgeInsets.only(right: 16.0, bottom: 8.0, top: 9.0, left: index == 0 ? 10.5 : 0),
                      child: SizedBox(
                        width: geometry.itemWidth,
                        child: _tile(context, ref, entries[index], kind),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, WidgetRef ref, ShelfItem entry, _GeometryKind kind) {
    switch (entry) {
      case ShelfPost(:final post):
        return PostCard(post: post);
      case ShelfTile(:final item):
        final spec = specFor(item);
        if (spec == null) return const SizedBox.shrink();
        final onTap = tapHandlerFor(context, ref, item);
        final onThumbnailTap = thumbnailTapHandlerFor(context, ref, item);
        void onAddToQueue() => queueFromTile(ref, item);
        void onWatchLater() => unawaited(addToWatchLater(context, item));
        final menu = menuForTile(context, ref, item, spec);
        return kind == _GeometryKind.shorts
            ? MediaTile.shorts(
                spec: spec,
                onTap: onTap,
                onThumbnailTap: onThumbnailTap,
                onAddToQueue: onAddToQueue,
                onWatchLater: onWatchLater,
                menu: menu,
              )
            : MediaTile(
                spec: spec,
                onTap: onTap,
                onThumbnailTap: onThumbnailTap,
                onAddToQueue: onAddToQueue,
                onWatchLater: onWatchLater,
                menu: menu,
              );
    }
  }
}

/// Which tile shape a row is laid out for. A mixed row is `video`: its Shorts and posts
/// then sit in 16:9 slots, which is what an `other` shelf of mixed tiles deserves.
enum _GeometryKind {
  video,
  shorts,
  posts;

  static _GeometryKind of(Shelf shelf) {
    if (shelf.items.isNotEmpty && shelf.items.every((e) => e is ShelfPost)) return posts;
    final allShorts = shelf.items.isNotEmpty &&
        shelf.items.every((e) => e is ShelfTile && e.item is VideoItem && (e.item as VideoItem).isShort);
    return allShorts ? shorts : video;
  }

  ({double itemWidth, double height}) geometry(double maxWidth) {
    switch (this) {
      case video:
        // One column narrower than the grid, so the row reads as a strip that continues
        // past the edge rather than as a short row that happens to be indented.
        final columns = FeedGridMetrics.columnCount(maxWidth, false) + 0.4;
        final itemWidth = (maxWidth / columns).clamp(180.0, 340.0);
        // 16:9 thumbnail plus the same caption block the grid tile uses.
        return (itemWidth: itemWidth, height: itemWidth / ScreenValues.normalAspectRatio + 104.0 + 32);
      case shorts:
        final itemWidth = (maxWidth / 3.5).clamp(140.0, 200.0);
        // `media_tile.dart`'s shorts `topArea` ratio, plus the title and view count.
        return (itemWidth: itemWidth, height: itemWidth * (1 / ScreenValues.shortAspectRatioSecondary) + 85.5);
      case posts:
        final itemWidth = (maxWidth / 3.2).clamp(240.0, 340.0);
        return (itemWidth: itemWidth, height: _PostCardMetrics.height);
    }
  }
}

abstract final class _PostCardMetrics {
  static const double height = 268;
}

const Set<String> _launchableSchemes = {'http', 'https'};

void _openPost(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !_launchableSchemes.contains(uri.scheme)) return;
  unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
}

/// A community post: author, text, picture, likes. Opens the post in the system browser
/// — there is no post page in this app, and nothing renders a browser inside it.
class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.post});

  final PostItem post;

  String get _narration {
    final parts = <String>[
      'Post by ${post.authorName}',
      if (post.publishedText != null) post.publishedText!,
      if (post.text != null) post.text!,
      if (post.likeCountText != null) '${post.likeCountText} likes',
    ];
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final url = post.postUrl;
    final image = post.imageUrl;
    final avatar = post.authorAvatarUrl;

    final card = Container(
      height: _PostCardMetrics.height - 17, // the row's own top and bottom padding
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundImage: avatar == null || avatar.isEmpty ? null : NetworkImage(avatar),
                onBackgroundImageError: avatar == null || avatar.isEmpty ? null : (_, _) {},
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.authorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (post.publishedText != null)
                      Text(
                        post.publishedText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (post.text != null)
            Expanded(
              child: ClipRect(
                child: Text(
                  post.text!,
                  maxLines: image == null ? 7 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
              ),
            )
          else
            const Spacer(),
          if (image != null && image.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 96,
              width: double.infinity,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  image,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ],
          if (post.likeCountText != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.thumb_up_outlined, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(post.likeCountText!, style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ],
        ],
      ),
    );

    return KeyboardTap(
      onTap: url == null ? null : () => _openPost(url),
      label: _narration,
      borderRadius: 12,
      child: ExcludeSemantics(child: card),
    );
  }
}
