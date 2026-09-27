import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_config.dart';
import 'package:rill/domain/update/app_version.dart';

void main() {
  test('UpdateConfig resolve release mode', () {
    final config = UpdateConfig.resolve(
      releaseMode: true,
      version: '1.0.0',
      feedOverride: 'http://127.0.0.1:8080/feed.json',
      keyOverride: base64Encode(List.filled(32, 1)),
      prefixOverride: 'http://127.0.0.1:8080/assets/',
    );

    expect(config.activeOverrides, isEmpty);
    expect(config.describe(), 'embedded');
    expect(config.allowedAssetPrefix, 'https://github.com/LordLux/rill/releases/download/');
    expect(config.manifestUrl.toString(), 'https://github.com/LordLux/rill/releases/latest/download/update.json');
  });

  test('UpdateConfig resolve non-release mode overrides', () {
    final key = base64Encode(List.filled(32, 1));
    final config = UpdateConfig.resolve(
      releaseMode: false,
      version: '1.0.0',
      feedOverride: 'http://127.0.0.1:8080/feed.json',
      keyOverride: key,
      prefixOverride: 'http://127.0.0.1:8080/assets/',
    );

    expect(config.activeOverrides, containsAll(['feed', 'key', 'prefix']));
    expect(config.describe(), contains('overridden: feed/key/prefix'));
    expect(config.describe().contains(key), isFalse);
    expect(config.manifestUrl.toString(), 'http://127.0.0.1:8080/feed.json');
    expect(config.allowedAssetPrefix, 'http://127.0.0.1:8080/assets/');
    expect(config.publicKey, List.filled(32, 1));
  });

  test('UpdateConfig resolve non-release invalid overrides', () {
    expect(() => UpdateConfig.resolve(
      releaseMode: false,
      version: '1.0.0',
      feedOverride: 'http://example.com/feed.json',
      keyOverride: '',
      prefixOverride: '',
    ), throwsArgumentError);

    expect(() => UpdateConfig.resolve(
      releaseMode: false,
      version: '1.0.0',
      feedOverride: '',
      keyOverride: base64Encode(List.filled(31, 1)),
      prefixOverride: '',
    ), throwsArgumentError);

    expect(() => UpdateConfig.resolve(
      releaseMode: false,
      version: '1.0.0',
      feedOverride: '',
      keyOverride: '',
      prefixOverride: 'http://example.com/assets/',
    ), throwsArgumentError);

    expect(() => UpdateConfig.resolve(
      releaseMode: false,
      version: '1.0.0',
      feedOverride: '',
      keyOverride: '',
      prefixOverride: 'https://example.com/assets',
    ), throwsArgumentError);
  });

  test('release mode ignores overrides even when they are malformed', () {
    final config = UpdateConfig.resolve(
      releaseMode: true,
      version: '1.0.0',
      feedOverride: 'http://example.com/feed.json',
      keyOverride: 'not base64',
      prefixOverride: 'ftp://nope',
    );
    expect(config.overridden, isFalse);
    expect(config.publicKey, base64Decode(UpdateConfig.embeddedPublicKeyBase64));
  });

  test('a key override that is not base64 throws in a test build', () {
    expect(() => UpdateConfig.resolve(releaseMode: false, version: '1.0.0', keyOverride: 'not base64!'), throwsArgumentError);
  });

  test('UpdateConfig version parsing', () {
    final c1 = UpdateConfig.resolve(releaseMode: true, version: '', feedOverride: '', keyOverride: '', prefixOverride: '');
    expect(c1.enabled, isFalse);
    expect(c1.currentVersion, isNull);

    final c2 = UpdateConfig.resolve(releaseMode: true, version: '0.0.1', feedOverride: '', keyOverride: '', prefixOverride: '');
    expect(c2.enabled, isTrue);
    expect(c2.currentVersion, const AppVersion(major: 0, minor: 0, patch: 1));
  });
}
