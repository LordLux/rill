import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _audioOnlyPrefsKey = 'audio_only_mode';

/// Whether Audio-Only mode is enabled.
///
/// In Audio-Only mode, video decoding is disabled via mpv's `vid` property
/// while the audio continues playing. The video stream is still loaded (so
/// switching back is instant), but no frames are decoded or composited.
class AudioModeController extends Notifier<bool> {
  AudioModeController({this.initial = false});

  final bool initial;

  @override
  bool build() => initial;

  Future<void> toggle() async {
    await setMode(!state);
  }

  Future<void> setMode(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioOnlyPrefsKey, state);
  }
}

final audioModeProvider = NotifierProvider<AudioModeController, bool>(
  AudioModeController.new,
);

/// Read the audio-only mode preference before runApp.
Future<bool> readAudioMode() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_audioOnlyPrefsKey) ?? false;
}
