import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';

/// Whether members-only videos appear in feeds at all.
///
/// A provider rather than a bare `const`, even though nothing writes to it yet:
/// the settings page that will own this is a later task, and the difference
/// between "a const someone has to find and replace" and "a provider with a
/// setter already wired to every surface" is the whole of that later task.
/// Every surface already watches it, so turning it off becomes a one-line
/// change in a settings screen rather than a refactor of the feed.
///
/// Defaults to **true** — showing them is what YouTube does, and a member who
/// paid for the content should not have to go and find a switch to see it.
///
/// Not persisted yet. When it is, this is the notifier that gains a
/// `SharedPreferences` read in `build`, the same way `accentProvider` does.
class MembersOnlyVisible extends Notifier<bool> {
  @override
  bool build() => true;

  // ignore: avoid_positional_boolean_parameters
  void set(bool value) => state = value;

  void toggle() => state = !state;
}

final membersOnlyVisibleProvider =
    NotifierProvider<MembersOnlyVisible, bool>(MembersOnlyVisible.new);

/// Whether a feed item is members-only content.
///
/// One place, because more than one surface asks and a `maybeMap` over a sealed
/// union is exactly the sort of thing that gets written slightly differently
/// each time. Only a video can be members-only; a mix, playlist or channel
/// answers false rather than being a case anyone has to remember.
bool isMembersOnlyItem(FeedItem item) =>
    item.maybeMap(video: (v) => v.isMembersOnly, orElse: () => false);
