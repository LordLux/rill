/// Measurement probe, not a regression test — see `test/README.md`.
///
/// `probe_blur_edges.dart` measured a bare blurred square. This one measures
/// the artist panel's **actual** backdrop composition — fractional box, two
/// nested gradient masks, blurred image, all over the tint — because the two
/// disagree about what is safe, and the widget is what ships.
///
/// The artwork stands in as a horizontal ramp from dark navy on the left to
/// bright cyan on the right, which is the case that matters: a blur that
/// repeats edge pixels turns a dark left column into a solid dark bar.
///
/// Reads a horizontal scan across the backdrop's left boundary and a vertical
/// one across its top, reporting how far each pixel sits from the tint. A
/// clean bleed rises smoothly from 0; an artefact is a spike or a step.
///
/// Run: flutter test test/probe_backdrop_edge.dart --reporter expanded
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double _kCard = 400; // square card, so both axes are readable at once
const Color _kTint = Color(0xFF0C5B78); // Ado's measured dark tint
const double _kSigma = 4;

/// Artwork with a deliberately dark left edge and a bright right one.
Future<ui.Image> _rampImage() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 600, 176),
    Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF101F3C), Color(0xFF7FF0FF)],
      ).createShader(const Rect.fromLTWH(0, 0, 600, 176)),
  );
  return recorder.endRecording().toImage(600, 176);
}

/// The shipping composition, with the blur strategy and the clip placement
/// as the variables.
///
/// `tightClip` is the one that matters: a `ShaderMask` masks only within its
/// own rect, and a blurred layer paints *past* that rect, so whatever escapes
/// is composited unmasked. Clipping inside the fractional box is what stops
/// anything escaping in the first place.
Widget _bleed(ui.Image image, {required TileMode tileMode, required bool tightClip}) {
  Widget masked = ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (bounds) => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF000000), Color(0x00000000)],
      stops: [0.45, 1.0],
    ).createShader(bounds),
    child: ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Color(0x00000000), Color(0xB0000000)],
        stops: [0.0, 0.75],
      ).createShader(bounds),
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: _kSigma,
          sigmaY: _kSigma,
          tileMode: tileMode,
        ),
        child: RawImage(image: image, fit: BoxFit.cover, alignment: Alignment.topCenter),
      ),
    ),
  );

  if (tightClip) masked = ClipRect(child: masked);

  final box = FractionallySizedBox(
    alignment: Alignment.topRight,
    widthFactor: 0.52,
    heightFactor: 0.52,
    child: masked,
  );

  // The loose case: a clip the size of the whole card, which cannot contain
  // anything the fractional box's child paints outside itself.
  return tightClip ? box : ClipRect(child: box);
}

void main() {
  testWidgets('scan the backdrop boundaries in the real composition', (tester) async {
    tester.view.physicalSize = const Size(_kCard, _kCard);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final ui.Image art;
    await tester.runAsync(() async {
      art = await _rampImage();
    });

    final cases = <String, Widget>{
      'decal/looseClip': _bleed(art, tileMode: TileMode.decal, tightClip: false),
      'clamp/looseClip': _bleed(art, tileMode: TileMode.clamp, tightClip: false),
      'decal/tightClip': _bleed(art, tileMode: TileMode.decal, tightClip: true),
      'clamp/tightClip': _bleed(art, tileMode: TileMode.clamp, tightClip: true),
    };

    for (final entry in cases.entries) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            child: Container(
              width: _kCard,
              height: _kCard,
              color: _kTint,
              child: Stack(children: [Positioned.fill(child: entry.value)]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);

      late final ByteData? bytes;
      var w = 0;
      await tester.runAsync(() async {
        final captured = await boundary.toImage();
        w = captured.width;
        bytes = await captured.toByteData(format: ui.ImageByteFormat.rawRgba);
      });
      if (bytes == null) continue;

      final data = bytes!.buffer.asUint8List();

      /// How far a pixel is from the flat tint, summed over RGB. 0 is the
      /// bare card; anything above is backdrop showing through.
      int deltaAt(int x, int y) {
        final i = (y * w + x) * 4;
        return (data[i] - 12).abs() + (data[i + 1] - 91).abs() + (data[i + 2] - 120).abs();
      }

      final leftEdge = (w * 0.48).round();
      final horizontal = <String>[];
      for (var offset = -8; offset <= 16; offset += 2) {
        horizontal.add('$offset:${deltaAt(leftEdge + offset, (w * 0.20).round())}');
      }

      // The worst single jump between neighbouring pixels across that
      // boundary — a smooth ramp steps a little, a hard bar steps a lot.
      var worstStep = 0;
      for (var x = leftEdge - 8; x < leftEdge + 16; x++) {
        final step = (deltaAt(x + 1, (w * 0.20).round()) - deltaAt(x, (w * 0.20).round())).abs();
        worstStep = math.max(worstStep, step);
      }

      // The top edge is the card's own boundary, so there is no outside to
      // scan — a rim there shows as the artwork failing to reach y=0, which
      // reads as tint where artwork should be.
      final vertical = <String>[];
      for (var y = 0; y <= 12; y += 2) {
        vertical.add('$y:${deltaAt((w * 0.75).round(), y)}');
      }

      debugPrint(
        '${entry.key.padRight(17)} worstStepLeft=${worstStep.toString().padLeft(3)}  '
        'left[${horizontal.join(' ')}]  top[${vertical.join(' ')}]',
      );
    }
  });
}
