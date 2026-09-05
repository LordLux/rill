import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Channel **ids** seen carrying a verified badge, most-recently-touched last.
///
/// Keyed on `channelId`, never on display name: names are neither unique nor
/// stable, so a name key both collides two channels onto one entry and drops
/// the badge the moment a channel renames itself.
const String _prefsKey = 'verified_channel_ids';

/// The name-keyed store this replaced. Its contents are display names, which
/// are not ids and cannot be migrated into them — it is deleted on first
/// restore rather than left to sit in `SharedPreferences` forever.
const String _legacyPrefsKey = 'verified_channel_names';

/// How many ids the cache keeps. Reached only by a user who has scrolled past
/// several hundred distinct verified channels in one install; past it the
/// least-recently-seen id is evicted, which costs one badge that the next
/// response carrying it puts straight back.
const int kVerifiedChannelsCapacity = 500;

/// Channels observed to carry the verified/artist badge at least once.
///
/// The badge is not present on every renderer that mentions a channel, so a
/// tile can know a channel is verified while the next tile for the same
/// channel does not. This caches the observation — it never invents one — so
/// the checkmark stops flickering between surfaces.
///
/// The cache only ever *adds*: a de-verified channel keeps its checkmark until
/// evicted. That is a deliberate ruling, not an oversight — de-verification is
/// rare and the failure is cosmetic, where clearing on absence would drop the
/// badge on every response that merely omits it, which is common.
///
/// It is bounded by [kVerifiedChannelsCapacity] as an LRU. Unbounded growth in
/// `SharedPreferences` is the part that is not acceptable: the file is read
/// synchronously at startup and there is no ceiling on how many channels an
/// install sees.
class VerifiedChannelsController extends Notifier<Set<String>> {
  /// Insertion/touch order, least-recently-seen first. `state` is the same
  /// ids as an unordered set, because every read is a `contains` on the build
  /// path of a tile and that has to stay O(1).
  final List<String> _recency = <String>[];

  @override
  Set<String> build() {
    Future.microtask(_restore);
    return const {};
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_legacyPrefsKey)) await prefs.remove(_legacyPrefsKey);

    final stored = prefs.getStringList(_prefsKey);
    if (stored == null) return;

    _recency
      ..clear()
      ..addAll(stored.where((id) => id.isNotEmpty));
    _trim();
    state = _recency.toSet();
  }

  /// Records that [channelId] was seen verified. Safe to call from a build
  /// method's microtask on every frame — a repeat call for an id already held
  /// only bumps recency in memory, changing neither `state` (so no rebuild)
  /// nor the stored list (so no write).
  Future<void> markVerified(String? channelId) async {
    if (channelId == null || channelId.isEmpty) return;

    if (_recency.remove(channelId)) {
      _recency.add(channelId);
      return;
    }

    _recency.add(channelId);
    _trim();
    state = _recency.toSet();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, List<String>.of(_recency));
  }

  void _trim() {
    if (_recency.length <= kVerifiedChannelsCapacity) return;
    _recency.removeRange(0, _recency.length - kVerifiedChannelsCapacity);
  }
}

final verifiedChannelsProvider = NotifierProvider<VerifiedChannelsController, Set<String>>(() => VerifiedChannelsController());
