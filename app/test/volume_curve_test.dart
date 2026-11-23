/// The volume control's curve (`data/playback/volume_curve.dart`, `architecture.md` §2.7).
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/playback/volume_curve.dart';

/// The amplitude mpv plays a setting at: (volume / 100)³.
double amplitude(double setting) => math.pow(mpvVolumeFor(setting) / 100, 3).toDouble();

/// The same in dB.
double db(double setting) => 20 * math.log(amplitude(setting)) / math.ln10;

void main() {
  test('the ends: 100 is the level as it comes, 0 is silence', () {
    expect(mpvVolumeFor(100), 100);
    expect(mpvVolumeFor(0), 0);
    expect(mpvVolumeFor(-5), 0);
    expect(mpvVolumeFor(130), 100, reason: 'never louder than mpv unscaled');
  });

  test('the setting squared is the amplitude: 50 is 12 dB down', () {
    // MUTATION: `return setting;` (the old straight write, which mpv cubes) fails here — 50 was 18 dB
    // down; and youtube.com's curve, `volumePower = 1`, puts 50 at 6.
    for (var s = 5.0; s <= 100; s += 5) {
      expect(amplitude(s), closeTo(math.pow(s / 100, 2), 1e-9), reason: '$s');
    }
    expect(db(50), closeTo(-12.04, 0.01));
    expect(db(10), closeTo(-40, 1e-9));
  });

  test('settingForMpvVolume undoes it', () {
    for (final s in [1.0, 5.0, 33.0, 50.0, 80.0, 100.0]) {
      expect(settingForMpvVolume(mpvVolumeFor(s)), closeTo(s, 1e-9));
    }
    expect(settingForMpvVolume(0), 0);
    expect(settingForMpvVolume(100), 100, reason: "mpv's default reads as the top of the slider");
    expect(settingForMpvVolume(-1), 0, reason: 'never negative');
  });
}
