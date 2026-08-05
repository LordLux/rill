import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_youtube/domain/feed_item.dart';
import 'package:native_youtube/ui/widgets/media_tile.dart';

void main() {
  test('Mapper test over real corpus', () {
    final corpusDir = Directory('../corpus');
    expect(corpusDir.existsSync(), isTrue);

    for (final entity in corpusDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final raw = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      
      final items = raw['items'] as List<dynamic>? ?? [];
      for (final itemJson in items) {
        final item = FeedItem.fromJson(itemJson as Map<String, dynamic>);
        
        final spec = specFor(item);
        
        if (item is UnknownItem || item is ChannelItem) {
          expect(spec, isNull, reason: '${item.kind} must map to null');
        } else {
          expect(spec, isNotNull, reason: '${item.kind} must map to a TileSpec');
          expect(spec!.title, isNotEmpty);
          expect(spec.thumbnailUrl, isNotEmpty);
        }
      }
    }
  });
}
