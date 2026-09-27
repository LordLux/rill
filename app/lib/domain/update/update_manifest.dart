import 'dart:convert';

import 'app_version.dart';

// The manifest `release/make-manifest.ts` signs. Strict: a field that is not
// what it should be is a rejected manifest, never a guess (architecture.md §2.14).

class UpdateAsset {
  final String name;
  final Uri url;
  final String sha256;
  final int size;

  const UpdateAsset({
    required this.name,
    required this.url,
    required this.sha256,
    required this.size,
  });
}

class UpdateManifest {
  final int schema;
  final AppVersion version;
  final String tag;
  final DateTime? publishedAt;
  final List<String> notes;
  final AppVersion? minimumVersion;
  final UpdateAsset windowsX64;

  const UpdateManifest({
    required this.schema,
    required this.version,
    required this.tag,
    this.publishedAt,
    required this.notes,
    this.minimumVersion,
    required this.windowsX64,
  });
}

sealed class ManifestParseResult {}

final class ManifestOk extends ManifestParseResult {
  final UpdateManifest manifest;
  ManifestOk(this.manifest);
}

final class ManifestUnknownSchema extends ManifestParseResult {
  final Object? schema;
  ManifestUnknownSchema(this.schema);
}

final class ManifestInvalid extends ManifestParseResult {
  final String reason;
  ManifestInvalid(this.reason);
}

ManifestParseResult parseUpdateManifest(List<int> bytes) {
  Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  } catch (_) {
    return ManifestInvalid('malformed');
  }

  if (json is! Map<String, dynamic>) {
    return ManifestInvalid('not an object');
  }

  if (!json.containsKey('schema')) {
    return ManifestInvalid('schema');
  }
  // `1.0 == 1` in Dart, so the type is checked before the value.
  final schema = json['schema'];
  if (schema is! int || schema != 1) {
    return ManifestUnknownSchema(schema);
  }

  final versionStr = json['version'];
  if (versionStr is! String) return ManifestInvalid('version');
  final version = AppVersion.tryParse(versionStr);
  if (version == null) return ManifestInvalid('version');

  final tag = json['tag'];
  if (tag is! String || tag != 'v$version') return ManifestInvalid('tag');

  DateTime? publishedAt;
  final pubAt = json['publishedAt'];
  if (pubAt is String) {
    publishedAt = DateTime.tryParse(pubAt);
  }

  final notesRaw = json['notes'];
  final notes = <String>[];
  if (notesRaw is List) {
    for (final e in notesRaw) {
      if (e is String) notes.add(e);
    }
  }

  AppVersion? minimumVersion;
  if (json.containsKey('minimumVersion') && json['minimumVersion'] != null) {
    final minVerStr = json['minimumVersion'];
    if (minVerStr is! String) return ManifestInvalid('minimumVersion');
    minimumVersion = AppVersion.tryParse(minVerStr);
    if (minimumVersion == null) return ManifestInvalid('minimumVersion');
  }

  final assets = json['assets'];
  if (assets is! Map<String, dynamic>) return ManifestInvalid('assets');

  final winAsset = assets['windows-x64'];
  if (winAsset is! Map<String, dynamic>) return ManifestInvalid('windows-x64');

  final name = winAsset['name'];
  if (name is! String || name.isEmpty) return ManifestInvalid('name');

  final urlStr = winAsset['url'];
  if (urlStr is! String) return ManifestInvalid('url');
  final url = Uri.tryParse(urlStr);
  if (url == null || !url.isAbsolute) return ManifestInvalid('url');

  final sha256 = winAsset['sha256'];
  if (sha256 is! String || sha256.length != 64 || RegExp(r'[^a-f0-9]').hasMatch(sha256)) return ManifestInvalid('sha256');

  final size = winAsset['size'];
  if (size is! int || size <= 0) return ManifestInvalid('size');

  return ManifestOk(UpdateManifest(
    schema: schema,
    version: version,
    tag: tag,
    publishedAt: publishedAt,
    notes: notes,
    minimumVersion: minimumVersion,
    windowsX64: UpdateAsset(
      name: name,
      url: url,
      sha256: sha256,
      size: size,
    ),
  ));
}
