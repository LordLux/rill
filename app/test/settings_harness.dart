/// An app with the real navigator and route tracker, for tests that open the settings page.
///
/// `openSettingsPage` pushes on `rootNavigatorKey`, and the page's back arrow and the
/// account menu's "already open" check read `currentRouteProvider`, which only the route
/// tracker sets. A bare `MaterialApp(home: …)` has neither.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/player_shell.dart' show rootNavigatorKey, routeTrackerProvider;

Widget settingsTestApp({List<Override> overrides = const [], required Widget home}) => ProviderScope(
      overrides: overrides,
      child: Consumer(
        builder: (context, ref, _) => MaterialApp(
          theme: buildRillTheme(kDefaultAccent),
          navigatorKey: rootNavigatorKey,
          navigatorObservers: [ref.watch(routeTrackerProvider)],
          home: home,
        ),
      ),
    );
