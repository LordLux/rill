import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/player/volume_bar.dart';

/// The hover cues on the volume bar: a halo anywhere on it, the thumb swelling and the click cursor
/// on the thumb alone.
void main() {
  const barKey = ValueKey('bar');

  Future<void> pumpBar(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: buildRillTheme(kDefaultAccent),
      home: Scaffold(
        body: Center(
          child: SizedBox(key: barKey, width: 120, child: VolumeBar(value: 50, onChanged: (_) {})),
        ),
      ),
    ),
  );

  /// The radii of every circle the bar paints.
  List<double> radii(WidgetTester tester) {
    final canvas = TestRecordingCanvas();
    final box = tester.renderObject(find.descendant(of: find.byKey(barKey), matching: find.byType(CustomPaint)).first);
    box.paint(TestRecordingPaintingContext(canvas), Offset.zero);
    return [
      for (final call in canvas.invocations)
        if (call.invocation.memberName == #drawCircle) call.invocation.positionalArguments[1] as double,
    ];
  }

  /// Hover, and let the animation run: it starts on the first frame and then takes 120 ms.
  Future<void> hover(WidgetTester tester, TestGesture mouse, Offset at) async {
    await mouse.moveTo(at);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the halo is anywhere on the bar, the swelling and the cursor only on the thumb', (tester) async {
    await pumpBar(tester);
    final rect = tester.getRect(find.byKey(barKey));
    final centreY = rect.center.dy;
    final thumbX = rect.left + 10 + (rect.width - 20) * 0.5;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);

    expect(radii(tester), [6.0], reason: 'at rest, just the thumb');

    await hover(tester, mouse, Offset(rect.left + 15, centreY));
    expect(radii(tester), hasLength(2), reason: 'a halo on any part of the bar');
    expect(radii(tester).last, 6.0, reason: 'but the thumb has not swollen');
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), isNot(SystemMouseCursors.click));

    await hover(tester, mouse, Offset(thumbX, centreY));
    expect(radii(tester), hasLength(2));
    expect(radii(tester).last, greaterThan(6.0), reason: 'the thumb swells under the pointer');
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);

    await hover(tester, mouse, const Offset(1, 1));
    expect(radii(tester), [6.0], reason: 'and all of it goes when the pointer leaves');
  });
}
