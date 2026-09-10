/// Anonymous browsing still works completely — Task 22 §8.
///
/// The brief lists "anonymous playback and captions still work" as a test, and
/// it is the one item in that list with a plausible way to go silently wrong:
/// Task 22 puts a cookie behind a mutable session, and the obvious mistake is
/// to route *everything* through it. The sidecar's two-client model says
/// otherwise — browse and report are `WEB` with cookies, stream resolution and
/// captions are the anonymous `MWEB`/`VISIONOS` session (F11, architecture.md
/// §2.3) — and this file is that claim, asserted from the app's side.
///
/// **What makes it non-vacuous.** A test that merely plays a video with the
/// auth state set to anonymous passes whether or not the two families are
/// actually separate, because nothing would have connected them. So the fake
/// sidecar models the real difference — measured live: signed out,
/// `feed.subscriptions` answers `UPSTREAM_ERROR — "You must be signed in"`
/// while `playback.open` and `captions.*` answer normally — and every test here
/// asserts *both halves in the same anonymous session*. The browse refusal is
/// what proves the session really is signed out; the resolve success is what
/// proves the resolve path does not care.
///
/// The other half of this claim lives in `sidecar/test/resolve-anonymous.test.ts`,
/// which asserts at source level that no cookie ever reaches a resolution
/// session in the first place.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/captions_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

late FakeEngine engine;
late ProviderContainer container;

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

Future<void> settle([int millis = 300]) => Future<void>.delayed(Duration(milliseconds: millis));

/// Put the sidecar in the signed-out state these tests are about.
Future<void> goAnonymous() =>
    RpcClient.instance.call('test.reset', {'authState': 'anonymous'});

void main() {
  setUpAll(() async {
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  setUp(() async {
    await goAnonymous();
    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [playbackEngineProvider.overrideWithValue(engine)],
    );
    container.read(playbackProvider);
    container.read(captionsProvider);
  });

  tearDown(() => container.dispose());

  tearDownAll(() => RpcClient.instance.killForTest());

  /// The control every test below leans on: this session really is signed out.
  ///
  /// Without it each test would be asserting "the resolve path works", which it
  /// does in every state, and would keep passing if a future change quietly
  /// signed the fake back in.
  Future<void> assertReallySignedOut() async {
    final verify = await RpcClient.instance.call('auth.verify', {}) as Map<String, dynamic>;
    expect(verify['state'], 'anonymous', reason: 'the control for this whole file');
    await expectLater(
      RpcClient.instance.call('feed.subscriptions', {}),
      throwsA(isA<RpcException>()),
      reason: 'a signed-out browse call must refuse, or the anonymity is not real',
    );
  }

  test('the browse family refuses while the resolve family does not', () async {
    await assertReallySignedOut();

    // Same session, same moment. `playback.open` resolves through the
    // anonymous session by design and must be untouched by any of the above.
    final source = await RpcClient.instance.call('playback.open', {'videoId': 'anon1'})
        as Map<String, dynamic>;
    expect(source['variants'], isNotEmpty);
    expect(source['sessionId'], isNotNull);
  });

  test('playback opens and reaches the engine while signed out', () async {
    await assertReallySignedOut();

    container.read(queueProvider.notifier).play(video('anon1'));
    await settle();

    // The engine is where a broken resolve would actually show: no URL opened.
    expect(engine.opened, isNotEmpty,
        reason: 'anonymous playback must reach mpv, not stop at the RPC');
  });

  test('captions list and load while signed out', () async {
    await assertReallySignedOut();

    final list = await RpcClient.instance.call('captions.list', {'videoId': 'anon1'})
        as Map<String, dynamic>;
    final tracks = list['tracks'] as List<dynamic>;
    expect(tracks, isNotEmpty, reason: 'captions ride the anonymous /player response');

    final trackId = (tracks.first as Map<String, dynamic>)['id'] as String;
    final got = await RpcClient.instance.call(
      'captions.get',
      {'videoId': 'anon1', 'trackId': trackId},
    ) as Map<String, dynamic>;
    expect(got['format'], 'ass');
    expect(got['content'], isNotEmpty);
  });

  test('the home feed still loads while signed out', () async {
    // Anonymous browsing "still works completely" includes the feed itself —
    // home is public where subscriptions is not, and the difference between
    // those two is the whole of what signing out should change.
    await assertReallySignedOut();

    final home = await RpcClient.instance.call('feed.home', {}) as Map<String, dynamic>;
    expect(home['items'], isNotEmpty);
  });
}
