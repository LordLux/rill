import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';

void main() {
  test('Contract test against exported corpus', () {
    final corpusDir = Directory('../corpus');
    expect(corpusDir.existsSync(), isTrue, reason: 'Corpus directory not found. Did you run bun run export-contract-corpus?');

    for (final entity in corpusDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;

      final raw = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      
      final chips = raw['chips'] as List<dynamic>? ?? [];
      for (final chipJson in chips) {
        final chip = Chip.fromJson(chipJson as Map<String, dynamic>);
        expect(chip.label, isNotNull);
        expect(chip.token, isNotNull);
        expect(chip.scope, isNotNull);
      }

      final items = raw['items'] as List<dynamic>? ?? [];
      for (final itemJson in items) {
        final item = FeedItem.fromJson(itemJson as Map<String, dynamic>);
        // Validate that nothing threw and we have a valid FeedItem
        expect(item, isNotNull);
      }
    }
  });
}
