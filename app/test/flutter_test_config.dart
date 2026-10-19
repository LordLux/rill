/// Runs once before every test file in `test/` — Flutter looks for this name.
///
/// **`shared_preferences` has no implementation under `flutter test`**, so
/// `getInstance()` throws `MissingPluginException`. Nothing awaits it —
/// `DrawerStateController.build` starts `_restore` in a `Future.microtask` — so
/// it arrives as an unhandled async error and lands on whichever test happens to
/// be running. Measured 2026-08-16: the same tree failed 2 tests on one run and
/// 38 on the next, in files that never mention preferences.
///
/// **yt-dlp is "on PATH" for every test unless it says otherwise.** The real
/// answer is whatever this machine has: an app-managed copy in
/// `%LOCALAPPDATA%\rill\bin` schedules a 30 s maintenance timer that the playlist
/// page's account button then leaves pending, and 29 tests failed on a machine
/// with one and passed on one without. A test that needs another state overrides
/// `ytDlpResolutionProvider`, as `ytdlp_controller_test.dart` does.
library;

import 'dart:async';

import 'package:rill/data/ytdlp/ytdlp_paths.dart';
import 'package:rill/domain/ytdlp/ytdlp_state.dart';
import 'package:rill/ui/ytdlp_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  ytDlpResolver = () => const YtDlpResolution(location: YtDlpLocation.onPath, path: 'yt-dlp');
  await testMain();
}
