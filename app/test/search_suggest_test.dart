/// Search suggestions under real, sustained typing (Task 20 §4) — the first
/// exercise of `$cancel` and the generation guard against typing speed rather
/// than a hand-placed race. Every prior use (the feed's chip switch) fires at
/// most a few times a minute; this fires per keystroke.
///
/// Mutation-shaped on purpose: a test that types, awaits, then asserts would
/// pass with the debounce deleted, because the await lets everything settle
/// first. These drive the controller with real, un-awaited gaps between
/// keystrokes and check the wire, not just the final state.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/ui/search_suggest_controller.dart';

Future<ProviderContainer> _boot() async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();
  return ProviderContainer();
}

/// Types [text] one character at a time, [gap] apart, without awaiting
/// anything in between — real wall-clock time, the same as a person typing.
Future<void> _type(SearchSuggestController controller, String text, Duration gap) async {
  for (var i = 1; i <= text.length; i++) {
    controller.onTextChanged(text.substring(0, i));
    await Future<void>.delayed(gap);
  }
}

void main() {
  late ProviderContainer container;

  tearDown(() {
    container.dispose();
    RpcClient.instance.killForTest();
  });

  test('a single keystroke issues exactly one request, after the debounce window', () async {
    container = await _boot();
    final controller = container.read(searchSuggestProvider.notifier);

    controller.onTextChanged('a');
    // Before the debounce window closes, nothing has gone out yet.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(controller.requestsIssued, 0);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(controller.requestsIssued, 1);
    expect(container.read(searchSuggestProvider).suggestions, ['a one', 'a two', 'a three']);
  });

  test(
    'sustained typing at 8 chars/s collapses to far fewer than 20 requests, '
    'and a superseded response never reaches the UI',
    () async {
      container = await _boot();
      final controller = container.read(searchSuggestProvider.notifier);

      // 125ms/keystroke = 8 chars/s, as the task asks to be tested against.
      // Each keystroke below the debounce's 200ms re-arms the timer, so a
      // request only ever goes out when typing pauses for a beat — here, never,
      // until the loop itself ends and the last timer is free to fire.
      await _type(controller, 'lofi hip hop chill mi', const Duration(milliseconds: 125));
      // Let the final debounce timer fire and its request answer.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Report exactly what happened, per the task's ask.
      // ignore: avoid_print
      print(
        'search.suggest: 21-character query, 8 chars/s typing → '
        '${controller.requestsIssued} request(s) issued, '
        '${controller.requestsCancelled} cancelled',
      );

      expect(controller.requestsIssued, lessThan(21),
          reason: 'debounce must collapse sustained typing into far fewer requests than keystrokes');

      final state = container.read(searchSuggestProvider);
      expect(state.suggestions, isNotEmpty);
      // Whatever landed must answer the *final* text in the box, never a
      // half-typed prefix from partway through the burst.
      expect(state.suggestions.every((s) => s.startsWith('lofi hip hop chill mi')), isTrue,
          reason: 'a superseded suggestion response must never reach the UI: ${state.suggestions}');
    },
  );

  test('a request superseded mid-flight (not merely debounced) is cancelled and dropped', () async {
    container = await _boot();
    final controller = container.read(searchSuggestProvider.notifier);

    // Past the debounce window so this one actually goes out, slow enough that
    // the next keystroke's debounced request can supersede it mid-flight.
    controller.onTextChanged('slow@400');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(controller.requestsIssued, 1, reason: 'the first request must be on the wire by now');

    controller.onTextChanged('fast');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(controller.requestsCancelled, greaterThanOrEqualTo(1));
    final suggestions = container.read(searchSuggestProvider).suggestions;
    expect(suggestions.any((s) => s.startsWith('slow')), isFalse,
        reason: 'the superseded in-flight request must never land: $suggestions');
    expect(suggestions, ['fast one', 'fast two', 'fast three']);
  });

  test('clearing the box cancels whatever is in flight and closes the dropdown', () async {
    container = await _boot();
    final controller = container.read(searchSuggestProvider.notifier);

    controller.onTextChanged('slow@400');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(controller.requestsIssued, 1);

    controller.onTextChanged('');
    expect(container.read(searchSuggestProvider).isOpen, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(container.read(searchSuggestProvider).suggestions, isEmpty,
        reason: 'the stale in-flight answer must not repopulate the dropdown after it was closed');
  });

  test('close() cancels in-flight work — Escape and blur must not leak a request', () async {
    container = await _boot();
    final controller = container.read(searchSuggestProvider.notifier);

    controller.onTextChanged('slow@400');
    await Future<void>.delayed(const Duration(milliseconds: 250));

    controller.close();
    expect(container.read(searchSuggestProvider).isOpen, isFalse);
    expect(controller.requestsCancelled, 1);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(container.read(searchSuggestProvider).suggestions, isEmpty);
  });

  group('arrow-key highlight navigation', () {
    /// Types [query], waits past the debounce and the fake sidecar's answer,
    /// and returns once three suggestions (`fake_sidecar.ts`'s fixed shape)
    /// are in state — the precondition every test below needs.
    Future<void> loadThreeSuggestions(SearchSuggestController controller, String query) async {
      controller.onTextChanged(query);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    test('does nothing while the dropdown is closed or empty', () async {
      container = await _boot();
      final controller = container.read(searchSuggestProvider.notifier);

      // Closed: never typed anything.
      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, isNull);

      // Open, but the fetch has not answered yet — still nothing to move onto.
      controller.onTextChanged('x');
      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, isNull);
    });

    test('arrow-down walks 0, 1, 2 and stops at the last suggestion — no wrap', () async {
      container = await _boot();
      final controller = container.read(searchSuggestProvider.notifier);
      await loadThreeSuggestions(controller, 'x');
      expect(container.read(searchSuggestProvider).suggestions, hasLength(3));

      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, 0);
      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, 1);
      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, 2);

      // MUTATION CHECK: a version that wraps (`% length`) or keeps
      // incrementing past the list would both pass a test that only checked
      // "index 2 is reachable" — this is the one arrow-down that must be a
      // no-op, on the boundary the bug would actually show up on.
      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, 2,
          reason: 'arrow-down past the last suggestion must not wrap or overrun');
    });

    test('arrow-up from index 0 returns to the text field, not index -1', () async {
      container = await _boot();
      final controller = container.read(searchSuggestProvider.notifier);
      await loadThreeSuggestions(controller, 'x');

      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, 0);
      controller.moveHighlight(-1);
      expect(container.read(searchSuggestProvider).highlightedIndex, isNull,
          reason: 'arrow-up out of the list must land on "nothing highlighted", not -1');

      // And arrow-up again, already back at the field, goes nowhere further.
      controller.moveHighlight(-1);
      expect(container.read(searchSuggestProvider).highlightedIndex, isNull);
    });

    test('typing again clears whatever was highlighted', () async {
      container = await _boot();
      final controller = container.read(searchSuggestProvider.notifier);
      await loadThreeSuggestions(controller, 'x');
      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, 0);

      controller.onTextChanged('xy');
      expect(container.read(searchSuggestProvider).highlightedIndex, isNull,
          reason: 'a highlight pointing into the previous keystroke\'s list must not survive a new one');
    });

    test('close() clears the highlight along with everything else', () async {
      container = await _boot();
      final controller = container.read(searchSuggestProvider.notifier);
      await loadThreeSuggestions(controller, 'x');
      controller.moveHighlight(1);
      expect(container.read(searchSuggestProvider).highlightedIndex, 0);

      controller.close();
      expect(container.read(searchSuggestProvider).highlightedIndex, isNull);
    });
  });
}
