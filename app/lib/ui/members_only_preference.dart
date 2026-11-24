import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/feed_item.dart';

/// Whether members-only videos appear at all — the settings page's "Members-only videos"
/// switch (Feeds › In every list).
///
/// **On by default** — showing them is what YouTube does, and a member who paid for the
/// content should not have to go and find a switch to see it.
///
/// It applies wherever tiles are listed: every `FeedView` (home, subscriptions, search),
/// the home page's rows, and the watch page's related list. Like the promoted switch it
/// needs no request: the sidecar ships the flag and the app filters, so flipping it takes
/// effect at once.
class MembersOnlyVisible extends Notifier<bool> {
  MembersOnlyVisible({this.initial = true});

  final bool initial;

  @override
  bool build() => initial;

  // ignore: avoid_positional_boolean_parameters
  Future<void> set(bool shown) async {
    if (state == shown) return;
    state = shown;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(membersOnlyVisibleKey, shown);
    } catch (_) {
      // A preference that did not stick still applied for this run.
    }
  }

  Future<void> toggle() => set(!state);
}

const String membersOnlyVisibleKey = 'members_only_visible';

final membersOnlyVisibleProvider = NotifierProvider<MembersOnlyVisible, bool>(MembersOnlyVisible.new);

/// The stored value, for seeding [membersOnlyVisibleProvider] before `runApp`.
Future<bool> readMembersOnlyVisible() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(membersOnlyVisibleKey) ?? true;
}

/// Whether a feed item is members-only content.
///
/// One place, because more than one surface asks and a `maybeMap` over a sealed
/// union is exactly the sort of thing that gets written slightly differently
/// each time. Only a video can be members-only; a mix, playlist or channel
/// answers false rather than being a case anyone has to remember.
bool isMembersOnlyItem(FeedItem item) =>
    item.maybeMap(video: (v) => v.isMembersOnly, orElse: () => false);
