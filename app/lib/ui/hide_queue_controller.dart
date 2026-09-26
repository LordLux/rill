import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _hideQueuePrefsKey = 'hide_queue_mode';

class HideQueueController extends Notifier<bool> {
  HideQueueController({this.initial = false});

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
    await prefs.setBool(_hideQueuePrefsKey, state);
  }
}

final hideQueueProvider = NotifierProvider<HideQueueController, bool>(
  HideQueueController.new,
);

Future<bool> readHideQueue() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_hideQueuePrefsKey) ?? false;
}
