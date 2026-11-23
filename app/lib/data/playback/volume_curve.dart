/// The volume control's curve: the viewer's 0–100 setting to mpv's `volume`, and back
/// (`architecture.md` §2.7, "The volume curve").
///
/// **The setting squared is the amplitude** — halfway between youtube.com, where the setting *is*
/// the amplitude (its slider's value goes straight to the `<video>` element's `volume`, a linear gain
/// in Chromium: 50 is 6 dB down, measured 2026-11-23), and writing the setting straight to mpv, which
/// cubes `volume` (`player/audio.c`, `pow(gain, 3)`): 50 was 18 dB down. Here 50 is 12 dB down.
library;

import 'dart:math' as math;

/// The amplitude is (setting / 100) to this power: 1 is youtube.com's, 3 the old straight write.
/// Chosen by ear against both, and against even-decibel curves, on 2026-11-23.
const double volumePower = 2;

/// mpv's `volume` (0–100) for a setting (0–100). mpv plays at (volume / 100)³.
double mpvVolumeFor(double setting) {
  if (setting <= 0) return 0;
  final s = math.min(setting, 100.0) / 100;
  return 100 * math.pow(s, volumePower / 3).toDouble();
}

/// The setting (0–100) that [mpvVolumeFor] maps to [mpvVolume]: the inverse, for a level read back
/// from mpv.
double settingForMpvVolume(double mpvVolume) {
  if (mpvVolume <= 0) return 0;
  final v = math.min(mpvVolume, 100.0) / 100;
  return 100 * math.pow(v, 3 / volumePower).toDouble();
}
