import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/player/volume_bar.dart';

void main() {
  int circles(WidgetTester tester) {
    final canvas = TestRecordingCanvas();
    tester.renderObject(find.byType(CustomPaint).last).paint(TestRecordingPaintingContext(canvas), Offset.zero);
    return canvas.invocations.where((call) => call.invocation.memberName == #drawCircle).length;
  }

  testWidgets('the pointer is a click over the bar, and a halo grows only on the thumb', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRillTheme(Colors.blue),
        home: const Scaffold(
          body: Center(
            child: SizedBox(width: 200, height: 40, child: VolumeBar(value: 50, onChanged: _ignore)),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(VolumeBar));
    // The track runs 10 px in from each end, so 50% is the middle of the box.
    final thumb = origin + const Offset(100, 20);
    final away = origin + const Offset(170, 20);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(away);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);
    expect(circles(tester), 1, reason: 'just the thumb, away from it');

    await mouse.moveTo(thumb);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(circles(tester), 2, reason: 'the thumb and its halo, on it');

    await mouse.moveTo(away);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(circles(tester), 1, reason: 'and the halo goes when the pointer does');
  });
}

void _ignore(double _) {}
