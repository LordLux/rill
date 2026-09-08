/// The subscriptions surface — the cheapest possible second surface (Task 20
/// §1). No chips, and the point of it: an anonymous session must read as
/// "browsing anonymously", not as an error or a silent empty grid.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/ui/feed_controller.dart';

Future<void> _settle(ProviderContainer container, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (!container.read(subscriptionsProvider).isLoading) return;
  }
  fail('subscriptions never settled');
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

  test('loads on build, like home — no chips in the response', () async {
    container = await _boot('');
    await _settle(container);

    final state = container.read(subscriptionsProvider);
    expect(state.items.length, 3);
    expect(state.chips, isEmpty);
  });

  test('an empty page with no auth reads as anonymous, not an error', () async {
    container = await _boot('empty-home');
    await _settle(container);
    // auth.verify is in flight (the 'empty-home' mode delays it 400ms).
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final state = container.read(subscriptionsProvider);
    expect(state.isAnonymous, isTrue);
    expect(state.error, isNull);
    expect(state.items, isEmpty);
  });
}
