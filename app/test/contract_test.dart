import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/video_detail.dart';

void main() {
  test('Contract test against exported corpus', () {
    final corpusDir = Directory('../corpus');
    expect(corpusDir.existsSync(), isTrue, reason: 'Corpus directory not found. Did you run bun run export-contract-corpus?');

    for (final entity in corpusDir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json') || entity.path.endsWith('video-detail.json')) continue;

      final raw = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      
      // Root level keys
      for (final key in raw.keys) {
        expect(['items', 'chips', 'continuation'], contains(key), reason: 'Unknown key "$key" in root of ${entity.path}');
      }

      final chips = raw['chips'] as List<dynamic>? ?? [];
      for (final chipJson in chips) {
        final map = chipJson as Map<String, dynamic>;
        final chip = Chip.fromJson(map);
        expect(chip.label, isNotNull);
        for (final key in map.keys) {
          expect(['label', 'token', 'selected', 'scope'], contains(key), reason: 'Unknown key "$key" in Chip');
        }
      }

      final items = raw['items'] as List<dynamic>? ?? [];
      for (final itemJson in items) {
        final map = itemJson as Map<String, dynamic>;
        final item = FeedItem.fromJson(map);
        
        final expectedKeys = item.map(
          video: (_) => ['kind', 'id', 'title', 'channelName', 'channelId', 'channelAvatarUrl', 'thumbnailUrl', 'durationSeconds', 'isLive', 'viewCountText', 'publishedText', 'badges', 'premiereAtMs', 'canWatchLater', 'canAddToQueue'],
          mix: (_) => ['kind', 'id', 'title', 'subtitle', 'thumbnailUrl', 'videoCount'],
          playlist: (_) => ['kind', 'id', 'title', 'thumbnailUrl', 'videoCount', 'channelName'],
          channel: (_) => ['kind', 'id', 'name', 'avatarUrl', 'subscriberText'],
          unknown: (_) => ['kind'],
        );
        for (final key in map.keys) {
          expect(expectedKeys, contains(key), reason: 'Unknown key "$key" in FeedItem of kind ${map["kind"]}');
        }
      }
    }
    
    // Test VideoDetail against video-detail.json
    final videoDetailFile = File(join(corpusDir.path, 'video-detail.json'));
    if (videoDetailFile.existsSync()) {
      final raw = jsonDecode(videoDetailFile.readAsStringSync()) as Map<String, dynamic>;
      final detail = VideoDetail.fromJson(raw);
      expect(detail.id, isNotNull);
      
      final expectedKeys = [
        'id', 'title', 'description', 'channelName', 'channelId', 
        'channelAvatarUrl', 'subscriberText', 'durationSeconds', 
        'isLive', 'viewCountText', 'publishedText', 'likeText', 
        'isSubscribed', 'badges', 'premiereAtMs', 'captionTracks', 
        'related', 'relatedContinuation'
      ];
      
      for (final key in raw.keys) {
        expect(expectedKeys, contains(key), reason: 'Unknown key "$key" in VideoDetail');
      }
      
      final related = raw['related'] as List<dynamic>? ?? [];
      for (final itemJson in related) {
        final map = itemJson as Map<String, dynamic>;
        final item = FeedItem.fromJson(map);
        final expectedFeedKeys = item.map(
          video: (_) => ['kind', 'id', 'title', 'channelName', 'channelId', 'channelAvatarUrl', 'thumbnailUrl', 'durationSeconds', 'isLive', 'viewCountText', 'publishedText', 'badges', 'premiereAtMs', 'canWatchLater', 'canAddToQueue'],
          mix: (_) => ['kind', 'id', 'title', 'subtitle', 'thumbnailUrl', 'videoCount'],
          playlist: (_) => ['kind', 'id', 'title', 'thumbnailUrl', 'videoCount', 'channelName'],
          channel: (_) => ['kind', 'id', 'name', 'avatarUrl', 'subscriberText'],
          unknown: (_) => ['kind'],
        );
        for (final key in map.keys) {
          expect(expectedFeedKeys, contains(key), reason: 'Unknown key "$key" in related FeedItem');
        }
      }
    }
  });
}
