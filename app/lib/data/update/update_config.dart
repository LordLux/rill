import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/update/app_version.dart';

/// Where the updater looks, whose signature it trusts, and which asset URLs it
/// will download — resolved once, at one place (architecture.md §2.14).
///
/// Everything is a compile-time constant. The three `RILL_UPDATE_*` defines
/// exist for testing against a local feed and are honoured only when the build
/// is not a release build; nothing a user or a file can change at runtime
/// reaches this.
class UpdateConfig {
  const UpdateConfig({
    required this.currentVersion,
    required this.manifestUrl,
    required this.signatureUrl,
    required this.publicKey,
    required this.allowedAssetPrefix,
    required this.activeOverrides,
  });

  /// The running build's version; null in a dev build, which has nothing to
  /// compare against and so never checks.
  final AppVersion? currentVersion;
  final Uri manifestUrl;
  final Uri signatureUrl;

  /// Raw Ed25519 public key, 32 bytes.
  final List<int> publicKey;

  /// The ONLY asset-URL rule, https included: a manifest whose installer URL
  /// does not start with this is rejected.
  final String allowedAssetPrefix;

  /// Which of `feed`, `key`, `prefix` came from a test define; empty for the
  /// embedded configuration.
  final List<String> activeOverrides;

  bool get enabled => currentVersion != null;
  bool get overridden => activeOverrides.isNotEmpty;

  /// For the startup log line. Never includes key material.
  String describe() => overridden ? 'overridden: ${activeOverrides.join('/')}' : 'embedded';

  static const embeddedManifestUrl = 'https://github.com/LordLux/rill/releases/latest/download/update.json';
  static const embeddedAssetPrefix = 'https://github.com/LordLux/rill/releases/download/';

  /// `release/update-signing.pub`; a test checks the two agree.
  static const embeddedPublicKeyBase64 = '6+8Nktorj+TkO4KoCVHNHcrZWPKOdmF0w3nuRZes14Q=';

  static final _loopbackPrefix = RegExp(r'^http://127\.0\.0\.1:\d{1,5}/');

  /// [releaseMode] is a parameter so both branches are testable; production
  /// passes `kReleaseMode` through [fromEnvironment]. In a release build every
  /// override is ignored, whatever its value. In any other build an override
  /// that is present but malformed throws: a test build pointed at the wrong
  /// place should fail loudly, not quietly fall back to the real feed.
  static UpdateConfig resolve({
    required bool releaseMode,
    required String version,
    String feedOverride = '',
    String keyOverride = '',
    String prefixOverride = '',
  }) {
    final currentVersion = AppVersion.tryParse(version);
    if (version.isNotEmpty && currentVersion == null) {
      stderr.writeln('rill update: RILL_VERSION "$version" is not MAJOR.MINOR.PATCH; updater off');
    }

    var feed = embeddedManifestUrl;
    List<int> key = base64Decode(embeddedPublicKeyBase64);
    var prefix = embeddedAssetPrefix;
    final active = <String>[];

    if (!releaseMode) {
      if (feedOverride.isNotEmpty) {
        final uri = Uri.tryParse(feedOverride);
        final ok = uri != null && (uri.scheme == 'https' && uri.host.isNotEmpty || _loopbackPrefix.hasMatch(feedOverride));
        if (!ok) throw ArgumentError.value(feedOverride, 'RILL_UPDATE_FEED', 'must be https:// or http://127.0.0.1:PORT/');
        feed = feedOverride;
        active.add('feed');
      }
      if (keyOverride.isNotEmpty) {
        List<int>? decoded;
        try {
          decoded = base64Decode(keyOverride);
        } on FormatException {
          decoded = null;
        }
        if (decoded == null || decoded.length != 32) {
          throw ArgumentError('RILL_UPDATE_PUBKEY must be the base64 of exactly 32 bytes');
        }
        key = decoded;
        active.add('key');
      }
      if (prefixOverride.isNotEmpty) {
        final https = prefixOverride.startsWith('https://') && prefixOverride.length > 'https://'.length;
        if (!(https || _loopbackPrefix.hasMatch(prefixOverride)) || !prefixOverride.endsWith('/')) {
          throw ArgumentError.value(prefixOverride, 'RILL_UPDATE_ASSET_PREFIX', 'must be https://…/ or http://127.0.0.1:PORT/…/');
        }
        prefix = prefixOverride;
        active.add('prefix');
      }
    }

    return UpdateConfig(
      currentVersion: currentVersion,
      manifestUrl: Uri.parse(feed),
      signatureUrl: Uri.parse('$feed.sig'),
      publicKey: List.unmodifiable(key),
      allowedAssetPrefix: prefix,
      activeOverrides: List.unmodifiable(active),
    );
  }

  static UpdateConfig fromEnvironment() => resolve(
    releaseMode: kReleaseMode,
    version: const String.fromEnvironment('RILL_VERSION'),
    feedOverride: const String.fromEnvironment('RILL_UPDATE_FEED'),
    keyOverride: const String.fromEnvironment('RILL_UPDATE_PUBKEY'),
    prefixOverride: const String.fromEnvironment('RILL_UPDATE_ASSET_PREFIX'),
  );
}
