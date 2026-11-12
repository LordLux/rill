import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/shelf.dart';

/// Which categories of home shelf are shown with their contents — the settings page's
/// one switch per category (`todo.md` 111).
///
/// **Defaults match what the app did before shelves were rows:** members shown, Shorts
/// and posts hidden (they were dropped), and `other` shown (those tiles were flattened
/// into the grid, so hiding them would be a loss no one asked for).
///
/// The filter is the app's and not the sidecar's — the sidecar ships every shelf and
/// stays a pure parser — so flipping a switch needs no request: the shelves are already
/// in [FeedState].
const Map<ShelfCategory, bool> shelfVisibilityDefaults = {
  ShelfCategory.members: true,
  ShelfCategory.shorts: false,
  ShelfCategory.posts: false,
  ShelfCategory.other: true,
};

String _key(ShelfCategory category) => 'shelf_visible_${category.name}';

class ShelfVisibility extends Notifier<Map<ShelfCategory, bool>> {
  ShelfVisibility({Map<ShelfCategory, bool>? initial}) : initial = initial ?? shelfVisibilityDefaults;

  final Map<ShelfCategory, bool> initial;

  @override
  Map<ShelfCategory, bool> build() => Map.unmodifiable(initial);

  bool isShown(ShelfCategory category) => state[category] ?? shelfVisibilityDefaults[category] ?? true;

  Future<void> set(ShelfCategory category, bool shown) async {
    if (isShown(category) == shown) return;
    state = Map.unmodifiable({...state, category: shown});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key(category), shown);
    } catch (_) {
      // A preference that did not stick still applied for this run.
    }
  }
}

final shelfVisibilityProvider =
    NotifierProvider<ShelfVisibility, Map<ShelfCategory, bool>>(ShelfVisibility.new);

Future<Map<ShelfCategory, bool>> readShelfVisibility() async {
  final prefs = await SharedPreferences.getInstance();
  return {
    for (final category in ShelfCategory.values)
      category: prefs.getBool(_key(category)) ?? shelfVisibilityDefaults[category]!,
  };
}
