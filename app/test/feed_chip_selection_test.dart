import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/feed_controller.dart';

Chip _chip(String label, String token, {bool selected = false, String scope = 'feed'}) =>
    Chip(label: label, token: token, selected: selected, scope: scope);

void main() {
  // The strip the sidecar ships for an unfiltered home feed: "All" first,
  // marked selected, empty token meaning "no filter".
  final bar = [
    _chip('All', '', selected: true),
    _chip('Music', 'CHIP_TOKEN_1'),
    _chip('Gaming', 'CHIP_TOKEN_2'),
  ];

  group('selection', () {
    test('a freshly loaded strip selects the chip the server marked', () {
      expect(resolveSelectedChip(bar, null)?.label, 'All');
    });

    test('falls back to the first chip when the server marks none', () {
      final unmarked = bar.map((c) => c.copyWith(selected: false)).toList();
      expect(resolveSelectedChip(unmarked, null)?.label, 'All');
    });

    test('the active token wins over a stale server mark', () {
      // The cached bar still says "All" is selected, because that is what the
      // server said when it was fetched. The token is the truth after a click.
      expect(resolveSelectedChip(bar, 'CHIP_TOKEN_2')?.label, 'Gaming');
    });

    test('an unknown token falls back to the first chip rather than throwing', () {
      expect(resolveSelectedChip(bar, 'CHIP_TOKEN_STALE')?.label, 'All');
    });

    test('an empty strip has no selection', () {
      expect(resolveSelectedChip([], null), isNull);
    });
  });

  group('chip bar ownership', () {
    test('a base browse stores the feed-scope bar', () {
      final bars = storeChipBar({}, 'home', bar, isBaseBrowse: true);
      expect(bars['home']?.map((c) => c.label), ['All', 'Music', 'Gaming']);
    });

    test('a chip-filtered or paged response never touches the bar', () {
      final stored = storeChipBar({}, 'home', bar, isBaseBrowse: true);
      // What a continuation actually returns: no feed chips at all.
      final after = storeChipBar(stored, 'home', const [], isBaseBrowse: false);
      expect(after['home']?.length, 3, reason: 'the bar must survive a filtered response');
      expect(identical(after, stored), isTrue, reason: 'and must not be rebuilt for no reason');
    });

    test('shelf chips from a continuation cannot replace the feed bar', () {
      final stored = storeChipBar({}, 'home', bar, isBaseBrowse: true);
      final shelfChips = [
        _chip('Shelf A', 'SHELF_1', scope: 'shelf'),
        _chip('Shelf B', 'SHELF_2', scope: 'shelf'),
      ];
      final after = storeChipBar(stored, 'home', shelfChips, isBaseBrowse: false);
      expect(after['home']?.map((c) => c.label), ['All', 'Music', 'Gaming']);
    });

    test('a base browse carrying only shelf chips leaves the bar alone', () {
      final stored = storeChipBar({}, 'home', bar, isBaseBrowse: true);
      final after = storeChipBar(
        stored,
        'home',
        [_chip('Shelf A', 'SHELF_1', scope: 'shelf')],
        isBaseBrowse: true,
      );
      expect(after['home']?.map((c) => c.label), ['All', 'Music', 'Gaming']);
    });

    test('one surface cannot show another surface bar', () {
      final bars = storeChipBar({}, 'home', bar, isBaseBrowse: true);
      expect(bars['subscriptions'], isNull);
      const state = FeedState(surface: 'subscriptions');
      expect(state.copyWith(chipBars: bars).chips, isEmpty);
    });
  });

  group('state', () {
    test('the bar is derived from the surface, not carried by each response', () {
      final bars = storeChipBar({}, 'home', bar, isBaseBrowse: true);
      const fresh = FeedState(surface: 'home');
      expect(fresh.chips, isEmpty);
      expect(fresh.copyWith(chipBars: bars).chips.length, 3);
    });

    test('copyWith can clear continuation — a filter switch must not page the old feed', () {
      const state = FeedState(surface: 'home', continuation: 'CONTINUATION_TOKEN_1');
      expect(state.copyWith(continuation: null).continuation, isNull);
    });

    test('copyWith can clear selectedToken back to unfiltered', () {
      const state = FeedState(surface: 'home', selectedToken: 'CHIP_TOKEN_1');
      expect(state.copyWith(selectedToken: null).selectedToken, isNull);
    });

    test('copyWith leaves untouched fields alone', () {
      const state = FeedState(
        surface: 'home',
        continuation: 'CONTINUATION_TOKEN_1',
        selectedToken: 'CHIP_TOKEN_1',
        error: 'boom',
      );
      final after = state.copyWith(isLoading: false);
      expect(after.continuation, 'CONTINUATION_TOKEN_1');
      expect(after.selectedToken, 'CHIP_TOKEN_1');
      expect(after.error, 'boom');
    });

    test('selection survives a filtered response, driven by the token', () {
      final bars = storeChipBar({}, 'home', bar, isBaseBrowse: true);
      final filtered =
          const FeedState(surface: 'home').copyWith(chipBars: bars, selectedToken: 'CHIP_TOKEN_1');
      expect(filtered.chips.length, 3, reason: 'bar still drawn while filtered');
      expect(filtered.selectedChip?.label, 'Music');
    });
  });
}
