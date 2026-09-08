/// The parts of task 16 that are decisions rather than widgets.
///
/// Split out from `player_controls_test.dart` because these run in
/// microseconds and need neither a tree nor a sidecar — and because a key map
/// and a ladder search are exactly the sort of thing that is easier to get
/// wrong than to notice through a screenshot.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/playback_source.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/controls.dart';
import 'package:rill/ui/player/shortcuts.dart';
import 'package:rill/ui/queue_controller.dart';

PlaybackVariant variant(int height, {int fps = 60}) => PlaybackVariant(
      videoUrl: 'https://fake.invalid/$height',
      audioUrl: 'https://fake.invalid/audio',
      height: height,
      fps: fps,
      videoCodec: 'vp9',
      audioCodec: 'opus',
    );

VideoItem item(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: id,
      channelName: 'c',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: false,
      canAddToQueue: false,
    );

/// Keeps `HardwareKeyboard` from asserting on a synthesised modifier press that
/// nothing else in the tree claims.
bool _swallow(KeyEvent event) => true;

void main() {
  // `resolvePlayerShortcut` asks `HardwareKeyboard.instance` about the modifier
  // keys, and that getter needs a binding even though nothing here pumps a
  // widget.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('variantFor', () {
    final ladder = [variant(2160), variant(1080), variant(720, fps: 30), variant(360, fps: 30)];

    test('no preference takes the sidecar ranking', () {
      expect(variantFor(ladder, null)?.height, 2160);
    });

    test('a preference takes the best rung at or under it', () {
      expect(variantFor(ladder, 1080)?.height, 1080);
      expect(variantFor(ladder, 1000)?.height, 720,
          reason: 'at or under, never over — 1080 is not "at or under" 1000');
    });

    test('a preference below every rung takes the smallest, not the largest', () {
      // The failure worth pinning: falling back to `variants.first` here would
      // answer a 240p preference with 2160p, which is the furthest possible
      // answer from what was asked for and exactly what F16 says costs frames.
      expect(variantFor([variant(2160), variant(1080)], 240)?.height, 1080);
    });

    test('an empty ladder is null rather than a crash', () {
      expect(variantFor(const [], 1080), isNull);
      expect(variantFor(const [], null), isNull);
    });
  });

  group('describeVariant', () {
    test('fps only when it is worth saying', () {
      expect(describeVariant(variant(1080)), '1080p60');
      expect(describeVariant(variant(720, fps: 30)), '720p');
    });
  });

  group('distinctQualities', () {
    test('one row per height and fps, keeping the best-ranked of each', () {
      // The shape a real ladder has: `aqz-KE-bpKQ` resolved to 22 rungs on
      // 2026-08-12, the same four or five resolutions in several codecs.
      final ladder = [
        variant(2160),
        variant(2160),
        variant(1080),
        variant(1080),
        variant(1080),
        variant(720, fps: 30),
      ];
      final menu = distinctQualities(ladder);
      expect(menu.map(describeVariant), ['2160p60', '1080p60', '720p']);
      expect(identical(menu[1], ladder[2]), isTrue,
          reason: 'the first of each group — the one the sidecar ranked highest');
    });

    test('the same height at different frame rates is two rows, not one', () {
      final menu = distinctQualities([variant(1080), variant(1080, fps: 30)]);
      expect(menu.map(describeVariant), ['1080p60', '1080p']);
    });

    test('an empty ladder collapses to nothing', () {
      expect(distinctQualities(const []), isEmpty);
    });
  });

  group('resolvePlayerShortcut', () {
    PlayerShortcut? resolve(LogicalKeyboardKey key) =>
        resolvePlayerShortcut(KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: key,
          timeStamp: Duration.zero,
        ));

    /// The same press with Shift genuinely held, rather than with a `<` handed
    /// in and hoped over: the Shift branch reads `HardwareKeyboard`, so a test
    /// that only swapped the logical key would pass against a deleted check.
    PlayerShortcut? resolveShifted(LogicalKeyboardKey key) {
      HardwareKeyboard.instance.addHandler(_swallow);
      addTearDown(() => HardwareKeyboard.instance.removeHandler(_swallow));
      final shift = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.shiftLeft,
        logicalKey: LogicalKeyboardKey.shiftLeft,
        timeStamp: Duration.zero,
      );
      HardwareKeyboard.instance.handleKeyEvent(shift);
      try {
        return resolve(key);
      } finally {
        HardwareKeyboard.instance.handleKeyEvent(KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.shiftLeft,
          logicalKey: LogicalKeyboardKey.shiftLeft,
          timeStamp: Duration.zero,
        ));
      }
    }

    test('the whole table', () {
      expect(resolve(LogicalKeyboardKey.space)?.action, PlayerAction.playPause);
      expect(resolve(LogicalKeyboardKey.keyK)?.action, PlayerAction.playPause);
      expect(resolve(LogicalKeyboardKey.arrowLeft),
          const PlayerShortcut(PlayerAction.seekBackward, seconds: 5));
      expect(resolve(LogicalKeyboardKey.arrowRight),
          const PlayerShortcut(PlayerAction.seekForward, seconds: 5));
      expect(resolve(LogicalKeyboardKey.keyJ),
          const PlayerShortcut(PlayerAction.seekBackward, seconds: 10));
      expect(resolve(LogicalKeyboardKey.keyL),
          const PlayerShortcut(PlayerAction.seekForward, seconds: 10));
      expect(resolve(LogicalKeyboardKey.arrowUp)?.action, PlayerAction.volumeUp);
      expect(resolve(LogicalKeyboardKey.arrowDown)?.action, PlayerAction.volumeDown);
      expect(resolve(LogicalKeyboardKey.keyM)?.action, PlayerAction.mute);
      expect(resolve(LogicalKeyboardKey.keyF)?.action, PlayerAction.fullscreen);
      expect(resolve(LogicalKeyboardKey.keyT)?.action, PlayerAction.theatre);
      expect(resolve(LogicalKeyboardKey.keyC)?.action, PlayerAction.toggleCaptions);
      expect(resolve(LogicalKeyboardKey.escape)?.action, PlayerAction.escape);
      expect(resolve(LogicalKeyboardKey.keyI)?.action, PlayerAction.miniPlayer);
    });

    test('Shift + N and Shift + P are the queue; bare N and P are nobody\'s', () {
      expect(resolveShifted(LogicalKeyboardKey.keyN)?.action, PlayerAction.next);
      expect(resolveShifted(LogicalKeyboardKey.keyP)?.action, PlayerAction.previous);
      expect(resolve(LogicalKeyboardKey.keyN), isNull);
      expect(resolve(LogicalKeyboardKey.keyP), isNull);
    });

    test('comma and period step one frame', () {
      expect(resolve(LogicalKeyboardKey.comma)?.action, PlayerAction.frameBackward);
      expect(resolve(LogicalKeyboardKey.period)?.action, PlayerAction.frameForward);
    });

    test('with Shift they are one second, in both spellings of the key', () {
      // A US layout reports `<` and `>`; others report `,` and `.` with the
      // shift flag. Both have to reach the same place or the row of the table
      // works on one keyboard and silently not on another.
      expect(resolveShifted(LogicalKeyboardKey.less),
          const PlayerShortcut(PlayerAction.seekBackward, seconds: 1));
      expect(resolveShifted(LogicalKeyboardKey.greater),
          const PlayerShortcut(PlayerAction.seekForward, seconds: 1));
      expect(resolveShifted(LogicalKeyboardKey.comma),
          const PlayerShortcut(PlayerAction.seekBackward, seconds: 1));
      expect(resolveShifted(LogicalKeyboardKey.period),
          const PlayerShortcut(PlayerAction.seekForward, seconds: 1));
    });

    test('every decile, on both rows of the keyboard', () {
      expect(resolve(LogicalKeyboardKey.digit0)?.decile, 0);
      expect(resolve(LogicalKeyboardKey.digit7)?.decile, 7);
      expect(resolve(LogicalKeyboardKey.digit9)?.decile, 9);
      expect(resolve(LogicalKeyboardKey.numpad3)?.decile, 3);
      expect(resolve(LogicalKeyboardKey.numpad0)?.decile, 0);
    });

    test('keys that are not shortcuts stay unclaimed', () {
      expect(resolve(LogicalKeyboardKey.keyQ), isNull);
      expect(resolve(LogicalKeyboardKey.enter), isNull);
      expect(resolve(LogicalKeyboardKey.tab), isNull);
    });

    test('a key up is not a shortcut', () {
      // Otherwise every press fires twice, and every seek is two seeks — at
      // F15's 1.2–1.3 s each.
      final up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyF,
        logicalKey: LogicalKeyboardKey.keyF,
        timeStamp: Duration.zero,
      );
      expect(resolvePlayerShortcut(up), isNull);
    });

    test('a repeat is not a shortcut either', () {
      final repeat = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.arrowRight,
        logicalKey: LogicalKeyboardKey.arrowRight,
        timeStamp: Duration.zero,
      );
      expect(resolvePlayerShortcut(repeat), isNull,
          reason: 'a held arrow key would queue one 1.2 s seek per repeat');
    });
  });

  group('the queue at its ends', () {
    test('previous and next stop rather than wrapping', () {
      var queue = QueueState()
          .appended(item('a'))
          .appended(item('b'))
          .appended(item('c'));
      expect(queue.currentIndex, 0);
      expect(queue.hasPrevious, isFalse, reason: 'nothing before the first');
      expect(queue.hasNext, isTrue);

      // Walking off the front is a no-op, not a jump to the back.
      expect(queue.reversed().currentIndex, 0);

      queue = queue.advanced().advanced();
      expect(queue.currentIndex, 2);
      expect(queue.hasNext, isFalse, reason: 'nothing after the last');
      expect(queue.hasPrevious, isTrue);
      expect(queue.advanced().currentIndex, 2, reason: 'and walking off the back is a no-op too');

      expect(queue.reversed().currentIndex, 1);
    });

    test('an empty queue has neither end', () {
      final queue = QueueState();
      expect(queue.hasPrevious, isFalse);
      expect(queue.hasNext, isFalse);
      expect(queue.reversed().currentIndex, isNull);
    });
  });

  group('formatClock', () {
    test('minutes, and hours when there are any', () {
      expect(formatClock(const Duration(seconds: 9)), '0:09');
      expect(formatClock(const Duration(minutes: 3, seconds: 7)), '3:07');
      expect(formatClock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    });
  });
}
