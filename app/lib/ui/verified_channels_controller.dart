import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _prefsKey = 'verified_channel_names';

class VerifiedChannelsController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    Future.microtask(_restore);
    return const {};
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey);
    if (stored != null) state = stored.toSet();
  }

  Future<void> markVerified(String channelName) async {
    if (state.contains(channelName) || channelName.isEmpty) return;
    
    final next = {...state, channelName};
    state = next;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, next.toList());
  }
}

final verifiedChannelsProvider = NotifierProvider<VerifiedChannelsController, Set<String>>(() => VerifiedChannelsController());
