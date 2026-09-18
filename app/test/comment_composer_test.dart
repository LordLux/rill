/// The "Add a comment…" box.
///
/// The composer is deliberately ignorant of RPC and of the account — the post
/// and the avatar are handed in — so that the one rule that matters can be
/// tested without a sidecar: **a failed post must never cost the user what they
/// typed.** Everything else here is the shape of the box (collapsed until it is
/// needed) and the two ways it could send a comment twice or send nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/widgets/comment_composer.dart';

Future<void> pumpComposer(
  WidgetTester tester, {
  required Future<bool> Function(String text) onPost,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: CommentComposer(onPost: onPost),
        ),
      ),
    ),
  );
}

Finder get field => find.byType(TextField);
Finder get postButton => find.byType(FilledButton);
Finder get cancelButton => find.widgetWithText(TextButton, 'Cancel');
String fieldText(WidgetTester tester) => tester.widget<TextField>(field).controller!.text;

void main() {
  testWidgets('is a single line until it is used', (tester) async {
    await pumpComposer(tester, onPost: (_) async => true);

    expect(find.text('Add a comment...'), findsOneWidget);
    expect(postButton, findsNothing);
    expect(cancelButton, findsNothing);
  });

  testWidgets('opens on typing, and cannot post nothing or whitespace', (tester) async {
    await pumpComposer(tester, onPost: (_) async => true);

    await tester.enterText(field, '   ');
    await tester.pump();
    expect(postButton, findsOneWidget);
    expect(tester.widget<FilledButton>(postButton).onPressed, isNull,
        reason: 'whitespace is not a comment');

    await tester.enterText(field, '  hello  ');
    await tester.pump();
    expect(tester.widget<FilledButton>(postButton).onPressed, isNotNull);
  });

  testWidgets('posts the trimmed text, then empties and collapses', (tester) async {
    final posted = <String>[];
    await pumpComposer(tester, onPost: (text) async {
      posted.add(text);
      return true;
    });

    await tester.enterText(field, '  hello  ');
    await tester.pump();
    await tester.tap(postButton);
    await tester.pumpAndSettle();

    expect(posted, ['hello']);
    expect(fieldText(tester), isEmpty);
    expect(postButton, findsNothing);
  });

  testWidgets('a failed post keeps exactly what was typed', (tester) async {
    // The rule the widget exists to keep. A snackbar saying "could not post"
    // above a box that has just been emptied is a user retyping a paragraph.
    await pumpComposer(tester, onPost: (_) async => false);

    await tester.enterText(field, 'a long, carefully worded comment');
    await tester.pump();
    await tester.tap(postButton);
    await tester.pumpAndSettle();

    expect(fieldText(tester), 'a long, carefully worded comment');
    expect(postButton, findsOneWidget, reason: 'still open, so it can be retried');
    expect(tester.widget<FilledButton>(postButton).onPressed, isNotNull);
  });

  testWidgets('cannot be sent twice while a post is out', (tester) async {
    final pending = Completer<bool>();
    var calls = 0;
    await pumpComposer(tester, onPost: (_) {
      calls++;
      return pending.future;
    });

    await tester.enterText(field, 'hello');
    await tester.pump();
    await tester.tap(postButton);
    await tester.pump();

    // In flight: the button and the field are both inert, and the button shows
    // progress instead of its label.
    expect(tester.widget<FilledButton>(postButton).onPressed, isNull);
    expect(tester.widget<TextField>(field).enabled, isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(postButton, warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);

    pending.complete(true);
    await tester.pumpAndSettle();
    expect(fieldText(tester), isEmpty);
    expect(calls, 1);
  });

  testWidgets('cancel empties the box and collapses it', (tester) async {
    await pumpComposer(tester, onPost: (_) async => true);

    await tester.enterText(field, 'never mind');
    await tester.pump();
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(fieldText(tester), isEmpty);
    expect(postButton, findsNothing);
  });

  testWidgets('disposes cleanly', (tester) async {
    await pumpComposer(tester, onPost: (_) async => true);
    await tester.enterText(field, 'x');
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(tester.takeException(), isNull);
  });
}
