/// The volume control's curve (`data/playback/volume_curve.dart`, `architecture.md` §2.7).
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/playback/volume_curve.dart';

/// The output's level in dB for a setting: mpv plays at (volume / 100)³.
double db(double setting) => 60 * math.log(mpvVolumeFor(setting) / 100) / math.ln10;

void main() {
  test('the ends: 100 is the level as it comes, 0 is silence', () {
    expect(mpvVolumeFor(100), 100);
    expect(mpvVolumeFor(0), 0);
    expect(mpvVolumeFor(-5), 0);
    expect(mpvVolumeFor(130), 100, reason: 'never louder than mpv unscaled');
  });

  test('every step of the setting is the same number of decibels', () {
    // MUTATION: `return setting;` (the old straight write, which mpv cubes) fails here — 100 → 95
    // was 1.3 dB and 10 → 5 was 18 dB.
    for (var s = 100.0; s > 5; s -= 5) {
      expect(db(s) - db(s - 5), closeTo(volumeRangeDb * 5 / 100, 1e-9), reason: '$s → ${s - 5}');
    }
    expect(db(50), closeTo(-volumeRangeDb / 2, 1e-9), reason: 'halfway is half the range down');
  });

  test('settingForMpvVolume undoes it', () {
    for (final s in [1.0, 5.0, 33.0, 50.0, 80.0, 100.0]) {
      expect(settingForMpvVolume(mpvVolumeFor(s)), closeTo(s, 1e-9));
    }
    expect(settingForMpvVolume(0), 0);
    expect(settingForMpvVolume(100), 100, reason: "mpv's default reads as the top of the slider");
    expect(settingForMpvVolume(0.0001), 0, reason: 'below the bottom reads as 0, never negative');
  });
}
