import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/update/update_manifest.dart';

void main() {
  test('UpdateManifest parses valid fixture', () {
    final validJson = {
      "schema": 1,
      "version": "0.2.2",
      "tag": "v0.2.2",
      "publishedAt": "2026-09-01T12:00:00Z",
      "notes": ["Feature 1", "Feature 2"],
      "minimumVersion": "0.1.0",
      "assets": {
        "windows-x64": {
          "name": "rill-0.2.2-windows-x64.zip",
          "url": "https://github.com/LordLux/rill/releases/download/v0.2.2/rill-0.2.2-windows-x64.zip",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "size": 12345
        }
      }
    };
    
    final bytes = utf8.encode(jsonEncode(validJson));
    final result = parseUpdateManifest(bytes);
    
    expect(result, isA<ManifestOk>());
    final manifest = (result as ManifestOk).manifest;
    expect(manifest.version.toString(), '0.2.2');
    expect(manifest.notes.length, 2);
    expect(manifest.windowsX64.name, 'rill-0.2.2-windows-x64.zip');
    expect(manifest.minimumVersion?.toString(), '0.1.0');
  });

  test('UpdateManifest invalid cases', () {
    ManifestParseResult parse(Map<String, dynamic> j) => parseUpdateManifest(utf8.encode(jsonEncode(j)));
    
    expect(parseUpdateManifest(utf8.encode('not json')), isA<ManifestInvalid>());
    expect(parseUpdateManifest(utf8.encode('[]')), isA<ManifestInvalid>());
    
    final base = {
      "schema": 1,
      "version": "0.2.2",
      "tag": "v0.2.2",
      "assets": {
        "windows-x64": {
          "name": "rill-0.2.2.zip",
          "url": "https://example.com/rill-0.2.2.zip",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "size": 123
        }
      }
    };

    expect(parse({...base}..remove('schema')), isA<ManifestInvalid>());
    expect(parse({...base, 'schema': 2}), isA<ManifestUnknownSchema>());

    expect(parse({...base}..remove('version')), isA<ManifestInvalid>());
    expect(parse({...base, 'version': 'bad'}), isA<ManifestInvalid>());
    
    expect(parse({...base, 'tag': 'v0.2.3'}), isA<ManifestInvalid>());
    
    expect(parse({...base}..remove('assets')), isA<ManifestInvalid>());
    expect(parse({...base, 'assets': {}}), isA<ManifestInvalid>());
    
    final badAssets = {...base};
    badAssets['assets'] = {
      "windows-x64": {
        "name": "r.zip",
        "url": "https://a.com",
        "sha256": "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
        "size": 123
      }
    };
    expect(parse(badAssets), isA<ManifestInvalid>()); // uppercase sha256

    final badSize = {...base};
    badSize['assets'] = {
      "windows-x64": {
        "name": "r.zip",
        "url": "https://a.com",
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "size": -1
      }
    };
    expect(parse(badSize), isA<ManifestInvalid>());
    
    final relativeUrl = {...base};
    relativeUrl['assets'] = {
      "windows-x64": {
        "name": "r.zip",
        "url": "/a.zip",
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "size": 123
      }
    };
    expect(parse(relativeUrl), isA<ManifestInvalid>());
    
    expect(parse({...base, 'minimumVersion': 'garbage'}), isA<ManifestInvalid>());
    expect(parse({...base, 'minimumVersion': null}), isA<ManifestOk>());
    expect(parse({...base, 'minimumVersion': '0.3.0'}), isA<ManifestOk>());

    final mixedNotes = {...base, 'notes': [123, "hello"]};
    final res = parse(mixedNotes);
    expect(res, isA<ManifestOk>());
    expect((res as ManifestOk).manifest.notes, ["hello"]);
  });

  test('a schema of 1.0 is an unknown schema, and parsing never throws', () {
    final text = File('test/signed_update/update.json').readAsStringSync().replaceFirst('"schema": 1', '"schema": 1.0');
    expect(() => parseUpdateManifest(utf8.encode(text)), returnsNormally);
    expect(parseUpdateManifest(utf8.encode(text)), isA<ManifestUnknownSchema>());
  });
}
