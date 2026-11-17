import 'package:freezed_annotation/freezed_annotation.dart';

import 'feed_item.dart';

part 'shelf.freezed.dart';
part 'shelf.g.dart';

/// What a home shelf is — decided by the sidecar from what its tiles are, never from
/// its (localised) title. `protocol.md` §3.2; `todo.md` 111.
///
/// [other] is a category in its own right, not a fallback for a parse failure: a shelf
/// the sidecar has no rule for, a mixed one, and a category a *newer* sidecar might add
/// all land there, so a shelf is never silently lost to an enum that did not know it.
enum ShelfCategory {
  members,
  shorts,
  posts,
  other;

  static ShelfCategory fromWire(Object? value) => switch (value) {
        'members' => members,
        'shorts' => shorts,
        'posts' => posts,
        _ => other,
      };
}

/// A community post, which exists only inside a [Shelf]. Deliberately not a
/// `FeedItem`: that union is switched over by every grid, search result and watch-page
/// rail, and none of them has anywhere to put a post.
@freezed
abstract class PostItem with _$PostItem {
  const PostItem._();

  const factory PostItem({
    @Default('post') String kind,
    required String id,
    required String authorName,
    String? authorChannelId,
    String? authorAvatarUrl,
    String? text,
    String? imageUrl,
    String? publishedText,
    String? likeCountText,

    /// Absolute, taken from the post's own link by the sidecar. Opened in the system
    /// browser; there is no post page in this app.
    String? postUrl,
  }) = _PostItem;

  factory PostItem.fromJson(Map<String, Object?> json) => _$PostItemFromJson(json);
}

/// What a [Shelf] holds: a feed tile or a post.
sealed class ShelfItem {
  const ShelfItem();

  factory ShelfItem.fromJson(Map<String, Object?> json) => json['kind'] == 'post'
      ? ShelfPost(PostItem.fromJson(json))
      : ShelfTile(FeedItem.fromJson(json));
}

class ShelfTile extends ShelfItem {
  const ShelfTile(this.item);
  final FeedItem item;
}

class ShelfPost extends ShelfItem {
  const ShelfPost(this.post);
  final PostItem post;
}

/// A titled row of the home feed, in the position YouTube put it.
class Shelf {
  const Shelf({
    required this.category,
    required this.title,
    required this.index,
    required this.items,
  });

  final ShelfCategory category;

  /// YouTube's header for the row, in the viewer's language; `null` when it had none.
  final String? title;

  /// How many of the *page's* grid tiles come before this shelf. A continuation page's
  /// `index` is relative to that page; [FeedState] adds the tiles already loaded.
  final int index;

  final List<ShelfItem> items;

  /// The same shelf, moved to an absolute grid position.
  Shelf shifted(int by) => Shelf(category: category, title: title, index: index + by, items: items);

  factory Shelf.fromJson(Map<String, Object?> json) => Shelf(
        category: ShelfCategory.fromWire(json['category']),
        title: json['title'] as String?,
        index: (json['index'] as num?)?.toInt() ?? 0,
        items: [
          for (final raw in (json['items'] as List<dynamic>? ?? const []))
            ShelfItem.fromJson(raw as Map<String, Object?>),
        ],
      );
}
