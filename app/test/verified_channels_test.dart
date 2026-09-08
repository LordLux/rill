/// The verified-badge cache — keyed on channel id, bounded as an LRU.
///
/// Both properties are rulings rather than implementation detail, and both
/// fail silently when broken: a name key collides two channels onto one entry
/// and drops the badge on a rename, and an unbounded set grows in
/// `SharedPreferences` forever with nothing to notice it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/verified_channels_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The controller writes through `SharedPreferences.getInstance()`, so the
/// write half can only be observed by letting those microtasks run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a channel is remembered under its id', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(verifiedChannelsProvider.notifier).markVerified('UC_lofi');
    expect(container.read(verifiedChannelsProvider), contains('UC_lofi'));
  });

  test('a null or empty id is ignored rather than cached', () async {
    // Every tile without a resolved channel id calls this on build, so the
    // empty key must never become a cache entry that verifies everything.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(verifiedChannelsProvider.notifier).markVerified(null);
    await container.read(verifiedChannelsProvider.notifier).markVerified('');
    expect(container.read(verifiedChannelsProvider), isEmpty);
  });

  test('the cache survives a restart', () async {
    final first = ProviderContainer();
    await first.read(verifiedChannelsProvider.notifier).markVerified('UC_a');
    await _settle();
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    // `build` restores asynchronously, so the first read is empty by design.
    expect(second.read(verifiedChannelsProvider), isEmpty);
    await _settle();
    expect(second.read(verifiedChannelsProvider), contains('UC_a'));
  });

  test('the name-keyed store from before the id ruling is deleted, not read', () async {
    // Its contents are display names. They are not ids and cannot be turned
    // into them, so migrating is not on the table — but leaving them to sit in
    // prefs forever is the unbounded-growth problem by another route.
    SharedPreferences.setMockInitialValues({
      'verified_channel_names': <String>['Lofi Girl', 'Some Channel'],
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(verifiedChannelsProvider);
    await _settle();

    expect(container.read(verifiedChannelsProvider), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('verified_channel_names'), isFalse);
  });

  test('the cache is bounded, and evicts the least recently seen', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(verifiedChannelsProvider.notifier);

    for (var i = 0; i < kVerifiedChannelsCapacity; i++) {
      await controller.markVerified('UC_$i');
    }
    expect(container.read(verifiedChannelsProvider), hasLength(kVerifiedChannelsCapacity));

    // Touch the oldest, so it is no longer the eviction candidate. A repeat
    // call must not change `state` — this fires from a build method and a
    // rebuild per frame would be a real cost.
    final before = container.read(verifiedChannelsProvider);
    await controller.markVerified('UC_0');
    expect(identical(container.read(verifiedChannelsProvider), before), isTrue);

    await controller.markVerified('UC_new');

    final cache = container.read(verifiedChannelsProvider);
    expect(cache, hasLength(kVerifiedChannelsCapacity));
    expect(cache, contains('UC_new'));
    expect(cache, contains('UC_0'), reason: 'touched, so not the eviction candidate');
    expect(cache, isNot(contains('UC_1')), reason: 'least recently seen');
  });

  test('what is persisted is bounded too', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(verifiedChannelsProvider.notifier);

    for (var i = 0; i < kVerifiedChannelsCapacity + 25; i++) {
      await controller.markVerified('UC_$i');
    }
    await _settle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('verified_channel_ids'), hasLength(kVerifiedChannelsCapacity));
  });
}
