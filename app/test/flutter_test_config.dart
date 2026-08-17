/// Runs once before every test file in `test/` — Flutter looks for this name.
///
/// **`shared_preferences` has no implementation under `flutter test`**, so
/// `getInstance()` throws `MissingPluginException`. Nothing awaits it —
/// `DrawerStateController.build` starts `_restore` in a `Future.microtask` — so
/// it arrives as an unhandled async error and lands on whichever test happens to
/// be running. Measured 2026-08-16: the same tree failed 2 tests on one run and
/// 38 on the next, in files that never mention preferences.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await testMain();
}
