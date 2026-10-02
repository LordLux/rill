import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the device has a network connection at all.
///
/// This is the interface (Wi-Fi, Ethernet, mobile), not a promise that YouTube is
/// reachable: `true` with a failing request means "connected, but not getting
/// through", `false` means "no connection". Those need different words.
/// Defaults to `true` until the platform answers, so a slow first answer never
/// claims the user is offline.
final isOnlineProvider = StreamProvider<bool>((ref) async* {
  final connectivity = Connectivity();
  bool online(List<ConnectivityResult> results) => results.any((r) => r != ConnectivityResult.none);
  try {
    yield online(await connectivity.checkConnectivity());
    yield* connectivity.onConnectivityChanged.map(online);
  } on Object {
    // No answer is not "offline".
    yield true;
  }
});

/// What to tell the user when a request failed to get through.
///
/// [offline] is [isOnlineProvider] being `false`. [raw] is the error's own text,
/// which for a transport failure is a socket message ("Was there a typo in the
/// url or port?") that points at the wrong thing entirely.
String connectionProblemMessage({required bool offline, required String raw}) {
  if (offline) return "You're offline.\nCheck your internet connection and try again.";
  final lower = raw.toLowerCase();
  if (lower.contains('unable to connect') || lower.contains('typo in the url') || lower.contains('socketexception') || lower.contains('timed out')) {
    return "You're connected, but YouTube could not be reached.\nTry again in a moment.";
  }
  return raw;
}
