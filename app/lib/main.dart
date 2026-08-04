import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'theme.dart';
import 'ui/debug_player.dart';
import 'ui/pages/feed.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // If the harness environment variables are set, boot directly into the debug player harness
  if (Platform.environment.containsKey('NY_MODE') || Platform.environment.containsKey('NY_VIDEO_ID')) {
    final config = HarnessConfig.fromEnvironment();
    try {
      final source = await StreamSource.load(config);
      runApp(HarnessApp(config: config, source: source));
    } on Object catch (error) {
      stderr.writeln('harness: $error');
      runApp(FailedApp(message: '$error'));
    }
    return;
  }

  // Boot the app normally
  runApp(
    const ProviderScope(
      child: NativeYouTubeApp(),
    ),
  );
}

class NativeYouTubeApp extends StatelessWidget {
  const NativeYouTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    var themeData = ThemeData.dark(useMaterial3: true);

    return MaterialApp(
      title: 'Native YouTube',
      theme: themeData,
      debugShowCheckedModeBanner: false,
      home: TextThemeMod(themeMode: ThemeMode.dark, onThemeModeChanged: (_) {}, child: const FeedPage()),
    );
  }
}
