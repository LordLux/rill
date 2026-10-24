/// Captions, from the RPC to the engine — against a real sidecar process.
///
/// `fake_sidecar.ts` answers `captions.list` and `captions.get` and records
/// every call, so these assert what the app actually put on the wire. The engine
/// is a [FakeEngine], which is also what makes "the ASS reached mpv" observable:
/// it logs every `setSubtitle`, nulls included, because several of the claims
/// here are about a *sequence* rather than a final value.
///
/// Three video ids carry the shapes: `nocaps1` has no tracks, `capsfail1` fails
/// the list, everything else has English and German.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/caption_track.dart';
import 'package:rill/data/playback/engine.dart';
import 'package:rill/ui/captions_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/shortcuts.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

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

late FakeEngine engine;
late ProviderContainer container;

Future<void> boot() async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();

  engine = FakeEngine();
  container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );
  container.read(playbackProvider);
  // The captions controller registers its playback listener in `build`, so
  // nothing loads until something has read it — same as `PlaybackController`.
  container.read(captionsProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

Future<void> play(String id) async {
  container.read(queueProvider.notifier).play(video(id));
  await settle();
}

CaptionsState get captions => container.read(captionsProvider);
CaptionsController get controller => container.read(captionsProvider.notifier);

Future<({List<dynamic> lists, List<dynamic> gets})> captionLog() async {
  final response = await RpcClient.instance.call('test.captionLog', {}) as Map<String, dynamic>;
  return (lists: response['lists'] as List<dynamic>, gets: response['gets'] as List<dynamic>);
}

void main() {
  // `resolvePlayerShortcut` reads `HardwareKeyboard.instance` for the modifier
  // state, and that getter throws without a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(boot);

  tearDown(() {
    container.dispose();
    RpcClient.instance.killForTest();
  });

  group('the track list', () {
    test('loads for whatever the player opened, without being told', () async {
      await play('vid1');
      expect(captions.tracks.map((t) => t.languageCode), ['en', 'de']);
      expect(captions.isLoadingTracks, isFalse);
      expect((await captionLog()).lists, ['vid1']);
    });

    test('a video with no tracks yields an empty list, not an error', () async {
      await play('nocaps1');
      expect(captions.tracks, isEmpty);
      expect(captions.hasTracks, isFalse);
      // Settled, not pending: this is what hides the CC control.
      expect(captions.isLoadingTracks, isFalse);
      expect(captions.error, isNull);
    });

    test('a failing list is an empty control, and says why', () async {
      await play('capsfail1');
      expect(captions.hasTracks, isFalse);
      expect(captions.error, isNotNull);
      // A caption failure never touches playback.
      expect(container.read(playbackProvider).error, isNull);
      expect(container.read(playbackProvider).hasVideo, isTrue);
    });

    test('reloads when the video changes', () async {
      await play('vid1');
      await play('vid2');
      expect((await captionLog()).lists, ['vid1', 'vid2']);
    });
  });

  group('selecting a track', () {
    test('fetches it and hands the ASS to the engine', () async {
      await play('vid1');
      await controller.select('.en');
      await settle();

      expect(captions.selectedId, '.en');
      expect(captions.isOn, isTrue);
      expect(engine.subtitle, contains('[Script Info]'));
      // The document that landed is the one that was asked for, not merely some
      // document — the fake writes the track id into its only Dialogue line.
      expect(engine.subtitle, contains('.en'));
      // Task 19 added three optional parameters to `captions.get`, and an
      // untouched session sends none of them — which is itself the claim worth
      // pinning here: turning the style menu and the drag on must not change the
      // request a user who never opened either makes.
      expect((await captionLog()).gets, [
        {
          'videoId': 'vid1',
          'trackId': '.en',
          'style': null,
          'offset': null,
          'hasMetrics': false,
        },
      ]);
    });

    test('switching language replaces the attached track', () async {
      await play('vid1');
      await controller.select('.en');
      await settle();
      await controller.select('a.de');
      await settle();

      expect(captions.selectedId, 'a.de');
      expect(engine.subtitle, contains('a.de'));
      expect(engine.subtitle, isNot(contains(',.en')));
    });

    test('Off detaches', () async {
      await play('vid1');
      await controller.select('.en');
      await settle();
      await controller.select(null);
      await settle();

      expect(captions.isOn, isFalse);
      expect(engine.subtitle, isNull);
    });

    test('opening a new video detaches the previous captions', () async {
      await play('vid1');
      await controller.select('.en');
      await settle();
      expect(engine.subtitle, isNotNull);

      await play('nocaps1');
      // Detached on the way in, not when the new list arrives: the words of the
      // previous video over the picture of the next one is the failure here.
      expect(engine.subtitle, isNull);
      expect(captions.isOn, isFalse);
    });
  });

  group('the session preference', () {
    test('the same language comes back on the next video', () async {
      await play('vid1');
      await controller.select('a.de');
      await settle();
      expect(captions.selectedId, 'a.de');

      await play('vid2');
      await settle();
      expect(captions.selectedId, 'a.de', reason: 'German was chosen, German should resume');
      expect(engine.subtitle, contains('a.de'));
    });

    test('MUTATION: without a preference the next video starts off', () async {
      // The control. If `preferOn` is ignored — the shape a deleted preference
      // check would take — the test above passes for the wrong reason, because
      // resuming *anything* would look like resuming the right thing.
      await play('vid1');
      expect(captions.isOn, isFalse, reason: 'captions are off until asked for');
      await play('vid2');
      await settle();
      expect(captions.isOn, isFalse);
      expect((await captionLog()).gets, isEmpty);
    });

    test('turning captions off is remembered too', () async {
      await play('vid1');
      await controller.select('.en');
      await settle();
      await controller.select(null);

      await play('vid2');
      await settle();
      expect(captions.isOn, isFalse, reason: 'Off is a choice, and it persists');
    });

    test('a video without the preferred language stays off rather than substituting', () async {
      await play('vid1');
      await controller.select('a.de');
      await settle();

      await play('nocaps1');
      await settle();
      expect(captions.isOn, isFalse);
    });
  });

  group('toggle', () {
    test('turns on the first track, then off', () async {
      await play('vid1');
      await controller.toggle();
      await settle();
      expect(captions.selectedId, '.en');

      await controller.toggle();
      await settle();
      expect(captions.isOn, isFalse);
      expect(engine.subtitle, isNull);
    });

    test('prefers the session language over the first track', () async {
      await play('vid1');
      await controller.select('a.de');
      await settle();
      await controller.select(null);

      await controller.toggle();
      await settle();
      expect(captions.selectedId, 'a.de', reason: 'not .en, which is merely first');
    });

    test('does nothing on a video with no tracks', () async {
      await play('nocaps1');
      await controller.toggle();
      await settle();
      expect(captions.isOn, isFalse);
      expect((await captionLog()).gets, isEmpty);
    });
  });

  group('a quality switch', () {
    test('keeps the captions attached', () async {
      await play('vid1');
      await controller.select('.en');
      await settle();

      final before = engine.subtitle;
      final variants = container.read(playbackProvider).variants;
      await container.read(playbackProvider.notifier).switchQuality(variants[2]);
      await settle();

      expect(engine.subtitle, before, reason: 'the reopen must not lose the track');
      // The *sequence* is the claim: dropped by the reopen, then put back. A
      // final-value check alone would pass against an engine that never dropped
      // it, which is not the engine media_kit gives us.
      expect(engine.subtitles.last, isNotNull);
      expect(engine.subtitles, contains(null));
    });

    test('MUTATION: without retainSubtitle the reopen loses them', () async {
      await play('vid1');
      await controller.select('.en');
      await settle();

      // What `switchQuality` would do if the flag were dropped. If `FakeEngine`
      // ever stops modelling the loss, this fails and says so — which is the
      // point: the test above would otherwise be unfailable.
      await engine.open(container.read(playbackProvider).variants[2]);
      expect(engine.subtitle, isNull);
    });

    test('no captions attached means nothing to restore, and no error', () async {
      await play('vid1');
      final variants = container.read(playbackProvider).variants;
      await container.read(playbackProvider.notifier).switchQuality(variants[2]);
      await settle();
      expect(engine.subtitle, isNull);
      expect(container.read(playbackProvider).error, isNull);
    });
  });

  group('the C key', () {
    test('resolves to the captions action', () {
      expect(
        resolvePlayerShortcut(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyC,
          logicalKey: LogicalKeyboardKey.keyC,
          timeStamp: Duration.zero,
        )),
        const PlayerShortcut(PlayerAction.captions),
      );
    });

    test('a key-up is not a press', () {
      expect(
        resolvePlayerShortcut(const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyC,
          logicalKey: LogicalKeyboardKey.keyC,
          timeStamp: Duration.zero,
        )),
        isNull,
      );
    });

    test('Ctrl+C is a copy, not a caption toggle', () async {
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      addTearDown(() => simulateKeyUpEvent(LogicalKeyboardKey.controlLeft));
      expect(
        resolvePlayerShortcut(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyC,
          logicalKey: LogicalKeyboardKey.keyC,
          timeStamp: Duration.zero,
        )),
        isNull,
      );
    });
  });

  group('the styled badge', () {
    test('the video-open path does not pay for it', () async {
      // §3.8 keeps `captions.list` off the open path, and the flag costs a
      // caption document per track. Opening a video must ask the cheap question.
      await play('vid1');
      expect((await captionLog()).lists, ['vid1']);
      expect(captions.tracks.map((t) => t.styled), [null, null]);
      expect(captions.tracks.map((t) => t.styleBadge), [null, null]);
    });

    test('asking fills it in, and says which tracks are styled', () async {
      await play('vid1');
      await controller.loadStyled();
      await settle();
      expect((await captionLog()).lists, ['vid1', 'vid1+styled']);
      expect(captions.tracks.map((t) => t.styled), ['karaoke', 'plain']);
    });

    test('karaoke and styled badge, plain does not', () async {
      await play('vid1');
      await controller.loadStyled();
      await settle();
      expect(captions.tracks.map((t) => t.styleBadge), ['Animated', null]);
    });

    test('a category this build has never heard of badges nothing', () async {
      // A newer sidecar can send one, and a row that printed it raw would show
      // the user a protocol token. Same degradation as hard invariant 4.
      const track = CaptionTrack(
        id: '.en',
        languageCode: 'en',
        label: 'English',
        isAutoGenerated: false,
        styled: 'lyrics-3d-rotating',
      );
      expect(track.styleBadge, isNull);
    });

    test('trackName arrives, and is empty when YouTube sends none', () async {
      await play('vid1');
      expect(captions.tracks.map((t) => t.trackName), ['Commentary', '']);
    });

    test('asking twice costs one fetch', () async {
      // The menu can be opened repeatedly; every track already has an answer
      // after the first, so there is nothing left to ask.
      await play('vid1');
      await controller.loadStyled();
      await settle();
      await controller.loadStyled();
      await settle();
      expect((await captionLog()).lists.where((l) => l == 'vid1+styled'), hasLength(1));
    });

    test('a video with no tracks asks nothing', () async {
      await play('nocaps1');
      await controller.loadStyled();
      await settle();
      expect((await captionLog()).lists, ['nocaps1']);
    });
  });

  group('the two settings that decide who draws a caption', () {
    // Everything else in this file runs against a `FakeEngine`, which is what
    // makes it testable and also what let this ship broken: the ASS reached the
    // engine correctly for two tasks while media_kit's defaults threw all of its
    // styling away. See `MediaKitEngine`'s [kNoFlutterSubtitles] for the
    // mechanism. These pin the values; only running the app pins that they are
    // still passed, so treat a failure here as "someone reverted the fix" and
    // not as coverage of the wiring.

    test('libass is on, so mpv renders captions instead of stripping them', () {
      // `false` — media_kit's default — sets `sub-ass=no` *and*
      // `sub-visibility=no`, so mpv discards every override and then draws
      // nothing at all.
      expect(kLibassEnabled, isTrue);
    });

    test("Flutter's subtitle view is off, so it is not a second renderer", () {
      // `visible: true` — media_kit's default — paints mpv's tag-stripped
      // `sub-text` in a Flutter `TextStyle` on top of the video. With libass now
      // on, leaving this would draw every caption twice in two different fonts.
      expect(kNoFlutterSubtitles.visible, isFalse);
    });
  });
}
