/// Task 19 — the style menu and the drag.
///
/// Against the same real sidecar process `captions_test.dart` uses, so the
/// claims here are about what the app actually put on the wire. Whether the
/// *sidecar* then renders it correctly is `sidecar/test/captions.test.ts`'s
/// business, against the real renderer; splitting it that way is what keeps
/// either side from asserting its own idea of the other's behaviour.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/caption_style.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/captions_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/caption_geometry.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

VideoItem _video(String id) => VideoItem(
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
  container.read(captionsProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

Future<void> play(String id) async {
  container.read(queueProvider.notifier).play(_video(id));
  await settle();
}

CaptionsState get captions => container.read(captionsProvider);
CaptionsController get controller => container.read(captionsProvider.notifier);

Future<List<dynamic>> gets() async {
  final response = await RpcClient.instance.call('test.captionLog', {}) as Map<String, dynamic>;
  return response['gets'] as List<dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(boot);
  tearDown(() {
    container.dispose();
    RpcClient.instance.killForTest();
  });

  group('the style menu', () {
    test('nothing is sent until something is set', () async {
      await play('a');
      await controller.select('.en');
      await settle();
      final log = await gets();
      expect(log.last['style'], isNull, reason: 'an untouched menu adds nothing to the request');
      expect(log.last['offset'], isNull);
    });

    test('a discrete control commits immediately and regenerates the document', () async {
      await play('a');
      await controller.select('.en');
      final before = (await gets()).length;

      await controller.setStyle(
        const CaptionStyle(edgeStyle: CaptionEdgeStyle.outline),
        immediate: true,
      );
      await settle();

      final log = await gets();
      expect(log.length, before + 1, reason: 'the document is re-rendered, not patched in mpv');
      expect((log.last['style'] as Map)['edgeStyle'], 'outline');
      // And it reached the player. The whole point of regenerating rather than
      // setting an mpv property is that the *document* changes.
      expect(engine.subtitles.last, isNotNull);
    });

    test('a colour change notifies watchers twice: the style write and the fetch landing',
        () async {
      // The bug this guards: `_fetch`'s last write was `state.copyWith(tracks:
      // newTracks, isLoadingTrack: false)`. On a track whose styled/positional
      // classification doesn't change (the common case — nothing here reclassifies
      // it), `newTracks` is null and `isLoadingTrack` was already false, so that
      // write produced a `CaptionsState` equal to the one already there.
      // Riverpod does not notify on a `state = value` that equals the previous
      // state, so `LibassLayer` — which only looks at `engine.subtitle` inside a
      // build triggered by watching this provider — was never told a new document
      // had landed. It kept showing whatever was on screen until some *other*,
      // later field change dragged a rebuild along with it: "one step behind".
      //
      // A single `setStyle(..., immediate: true)` call makes *two* writes:
      // `state = state.copyWith(style: style)` at the top (always notifies,
      // since `style` itself changed — this is why a test that only checks "did
      // it notify at all" cannot catch the bug, that write always passes) and
      // the tail write once the fetch lands (notifies only with the
      // `documentVersion` fix). So the real assertion is the *count within one
      // call*, not just whether it moved off zero.
      await play('a');
      await controller.select('.en');
      await settle();

      var notifications = 0;
      final sub = container.listen(captionsProvider, (previous, next) => notifications++);
      addTearDown(sub.close);

      await controller.setStyle(
        const CaptionStyle(textColor: Color(0xFF4CAF50)),
        immediate: true,
      );
      await settle();
      expect(notifications, 2,
          reason: 'one for the style field itself, one for the fetched document landing — '
              'without the second, LibassLayer is never told to look at engine.subtitle again');

      notifications = 0;
      await controller.setStyle(
        const CaptionStyle(textColor: Color(0xFFFFEB3B)),
        immediate: true,
      );
      await settle();
      expect(notifications, 2, reason: 'the second colour change must land the same way');
    });

    test('slider input is debounced into one commit, not one per frame', () async {
      // A colour or opacity slider fires per frame, and each change costs a
      // round trip plus a `sub-add`. Without the debounce a single drag would
      // queue sixty of them.
      await play('a');
      await controller.select('.en');
      final before = (await gets()).length;

      for (var step = 1; step <= 8; step++) {
        unawaited(controller.setStyle(CaptionStyle(fontSizePercent: 100 + step * 10.0)));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await settle(400);

      final log = await gets();
      expect(log.length - before, lessThan(4),
          reason: 'eight slider frames must not be eight round trips');
      expect((log.last['style'] as Map)['fontSizePercent'], 180,
          reason: 'and the value that lands is the last one, not an early one');
    });

    test('three separate, fully-settled slider commits each carry their own value', () async {
      // Reported: opacity 100 -> 0 does nothing; then 0 -> 50 shows 0; then
      // 50 -> 100 shows 50 — every commit one step behind the one before it.
      // Each step here is `immediate: false` (what the opacity slider actually
      // passes) and is awaited to full settle before the next starts, so this
      // is not the debounce-collapsing-a-burst case above — each is its own
      // independent, completed action.
      await play('a');
      await controller.select('.en');

      await controller.setStyle(const CaptionStyle(textOpacity: 0));
      await settle();
      expect((await gets()).last['style'], isNotNull, reason: 'a default-null->0 change is not a no-op');
      expect(((await gets()).last['style'] as Map)['textOpacity'], 0,
          reason: 'the first commit must carry 0, not be dropped as a no-op');

      await controller.setStyle(const CaptionStyle(textOpacity: 0.5));
      await settle();
      expect(((await gets()).last['style'] as Map)['textOpacity'], 0.5,
          reason: 'the second commit must carry 0.5, not the previous 0');

      await controller.setStyle(const CaptionStyle(textOpacity: 1));
      await settle();
      expect(((await gets()).last['style'] as Map)['textOpacity'], 1,
          reason: 'the third commit must carry 1, not the previous 0.5');
    });

    // A widget-level version of the test above — real controller, real
    // `PlayerSettingsMenu`, real 120ms debounce — was tried and dropped: it
    // hung `flutter test` for the full 10-minute test timeout rather than
    // failing or passing. `testWidgets`'s pumped clock and a real RPC
    // subprocess's genuine async I/O do not mix reliably in this harness;
    // `settings_menu_test.dart`'s widget tests avoid it by never using real
    // RPC, and this file's real-RPC tests avoid it by never pumping a widget.
    // Combining both is the one thing neither file does, and it is not a
    // fixable test — it needs a different harness, not a longer timeout.

    test('the style survives a track change and a video change', () async {
      // It is a session preference, like the chosen language. Someone who turned
      // the background off wants it off on the next video too.
      await play('a');
      await controller.select('.en');
      await controller.setStyle(const CaptionStyle(fontFamily: 'Georgia'), immediate: true);
      await settle();

      await controller.select('a.de');
      await settle();
      expect((( await gets()).last['style'] as Map)['fontFamily'], 'Georgia');

      await play('b');
      await controller.select('.en');
      await settle();
      expect(captions.style.fontFamily, 'Georgia');
      expect(((await gets()).last['style'] as Map)['fontFamily'], 'Georgia');
    });

    test('reset clears the style and the drag together', () async {
      await play('a');
      await controller.select('.en');
      await controller.setStyle(const CaptionStyle(fontFamily: 'Georgia'), immediate: true);
      await controller.setOffset(const CaptionOffset(0.2, -0.3));
      await settle();

      await controller.resetStyle();
      await settle();

      expect(captions.style.isDefault, isTrue);
      expect(captions.offset.isZero, isTrue);
      final log = await gets();
      expect(log.last['style'], isNull);
      expect(log.last['offset'], isNull);
    });
  });

  group('the drag offset', () {
    test('a commit sends the delta, and nothing else', () async {
      await play('a');
      await controller.select('.en');
      await controller.setOffset(const CaptionOffset(0.1, -0.2));
      await settle();

      final last = (await gets()).last;
      expect((last['offset'] as Map)['dx'], closeTo(0.1, 1e-9));
      expect((last['offset'] as Map)['dy'], closeTo(-0.2, 1e-9));
      // A drag used to carry a measured width table so the sidecar could clamp
      // the position against an estimate of the text. `LibassLayer` clamps
      // against the boxes libass actually produced, so the delta is the whole
      // message and there is no second instrument to keep in step with it.
      expect(last['hasMetrics'], isFalse);
    });

    test('it resets when the track changes and survives captions off and on', () async {
      await play('a');
      await controller.select('.en');
      await controller.setOffset(const CaptionOffset(0.1, 0.1));
      await settle();

      // Off and on again: the one continuity a user notices.
      await controller.select(null);
      await controller.select('.en');
      await settle();
      expect(captions.offset, const CaptionOffset(0.1, 0.1));

      // A different track puts its lines somewhere else entirely, so a position
      // chosen for one means nothing on the other.
      await controller.select('a.de');
      await settle();
      expect(captions.offset.isZero, isTrue);
    });

    test('a new video starts from the default position', () async {
      await play('a');
      await controller.select('.en');
      await controller.setOffset(const CaptionOffset(0.3, 0.3));
      await settle();

      await play('b');
      await settle();
      expect(captions.offset.isZero, isTrue);
    });
  });

  group('the video rectangle', () {
    // What is left of `caption_geometry.dart` after phase 5. The per-character
    // width table, the predicted caption rectangle and the clamp built on both
    // were retired with the mpv pipeline that needed them: `LibassLayer` reads
    // the real boxes out of `ass_render_frame`, so there is nothing left to
    // estimate. Letterboxing is the one piece of geometry that was never an
    // estimate, and it is still the client's to work out.
    test('the video rectangle is the picture, not the widget', () {
      // media_kit letterboxes the texture, so a caption placed against the
      // widget's own bounds drifts on every aspect ratio but the window's.
      final wide = videoRectIn(const Size(1600, 900), 16 / 9);
      expect(wide, const Rect.fromLTWH(0, 0, 1600, 900));

      final pillarboxed = videoRectIn(const Size(1600, 900), 4 / 3);
      expect(pillarboxed.height, 900);
      expect(pillarboxed.width, closeTo(1200, 0.001));
      expect(pillarboxed.left, closeTo(200, 0.001));

      final letterboxed = videoRectIn(const Size(1600, 900), 21 / 9);
      expect(letterboxed.width, 1600);
      expect(letterboxed.top, greaterThan(0));
    });

    test('a degenerate aspect ratio fills the box rather than vanishing', () {
      expect(videoRectIn(const Size(800, 600), 0), const Rect.fromLTWH(0, 0, 800, 600));
      expect(
        videoRectIn(const Size(800, 600), double.nan),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
    });
  });
}
