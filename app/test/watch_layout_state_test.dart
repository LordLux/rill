/// State under the watch page survives switching layout mode.
///
/// Reported: a like set on the watch page reset to "no rating" on a theatre ↔
/// normal toggle, though the rating itself had reached YouTube. The cause is
/// structural — `WatchLayout` puts the player *into* the metadata column in
/// normal mode and *above* the whole content in theatre, so the metadata and the
/// rail change position in their parents on every toggle. Elements are matched
/// by position unless keyed, so every `State` below them was being discarded
/// and rebuilt from scratch.
///
/// These tests put a counting `StatefulWidget` in each slot and flip the mode.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/pages/watch_layout.dart';
import 'package:silky_scroll/silky_scroll.dart';

/// Counts how many distinct `State` objects were ever created for a slot.
class _Probe extends StatefulWidget {
  const _Probe(this.name, this.created);
  final String name;
  final Map<String, int> created;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.created.update(widget.name, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: 40, child: Text(widget.name));
}

Widget _page({required bool theatre, required double width, required Map<String, int> created}) {
  return MaterialApp(
    home: Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final geometry = computeWatchGeometry(
            availableWidth: width,
            viewportHeight: 900,
            aspectRatio: 16 / 9,
            theatre: theatre,
          );
          return WatchLayout(
            geometry: geometry,
            playerSlot: _Probe('player', created),
            metadataSlot: _Probe('metadata', created),
            railSlot: _Probe('rail', created),
            // The page's own scroll view, not the default — the key lookup that
            // makes a moved child findable lives in the sliver list.
            scrollView: (children) => SilkyListView(
              padding: EdgeInsets.zero,
              children: children,
            ),
          );
        },
      ),
    ),
  );
}

Future<void> _toggle(WidgetTester tester, double width, Map<String, int> created) async {
  await tester.pumpWidget(_page(theatre: false, width: width, created: created));
  await tester.pump();
  await tester.pumpWidget(_page(theatre: true, width: width, created: created));
  await tester.pump();
  await tester.pumpWidget(_page(theatre: false, width: width, created: created));
  await tester.pump();
}

void main() {
  for (final (label, width) in [('two-column', 1600.0), ('single column', 700.0)]) {
    group(label, () {
      testWidgets('the metadata keeps its State across normal → theatre → normal', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final created = <String, int>{};
        await _toggle(tester, width, created);
        expect(created['metadata'], 1, reason: 'a second State means the like button forgot');
      });

      testWidgets('the rail keeps its State across normal → theatre → normal', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final created = <String, int>{};
        await _toggle(tester, width, created);
        // Single column has no rail slot on screen at all, so there is nothing
        // to keep; two-column is where the queue panel lives.
        if (width >= 889) expect(created['rail'], 1);
      });
    });
  }
}
