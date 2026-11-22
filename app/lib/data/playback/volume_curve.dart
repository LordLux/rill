/// The volume control's curve: the viewer's 0–100 setting to mpv's `volume`, and back
/// (`architecture.md` §2.7, "The volume curve").
///
/// **Even in decibels.** mpv cubes `volume` (`player/audio.c`, `pow(gain, 3)`), so writing the
/// slider's position straight to it made the top half of the slider worth 18 dB and the bottom
/// half everything else: 100 → 95 was 1.3 dB, 10 → 5 was 18 dB. Here every point of the setting
/// is the same number of decibels, [volumeRangeDb] across the whole slider, and 0 is silence.
library;

import 'dart:math' as math;

/// The setting's span in decibels: 100 is the level as it comes, 1 is just under this far below
/// it, 0 is off. A step of 5 (the arrow keys) is 2.5 dB.
const double volumeRangeDb = 50;

/// mpv's `volume` (0–100) for a setting (0–100).
double mpvVolumeFor(double setting) {
  if (setting <= 0) return 0;
  final s = math.min(setting, 100.0);
  final db = -volumeRangeDb * (1 - s / 100);
  // The amplitude mpv plays at is (volume / 100)³, so this volume is 20·log10 of it = `db`.
  return 100 * math.pow(10, db / 60).toDouble();
}

/// The setting (0–100) that [mpvVolumeFor] maps to [mpvVolume]: the inverse, for a level read back
/// from mpv. Anything quieter than the setting's bottom reads as 0.
double settingForMpvVolume(double mpvVolume) {
  if (mpvVolume <= 0) return 0;
  final db = 60 * math.log(math.min(mpvVolume, 100.0) / 100) / math.ln10;
  return (100 * (1 + db / volumeRangeDb)).clamp(0.0, 100.0);
}
