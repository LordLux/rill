import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_verifier.dart';
import 'package:rill/data/update/update_config.dart';
import 'package:rill/domain/update/update_state.dart';
import 'package:cryptography/dart.dart';

void main() {
  test('Update Check Tests', () async {
    final ed25519 = DartEd25519();
    final kp = await ed25519.newKeyPair();
    final pk = await kp.extractPublicKey();
    final keyBase64 = base64Encode(pk.bytes);
    
    final config = UpdateConfig.resolve(
      releaseMode: false,
      version: '1.0.0',
      feedOverride: '',
      keyOverride: keyBase64,
      prefixOverride: 'http://127.0.0.1:8765/',
    );
    
    Future<List<int>> sign(String jsonStr) async {
      final data = utf8.encode(jsonStr);
      final sig = await ed25519.sign(data, keyPair: kp);
      return utf8.encode(base64Encode(sig.bytes));
    }
    
    final validJson = '''{
      "schema": 1,
      "version": "1.1.0",
      "tag": "v1.1.0",
      "notes": [],
      "assets": {
        "windows-x64": {
          "name": "r.zip",
          "url": "http://127.0.0.1:8765/r.zip",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "size": 123
        }
      }
    }''';
    
    final validBytes = utf8.encode(validJson);
    final validSig = await sign(validJson);
    
    final newerCheck = await checkManifest(manifestBytes: validBytes, signatureFileBytes: validSig, config: config);
    expect(newerCheck, isA<ManifestNewer>());
    
    final badSigCheck = await checkManifest(manifestBytes: validBytes, signatureFileBytes: utf8.encode('bad'), config: config);
    expect(badSigCheck, isA<ManifestRejected>());
    expect((badSigCheck as ManifestRejected).kind, UpdateErrorKind.signature);
    
    final invalidJsonWithBadSig = await checkManifest(manifestBytes: utf8.encode('not json'), signatureFileBytes: utf8.encode('bad'), config: config);
    expect(invalidJsonWithBadSig, isA<ManifestRejected>());
    expect((invalidJsonWithBadSig as ManifestRejected).kind, UpdateErrorKind.signature);
    
    final badUrlJson = validJson.replaceAll('http://127.0.0.1:8765/r.zip', 'https://example.com/r.zip');
    final badUrlCheck = await checkManifest(manifestBytes: utf8.encode(badUrlJson), signatureFileBytes: await sign(badUrlJson), config: config);
    expect(badUrlCheck, isA<ManifestRejected>());
    
    final sameVerJson = validJson.replaceAll('"1.1.0"', '"1.0.0"').replaceAll('"v1.1.0"', '"v1.0.0"');
    final sameVerCheck = await checkManifest(manifestBytes: utf8.encode(sameVerJson), signatureFileBytes: await sign(sameVerJson), config: config);
    expect(sameVerCheck, isA<ManifestNotNewer>());
    
    final lowerVerJson = validJson.replaceAll('"1.1.0"', '"0.9.0"').replaceAll('"v1.1.0"', '"v0.9.0"');
    final lowerVerCheck = await checkManifest(manifestBytes: utf8.encode(lowerVerJson), signatureFileBytes: await sign(lowerVerJson), config: config);
    expect(lowerVerCheck, isA<ManifestNotNewer>());
    
    // The default prefix is the https rule: a plain-http asset URL cannot pass it.
    final embeddedPrefix = UpdateConfig.resolve(releaseMode: false, version: '1.0.0', keyOverride: keyBase64);
    final httpCheck = await checkManifest(manifestBytes: validBytes, signatureFileBytes: validSig, config: embeddedPrefix);
    expect(httpCheck, isA<ManifestRejected>());
    expect((httpCheck as ManifestRejected).kind, UpdateErrorKind.manifest);

    final schema2Json = validJson.replaceAll('"schema": 1', '"schema": 2');
    final schema2Check = await checkManifest(manifestBytes: utf8.encode(schema2Json), signatureFileBytes: await sign(schema2Json), config: config);
    expect(schema2Check, isA<ManifestIgnored>());
  });
}
