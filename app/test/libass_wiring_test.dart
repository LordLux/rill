import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/data/playback/engine.dart';
import 'package:rill/ui/audio_mode_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/libass_layer.dart';
import 'package:rill/ui/player_shell.dart';

import 'fake_engine.dart';

/// Which renderer draws captions on the main player (`architecture.md` §2.9).
///
/// The hover preview's half (mpv draws, no `LibassLayer` mounted) is in
/// `hover_preview_test.dart`, group "Wiring checks".
void main() {
  test('the two caption settings have the values §2.9 needs', () {
    expect(kLibassEnabled, isTrue, reason: 'off, mpv strips every ASS tag');
    expect(kNoFlutterSubtitles.visible, isFalse,
        reason: "on, media_kit's SubtitleView paints a plain-text copy over the styled one");
  });

  test('engine.dart passes both settings everywhere it builds a player', () {
    // A source check, because media_kit gives no way to read a Player's
    // configuration back. Counted, not `contains`: engine.dart builds two
    // PlayerConfigurations (the shipped one, and one with a log level for
    // measurement), and dropping libass from either one must fail.
    final source = File('lib/data/playback/engine.dart').readAsStringSync();
    final built = RegExp(r'PlayerConfiguration\(').allMatches(source).length;
    final withLibass =
        RegExp(r'PlayerConfiguration\([^)]*libass: kLibassEnabled').allMatches(source).length;
    expect(built, greaterThan(0), reason: 'no PlayerConfiguration found; this check would pass vacuously');
    expect(withLibass, built, reason: 'every PlayerConfiguration must pass libass: kLibassEnabled');
    expect(source, contains('subtitleViewConfiguration: kNoFlutterSubtitles'),
        reason: 'the Video widget must hide SubtitleView, or captions draw twice');
  });

  testWidgets('the main player mounts LibassLayer and turns mpv subtitles off', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackEngineProvider.overrideWithValue(engine),
          audioModeProvider.overrideWith(() => AudioModeController(initial: false)),
        ],
        child: const MaterialApp(home: PlayerShell(child: SizedBox())),
      ),
    );

    expect(find.byType(LibassLayer), findsOneWidget);
    expect(engine.subtitleVisible, isFalse,
        reason: 'with mpv subtitles on as well, every caption draws twice');
  });
}
