/// What happens after a page fails to load.
///
/// `loadMore` is driven by a scroll listener that fires on every notification
/// within 400 px of the bottom. Before this, a failed continuation left
/// `continuation` set and `isLoading` false, so the very next scroll event
/// issued the same failing request again — unbounded, and invisible, because the
/// error surface only replaces the grid when there are no items at all.
///
/// These tests pin the two halves of the fix: the gate that stops the loop, and
/// the difference `protocol.md` §4 draws between a failure the app may retry on
/// its own and one only a person should answer.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/ui/feed_controller.dart';

Future<void> _settle(
  ProviderContainer container, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (!container.read(feedProvider).isLoading) return;
  }
  fail('feed never settled');
}

Future<ProviderContainer> _boot(String mode) async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1', mode];
  await RpcClient.instance.start();
  return ProviderContainer();
}

void main() {
  late ProviderContainer container;

  tearDown(() {
    container.dispose();
    RpcClient.instance.killForTest();
  });

  test('a retry:"user" page failure stops the loop and asks the user', () async {
    container = await _boot('paging-user');
    await _settle(container);

    final controller = container.read(feedProvider.notifier);
    expect(container.read(feedProvider).continuation, isNotNull,
        reason: 'the fixture must hand back a continuation or there is no page to fail');

    await controller.loadMore();
    await _settle(container);

    var state = container.read(feedProvider);
    expect(state.error, 'page unavailable');
    expect(state.errorRetry, RpcRetryMode.user);
    expect(state.items, isNotEmpty, reason: 'the first page must survive the second one failing');

    // The gate. Scrolling calls this on every notification; each call must now
    // be a no-op rather than another request.
    //
    // The assertion has to run *before* awaiting the call. `loadHome` sets
    // `isLoading: true` in its synchronous prefix and the request has cleared it
    // again by the time the future completes, so checking after an `await` sees
    // false either way and proves nothing — the first draft of this test passed
    // with the gate deleted.
    for (var i = 0; i < 5; i++) {
      final call = controller.loadMore();
      expect(container.read(feedProvider).isLoading, isFalse,
          reason: 'loadMore #$i re-issued a request after a failure');
      await call;
    }
    expect(container.read(feedProvider).error, 'page unavailable');

    // And the user can still get out of it.
    final pending = controller.retryMore();
    expect(container.read(feedProvider).isLoading, isTrue,
        reason: 'retryMore must clear the gate that loadMore respects');
    await pending;
  });

  test('a retry:"auto" page failure retries silently, showing loading not an error', () async {
    container = await _boot('paging-auto');
    await _settle(container);

    final controller = container.read(feedProvider.notifier);
    await controller.loadMore();

    // Give the failure time to land, but not the 1 s first backoff.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final state = container.read(feedProvider);
    expect(state.error, isNull, reason: '§4: an auto failure shows a loading state, not an error');
    expect(state.isLoading, isTrue);

    // The loading state doubles as the gate while the backoff is pending, so a
    // scroll cannot race the timer into a second request.
    await controller.loadMore();
    expect(container.read(feedProvider).isLoading, isTrue);
    expect(container.read(feedProvider).error, isNull);
  });

  test('a failing base load exhausts its retry budget instead of looping forever', () async {
    // The budget is only a budget if a retry cannot refill it. A scheduled retry
    // re-entered `loadHome` as an ordinary base load and reset `_autoAttempt` to
    // 0, so the cap never bit: a failing home feed retried every second forever
    // behind a spinner that never became an error. Silent, unbounded, and
    // invisible — the exact pathology the cap was written to prevent.
    final original = FeedController.autoBackoff;
    FeedController.autoBackoff = const [
      Duration(milliseconds: 60),
      Duration(milliseconds: 60),
      Duration(milliseconds: 60),
      Duration(milliseconds: 60),
    ];
    addTearDown(() => FeedController.autoBackoff = original);

    container = await _boot('base-fail-auto');

    // Long enough for four 60 ms attempts many times over. With the budget
    // refilling, this window holds dozens of attempts and never surfaces one.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (container.read(feedProvider).error != null) break;
    }

    final state = container.read(feedProvider);
    expect(state.error, isNotNull, reason: 'the budget never ran out — it is being refilled');
    expect(state.isLoading, isFalse);

    // Surfaced as the user's call once the app has stopped retrying for them.
    expect(state.errorRetry, RpcRetryMode.user);

    // The fixture counts attempts, so the message pins the budget's size rather
    // than merely that it is finite.
    expect(state.error, 'base browse failed, attempt ${FeedController.autoBackoff.length + 1}');
  });

  test('copyWith can clear errorRetry, not only set it', () {
    // Hard invariant 10. `errorRetry` travels with `error`, and a load that
    // clears one must clear the other or a stale mode outlives its message.
    const failed = FeedState(
      surface: 'home',
      error: 'boom',
      errorRetry: RpcRetryMode.no,
    );
    final cleared = failed.copyWith(error: null, errorRetry: null);
    expect(cleared.error, isNull);
    expect(cleared.errorRetry, isNull);

    final untouched = failed.copyWith(isLoading: true);
    expect(untouched.error, 'boom');
    expect(untouched.errorRetry, RpcRetryMode.no);
  });
}
