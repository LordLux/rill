/// The save-to-playlist dialog (Task 25 §5) against a fake sidecar —
/// `playlist.forVideo`'s membership rendered correctly, and both the add and
/// remove side of the checkbox toggle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/ui/widgets/save_dialog.dart';

/// Matches `ACTION_FAIL_ID` in `fake_sidecar.ts`.
const String actionFailId = 'actionfail1';

Widget harness(String videoId) => MaterialApp(
      home: Scaffold(body: Center(child: SaveDialog(videoId: videoId))),
    );

/// A real sidecar subprocess talks over real pipes, which `FakeAsync` (what
/// `testWidgets` runs the test body under) does not advance — `runAsync`
/// escapes to the real event loop just long enough for the round trip to
/// land. A fixed pump rather than `pumpAndSettle`: the busy row briefly shows
/// an indeterminate `CircularProgressIndicator`, which never "settles" by
/// definition, so `pumpAndSettle` times out waiting for an animation this
/// dialog runs on purpose.
///
/// The trailing `pump` is on a **different** clock from the delay above it.
/// `SaveDialog`'s own busy-clearing timer (`Future.delayed(150–300ms)`) is
/// created inside the widget's build, which runs under `testWidgets`'s fake
/// clock — `runAsync`'s real-time wait does nothing for it. `pump(duration)`
/// advances *that* clock, so it has to cover the full 300 ms the random busy
/// window can reach, not a token amount.
Future<void> settleReal(WidgetTester tester, [int millis = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: millis)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());

  setUp(() => RpcClient.instance.call('test.reset', {}));

  testWidgets('renders existing membership correctly — neither playlist checked', (tester) async {
    await tester.pumpWidget(harness('vid_save_1'));
    await settleReal(tester);

    expect(find.text('Watch later'), findsOneWidget);
    expect(find.text('My Mix'), findsOneWidget);

    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(checkboxes, hasLength(2));
    expect(checkboxes.every((c) => c.value == false), isTrue);
  });

  testWidgets('checking a row adds the video and re-renders it ticked', (tester) async {
    await tester.pumpWidget(harness('vid_save_2'));
    await settleReal(tester);

    await tester.tap(find.text('My Mix'));
    await settleReal(tester);

    final myMixRow = find.ancestor(of: find.text('My Mix'), matching: find.byType(InkWell));
    final checkbox = tester.widget<Checkbox>(find.descendant(of: myMixRow, matching: find.byType(Checkbox)));
    expect(checkbox.value, isTrue);
  });

  testWidgets('checking then unchecking the same row in one session removes it', (tester) async {
    // The row added just above has no `removeToken` of its own — nothing
    // handed one to this client for a video it added itself — so unchecking
    // it has to fetch one lazily rather than assume the optimistic state
    // already carries everything needed. This is the path a real account hit
    // as a full-blown bug: refetching membership right after the add (rather
    // than only right before a removal) could still answer "not in the
    // playlist" for the entry it had just created, silently un-ticking a
    // save that had, in fact, already landed.
    await tester.pumpWidget(harness('vid_save_2b'));
    await settleReal(tester);

    await tester.tap(find.text('My Mix'));
    await settleReal(tester);
    final myMixRow = find.ancestor(of: find.text('My Mix'), matching: find.byType(InkWell));
    expect(
      tester.widget<Checkbox>(find.descendant(of: myMixRow, matching: find.byType(Checkbox))).value,
      isTrue,
    );

    await tester.tap(find.text('My Mix'));
    // Two sequential real round trips this time — fetching the removeToken
    // this row never got, then the removal itself.
    await settleReal(tester);
    await settleReal(tester);
    expect(
      tester.widget<Checkbox>(find.descendant(of: myMixRow, matching: find.byType(Checkbox))).value,
      isFalse,
    );
  });

  testWidgets('unchecking Watch Later removes it and re-renders unticked', (tester) async {
    // Seed membership first, exactly like the dialog itself would. Wrapped in
    // `runAsync` for the same reason `settleReal` is — a real subprocess round
    // trip does not resolve inside the fake-async zone `testWidgets` runs in.
    await tester.runAsync(() => RpcClient.instance.call('action.addToWatchLater', {'videoId': 'vid_save_3'}));

    await tester.pumpWidget(harness('vid_save_3'));
    await settleReal(tester);

    final watchLaterRow = find.ancestor(of: find.text('Watch later'), matching: find.byType(InkWell));
    expect(
      tester.widget<Checkbox>(find.descendant(of: watchLaterRow, matching: find.byType(Checkbox))).value,
      isTrue,
      reason: 'seeded membership must render checked before any tap',
    );

    await tester.tap(find.text('Watch later'));
    await settleReal(tester);

    expect(
      tester.widget<Checkbox>(find.descendant(of: watchLaterRow, matching: find.byType(Checkbox))).value,
      isFalse,
    );
  });

  testWidgets('a toggle that fails still reports it, but never reverts the checkbox', (tester) async {
    // Deliberately not the usual revert-on-failure rule (see `_toggle`'s doc
    // comment): playlist edits are idempotent, so nothing about correctness
    // depends on this client waiting for or reacting to the answer, and the
    // tap has already done its job the moment the request was sent. A
    // mutation guard on the other half — a dialog that never shows the
    // failure at all would also leave the checkbox ticked and pass a test
    // that only checked the checkbox.
    await tester.pumpWidget(harness(actionFailId));
    await settleReal(tester);

    await tester.tap(find.text('My Mix'));
    await settleReal(tester);

    final myMixRow = find.ancestor(of: find.text('My Mix'), matching: find.byType(InkWell));
    expect(
      tester.widget<Checkbox>(find.descendant(of: myMixRow, matching: find.byType(Checkbox))).value,
      isTrue,
      reason: 'a failed edit is still reported, but the checkbox is not rolled back',
    );
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
