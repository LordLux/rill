import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/feed_item.dart';

/// Whether tiles YouTube marks as promoted are shown — the "Promoted videos" switch
/// (`architecture.md` F63).
///
/// **Off by default.** A promoted tile is a paid placement that looks like a video but is
/// not one: no queue, no Watch Later, and opening it ends in "This video is unavailable".
/// It applies on every surface that shows tiles (the home feed and its rows, search, the
/// watch page's related list), and needs no request — the sidecar ships the flag and the
/// app filters, so flipping it takes effect at once.
class PromotedVisible extends Notifier<bool> {
  PromotedVisible({this.initial = false});

  final bool initial;

  @override
  bool build() => initial;

  Future<void> set(bool shown) async {
    if (state == shown) return;
    state = shown;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(promotedVisibleKey, shown);
    } catch (_) {
      // A preference that did not stick still applied for this run.
    }
  }
}

const String promotedVisibleKey = 'promoted_visible';

final promotedVisibleProvider = NotifierProvider<PromotedVisible, bool>(PromotedVisible.new);

Future<bool> readPromotedVisible() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(promotedVisibleKey) ?? false;
}

/// Whether a feed item is a promoted placement. Only a video can be; one place, like
/// `isMembersOnlyItem`, because more than one surface asks.
bool isPromotedItem(FeedItem item) => item.maybeMap(video: (v) => v.isPromoted, orElse: () => false);
