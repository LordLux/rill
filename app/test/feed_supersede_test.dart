/// The cancel-and-supersede path, against a real sidecar process.
///
/// Everything else about the feed controller is a pure function with a unit
/// test. This is the one part with a race: a filter switch issued while an
/// earlier request is still in flight. `$cancel` alone cannot make it safe —
/// a response already on the wire cannot be recalled — so the controller also
/// carries a generation counter, and that is what these tests pin.
///
/// `fake_sidecar.ts` encodes the delay in the chip token, because the token is
/// the only per-request value the controller lets a caller control.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/feed_controller.dart';

/// Titles of the items currently in the feed, which carry the token that
/// produced them.
List<String> _titles(FeedState state) => state.items
    .map((i) => switch (i) {
          VideoItem(:final title) => title,
          _ => '',
        })
    .toList();

Future<void> _settle(ProviderContainer container, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (!container.read(feedProvider).isLoading) return;
  }
  fail('feed never settled');
}

/// Start a fresh sidecar and container.
///
/// `RpcClient` is a singleton, and a killed process's stdout `onDone` arrives
/// asynchronously — if the next test has already spawned its replacement, that
/// stale callback tears the new one down instead. The pause lets the old
/// streams close while `_process` is still null, where `_handleExit` returns
/// early and does no damage.
Future<ProviderContainer> _boot({String mode = ''}) async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = [
    'run',
    'app/test/fake_sidecar.ts',
    '1',
    if (mode.isNotEmpty) mode,
  ];
  // Start the sidecar *before* the container, so spawning bun — several hundred
  // milliseconds — is not inside the window a test is trying to time. Without
  // this, a supersede aimed at a request in flight instead lands while the
  // first request is still queued behind process startup, and the test proves
  // nothing.
  await RpcClient.instance.start();
  return ProviderContainer();
}

void main() {
  late ProviderContainer container;

  setUp(() async {
    container = await _boot();
  });

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('a superseded payload is dropped even when it lands after its replacement', () async {
    final controller = container.read(feedProvider.notifier);
    await _settle(container);

    // MUSIC answers after 400ms and ignores $cancel, so its payload is
    // guaranteed to arrive *after* GAMING's. Only the generation guard can
    // keep it out of the feed.
    final slow = controller.loadHome(chipToken: 'MUSIC@400!keepalive');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final fast = controller.loadHome(chipToken: 'GAMING');

    // A superseded loadHome must still return. Its RPC future never completes
    // once cancelled, so without the supersede signal this hangs — and so
    // would any caller awaiting a refresh.
    await Future.wait([slow, fast]).timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail('a superseded loadHome() never completed'),
    );
    await _settle(container);

    // Wait past the point where the superseded response has certainly landed.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final titles = _titles(container.read(feedProvider));
    expect(titles.any((t) => t.startsWith('MUSIC')), isFalse,
        reason: 'the superseded filter\'s items must never appear: $titles');
    expect(container.read(feedProvider).selectedToken, 'GAMING');
  });

  test("the surviving filter's results are complete and unmixed", () async {
    final controller = container.read(feedProvider.notifier);
    await _settle(container);

    final slow = controller.loadHome(chipToken: 'MUSIC@400!keepalive');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final fast = controller.loadHome(chipToken: 'GAMING');
    await Future.wait([slow, fast]);
    await _settle(container);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final titles = _titles(container.read(feedProvider));
    expect(titles, ['GAMING item 0', 'GAMING item 1', 'GAMING item 2'],
        reason: 'complete, in order, and nothing from the superseded request');
  });

  test('the chip bar survives a filter switch and follows the token', () async {
    final controller = container.read(feedProvider.notifier);
    await _settle(container);
    expect(container.read(feedProvider).chips.length, 3,
        reason: 'the base browse ships the bar');

    // A filtered response carries no chips at all — the bar must persist.
    await controller.loadHome(chipToken: 'MUSIC');
    await _settle(container);

    final state = container.read(feedProvider);
    expect(state.chips.length, 3, reason: 'bar still drawn while filtered');
    expect(state.selectedChip?.label, 'Music', reason: 'and follows the active token');
  });

  test('a late auth.verify cannot overwrite a newer filter (generation guard)', () async {
    // The one response the client never cancels. `auth.verify` goes out with a
    // plain call when a base browse comes back empty, so when a filter switch
    // supersedes it mid-flight, the generation guard is the *only* thing
    // standing between a stale "anonymous" verdict and the new filter's feed.
    container.dispose();
    container = await _boot(mode: 'empty-home');

    final controller = container.read(feedProvider.notifier);
    // Base browse returns no items, so auth.verify is now in flight for 400ms.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // The window is real only because _boot pre-started the sidecar: the base
    // browse has answered (empty) and auth.verify is the outstanding request.
    expect(container.read(feedProvider).isLoading, isTrue,
        reason: 'auth.verify should still be in flight');
    await controller.loadHome(chipToken: 'GAMING');
    await _settle(container);

    // Let the superseded auth.verify land.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final state = container.read(feedProvider);
    expect(state.isAnonymous, isFalse,
        reason: 'a superseded auth.verify must not flip the feed to anonymous');
    expect(_titles(state), ['GAMING item 0', 'GAMING item 1', 'GAMING item 2'],
        reason: 'the newer filter survives intact');
  });

  test('a cancelled request never completes — the transport contract still holds', () async {
    // Not routed through the controller: this is the transport promise the
    // controller is built on, and the reason it supersedes on its own signal
    // rather than waiting for a cancelled response.
    await RpcClient.instance.start();
    final request = RpcClient.instance.callCancelable('feed.home', {'chipToken': 'MUSIC@200'});

    var completed = false;
    unawaited(request.response.then((_) => completed = true, onError: (_) => completed = true));

    RpcClient.instance.cancel(request.id);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(completed, isFalse,
        reason: 'a cancelled request must neither resolve nor reject');
  });
}
