/// Measurement probe, not a regression test — see `test/README.md`.
///
/// Answers what the artist panel's header actually measures at real window
/// widths: how wide the action pills want to be, how wide each header column
/// ends up, and whether the pills fit on a single row. The two-column split
/// is driven by constants (`_avatarBlockWidth`, `_minIdentityWidth`) whose
/// only justification is that the pills stay on one row wherever there is
/// room for them, so those numbers have to be checked against a real layout
/// rather than reasoned about.
///
/// Run: flutter test test/probe_artist_header.dart --reporter expanded
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/domain/artist_panel.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/widgets/artist_panel_card.dart';
import 'package:rill/ui/widgets/subscribe_button.dart';

void main() {
  testWidgets('measure the header columns across widths', (tester) async {
    tester.view.physicalSize = const Size(2400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const panel = ArtistPanel(
      channelId: 'UC_probe',
      name: 'Ado',
      handle: '@Ado1024',
      avatarUrl: '',
      subscriberText: '9.52M subscribers',
      videoCountText: '739 videos',
      description: 'Ado is a Japanese singer.',
      isSubscribed: true,
      mixPlaylistId: 'RD_probe',
    );

    for (final width in <double>[1096.0, 1000.0, 940.0, 880.0, 820.0, 760.0, 700.0]) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildRillTheme(kDefaultAccent),
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(width: width, child: const ArtistPanelCard(artist: panel)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final pills = find.ancestor(
        of: find.byType(SubscribeButton),
        matching: find.byType(Wrap),
      );
      final pillBox = tester.getRect(pills.first);
      final name = tester.getRect(find.text('Ado'));
      final meta = tester.getRect(find.text('@Ado1024 • 9.52M subscribers • 739 videos'));

      // Sum the individual pills to get the width a single row would need,
      // which is the number the cap has to clear and cannot be read off a
      // Wrap that has already wrapped.
      final labels = ['Subscribed', 'View Channel', 'Mix', 'YouTube Music'];
      var natural = 0.0;
      final each = <String>[];
      for (final label in labels) {
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (w) => w is SubscribeButton || w is OutlinedButton,
          ),
        );
        if (button.evaluate().isNotEmpty) {
          final size = tester.getSize(button.first);
          natural += size.width;
          // The label's own width, to separate real glyph cost from whatever
          // chrome the button wraps around it.
          final text = tester.getSize(find.text(label).first);
          each.add(
            '$label=${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}'
            '(text=${text.width.toStringAsFixed(0)}, chrome=${(size.width - text.width).toStringAsFixed(0)})',
          );
        }
      }
      natural += 8 * (labels.length - 1);
      if (width == 1096.0) debugPrint('  per-pill: ${each.join('  ')}');

      final rows = (pillBox.height / 56).ceil();
      debugPrint(
        'panel=${width.toStringAsFixed(0)} '
        'pillBox=${pillBox.width.toStringAsFixed(0)}x${pillBox.height.toStringAsFixed(0)} '
        'rows=$rows '
        'naturalOneRow=${natural.toStringAsFixed(0)} '
        'pillsRight=${pillBox.right.toStringAsFixed(0)} '
        'identityRight=${meta.right.toStringAsFixed(0)} '
        'nameLeft=${name.left.toStringAsFixed(0)}',
      );
    }
  });
}
