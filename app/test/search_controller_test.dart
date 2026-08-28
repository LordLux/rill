/// The search surface, driven through the same generalised `FeedController`
/// home already uses (Task 20 §1). These pin the parts that are genuinely new
/// — a required `q`, filters riding along, paging via `continuation` alone,
/// and an empty page reading as "no results" rather than an error.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/search_filters.dart';
import 'package:rill/ui/feed_controller.dart';

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
    if (!container.read(searchProvider).isLoading) return;
  }
  fail('search never settled');
}

Future<ProviderContainer> _boot({String mode = ''}) async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1', if (mode.isNotEmpty) mode];
  await RpcClient.instance.start();
  return ProviderContainer();
}

void main() {
  late ProviderContainer container;

  tearDown(() {
    container.dispose();
    RpcClient.instance.killForTest();
  });

  test('build() does not auto-load — search needs a query first', () async {
    container = await _boot();
    // No microtask fires an RPC call here: give one a chance to and see none did.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(searchProvider).items, isEmpty);
    expect(container.read(searchProvider).isLoading, isFalse);
  });

  test('search() issues q and loads results', () async {
    container = await _boot();
    final controller = container.read(searchProvider.notifier);

    await controller.search('lofi');
    await _settle(container);

    final state = container.read(searchProvider);
    expect(_titles(state), ['lofi result 0', 'lofi result 1', 'lofi result 2']);
    expect(state.query, 'lofi');
    expect(state.continuation, isNotNull);
    expect(state.chips, isEmpty, reason: 'search has no chip bar');
  });

  test('loadMore pages via continuation alone, without re-sending q', () async {
    container = await _boot();
    final controller = container.read(searchProvider.notifier);
    await controller.search('lofi');
    await _settle(container);

    await controller.loadMore();
    await _settle(container);

    final state = container.read(searchProvider);
    expect(_titles(state), [
      'lofi result 0',
      'lofi result 1',
      'lofi result 2',
      'search page2 item 3',
      'search page2 item 4',
      'search page2 item 5',
    ]);
  });

  test('a real empty result set reads as "no results", not an error or auth check', () async {
    container = await _boot();
    final controller = container.read(searchProvider.notifier);
    await controller.search('empty');
    await _settle(container);

    final state = container.read(searchProvider);
    expect(state.items, isEmpty);
    expect(state.error, isNull);
    expect(state.isAnonymous, isFalse, reason: 'search never runs the auth.verify heuristic');
    expect(state.isAuthDegraded, isFalse);
  });

  test('filters ride along on the request and updateFilters starts a fresh page', () async {
    container = await _boot();
    final controller = container.read(searchProvider.notifier);
    await controller.search('lofi', filters: const SearchFilters(type: SearchTypeFilter.playlist));
    await _settle(container);

    final log = await RpcClient.instance.call('test.searchLog', {});
    final calls = (log['searchCalls'] as List).cast<Map<String, dynamic>>();
    expect(calls.last['filters'], {'type': 'playlist'});

    await controller.updateFilters(
      const SearchFilters(type: SearchTypeFilter.playlist, sortBy: SortByFilter.viewCount),
    );
    await _settle(container);

    final log2 = await RpcClient.instance.call('test.searchLog', {});
    final calls2 = (log2['searchCalls'] as List).cast<Map<String, dynamic>>();
    expect(calls2.last['filters'], {'type': 'playlist', 'sortBy': 'viewCount'});
    // A filter change is a fresh page, the same as a chip switch.
    expect(container.read(searchProvider).items.length, 3);
  });

  test('a retry:"user" search failure is shown, not silently swallowed', () async {
    container = await _boot();
    final controller = container.read(searchProvider.notifier);
    await controller.search('foo!fail=user');
    await _settle(container);

    final state = container.read(searchProvider);
    expect(state.error, 'search unavailable');
    expect(state.errorRetry, RpcRetryMode.user);
  });

  test('a superseded search is dropped by the generation guard', () async {
    container = await _boot();
    final controller = container.read(searchProvider.notifier);
    await _settle(container);

    final slow = controller.search('slow@400!keepalive');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final fast = controller.search('fast');

    await Future.wait([slow, fast]).timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail('a superseded search() never completed'),
    );
    await _settle(container);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final titles = _titles(container.read(searchProvider));
    expect(titles.any((t) => t.startsWith('slow')), isFalse);
    expect(container.read(searchProvider).query, 'fast');
  });
}
