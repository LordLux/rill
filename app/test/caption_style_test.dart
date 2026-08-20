/// Task 19 — the style menu, the drag, and the width estimate.
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

/// The layout the fake sidecar reports — the real numbers from `ass.ts`.
const CaptionLayout _layout = CaptionLayout(
  fontFamily: 'Arial',
  fontSize: 48,
  playResX: 1920,
  playResY: 1080,
  margin: 60,
  outlineWidth: 2.5,
  boxPadding: 6,
  defaultAlignment: 2,
  defaultX: 960,
  defaultY: 1020,
  lineSpacing: 1.2,
);

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
    test('a commit sends the delta and the width table with it', () async {
      await play('a');
      await controller.select('.en');
      await controller.setOffset(const CaptionOffset(0.1, -0.2));
      await settle();

      final last = (await gets()).last;
      expect((last['offset'] as Map)['dx'], closeTo(0.1, 1e-9));
      expect((last['offset'] as Map)['dy'], closeTo(-0.2, 1e-9));
      // The table only matters to the clamp, and the clamp only runs when the
      // caption has been dragged — so it rides with the offset and not on its own.
      expect(last['hasMetrics'], isTrue);
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

    test('the width table is measured once and reused', () async {
      await play('a');
      await controller.select('.en');
      await settle();
      final first = captions.metrics;
      expect(first, isNotNull);

      await controller.setOffset(const CaptionOffset(0.1, 0));
      await settle();
      expect(identical(captions.metrics, first), isTrue,
          reason: '74 TextPainter layouts per commit would be a real cost for no answer');
    });
  });

  group('the width estimate', () {
    test('it is a per-character table, summed per line', () {
      // **`flutter test` renders with a fixed-width test font**, so nothing here
      // can assert that `W` is wider than `i` — every glyph measures the same.
      // That claim belongs where the real font is: measured through the bundled
      // libass in `sidecar/scratch/measure-advances.ts` (8.3 px to 40.5 px at
      // Arial 48, a 4.9x range, which is what rules out a single
      // pixels-per-character number), and asserted against the shipped table in
      // `sidecar/test/captions.test.ts`. What is testable here is the shape: one
      // entry per character, and a width that is their sum.
      final metrics = measureAdvances(_layout);
      expect(metrics.advances, isNotEmpty);
      expect(metrics.fallbackAdvance, greaterThan(0));
      expect(metrics.widthOf('aaa'), closeTo(3 * metrics.advances['a']!, 1e-6));
      expect(metrics.widthOf('unmeasurable 一'),
          greaterThanOrEqualTo(metrics.fallbackAdvance));
    });

    test('the widest line wins, not the total', () {
      final metrics = measureAdvances(_layout);
      expect(metrics.widthOf('aa\nbbbb'), metrics.widthOf('bbbb'));
    });

    test('the clamp keeps the whole caption inside the frame', () {
      final metrics = measureAdvances(_layout);
      // Short enough to fit under the test font's fixed-width glyphs, which are
      // much wider than Arial's — a realistic caption string would be past the
      // frame here and would be testing the overflow branch below instead.
      final size = captionSize(text: 'hello', layout: _layout, metrics: metrics);
      expect(size.width, lessThan(_layout.playResX),
          reason: 'otherwise this measures the pinning rule, not the clamp');

      // Dragged well past the bottom-right corner.
      final clamped = clampedOffset(
        proposed: const CaptionOffset(0.5, 0.5),
        captionSize: size,
        layout: _layout,
        alignment: _layout.defaultAlignment,
      );
      final anchorX = _layout.defaultX + clamped.dx * _layout.playResX;
      final anchorY = _layout.defaultY + clamped.dy * _layout.playResY;
      expect(anchorX + size.width / 2, lessThanOrEqualTo(_layout.playResX));
      expect(anchorY, lessThanOrEqualTo(_layout.playResY));
    });

    test('a caption wider than the frame is pinned to the left, not centred', () {
      // The one case the clamp cannot satisfy. libass wraps a positioned line at
      // the frame width, so whenever the estimate exceeds the frame the real
      // text is narrower than it — and pinning the start on screen is the useful
      // failure. Centring it would hide the beginning of the line.
      final metrics = measureAdvances(_layout);
      final huge = Size(_layout.playResX * 2, 60);
      final clamped = clampedOffset(
        proposed: const CaptionOffset(0.5, 0),
        captionSize: huge,
        layout: _layout,
        alignment: _layout.defaultAlignment,
      );
      final left = _layout.defaultX + clamped.dx * _layout.playResX - huge.width / 2;
      expect(left, closeTo(_layout.boxPadding, 0.001));
      expect(metrics.advances, isNotEmpty);
    });

    test('a longer caption is pushed further in than a shorter one', () {
      // The requirement in the user's own words: drag one into the corner, and a
      // longer line that follows has to come back in to fit.
      final metrics = measureAdvances(_layout);
      CaptionOffset at(String text) => clampedOffset(
            proposed: const CaptionOffset(0.5, 0.5),
            captionSize: captionSize(text: text, layout: _layout, metrics: metrics),
            layout: _layout,
            alignment: _layout.defaultAlignment,
          );
      // Both short enough to fit the frame under the test font — see the clamp
      // test above for why the strings are not realistic caption lines.
      expect(at('hi there you').dx, lessThan(at('hi').dx));
    });

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

    test('the hit rectangle follows the drag', () {
      final metrics = measureAdvances(_layout);
      Rect rect(CaptionOffset offset) => captionRect(
            text: 'a caption',
            layout: _layout,
            metrics: metrics,
            offset: offset,
            video: const Rect.fromLTWH(0, 0, 1920, 1080),
          )!;
      final home = rect(CaptionOffset.zero);
      final moved = rect(const CaptionOffset(0.1, -0.1));
      expect(moved.left - home.left, closeTo(192, 0.001));
      expect(moved.top - home.top, closeTo(-108, 0.001));
      // Bottom-centred on the default anchor, which is where an undragged,
      // unpositioned cue lands.
      expect(home.center.dx, closeTo(960, 0.001));
      expect(home.bottom, closeTo(1020, 0.001));
    });
  });
}
