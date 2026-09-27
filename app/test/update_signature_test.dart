import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_verifier.dart';
import 'package:rill/data/update/update_config.dart';
import 'package:cryptography/dart.dart';

void main() {
  test('Signature KNOWN-ANSWER test', () async {
    final manifestBytes = File('test/signed_update/update.json').readAsBytesSync();
    final signatureBytes = File('test/signed_update/update.json.sig').readAsBytesSync();
    final pubKey = base64Decode(UpdateConfig.embeddedPublicKeyBase64);
    
    final ok = await verifyManifestSignature(
      manifestBytes: manifestBytes, 
      signatureFileBytes: signatureBytes, 
      publicKey: pubKey
    );
    expect(ok, isTrue);
  });

  test('Signature failure cases', () async {
    final manifestBytes = File('test/signed_update/update.json').readAsBytesSync();
    final signatureBytes = File('test/signed_update/update.json.sig').readAsBytesSync();
    final pubKey = base64Decode(UpdateConfig.embeddedPublicKeyBase64);

    final badManifest = List<int>.from(manifestBytes);
    badManifest[0] ^= 1;
    expect(await verifyManifestSignature(manifestBytes: badManifest, signatureFileBytes: signatureBytes, publicKey: pubKey), isFalse);

    final badSig = List<int>.from(signatureBytes);
    badSig[0] ^= 1;
    expect(await verifyManifestSignature(manifestBytes: manifestBytes, signatureFileBytes: badSig, publicKey: pubKey), isFalse);

    final kp = await DartEd25519().newKeyPair();
    final pk = await kp.extractPublicKey();
    expect(await verifyManifestSignature(manifestBytes: manifestBytes, signatureFileBytes: signatureBytes, publicKey: pk.bytes), isFalse);

    final decoded = base64Decode(utf8.decode(signatureBytes).trim());
    decoded[63] ^= 0x01;
    expect(
      await verifyManifestSignature(manifestBytes: manifestBytes, signatureFileBytes: utf8.encode(base64Encode(decoded)), publicKey: pubKey),
      isFalse,
    );

    final shortSig = utf8.encode(base64Encode(List.filled(63, 0)));
    expect(await verifyManifestSignature(manifestBytes: manifestBytes, signatureFileBytes: shortSig, publicKey: pubKey), isFalse);
    
    expect(await verifyManifestSignature(manifestBytes: manifestBytes, signatureFileBytes: utf8.encode('???'), publicKey: pubKey), isFalse);
  });

  test('Embedded key equals update-signing.pub', () {
    // Fails rather than skips when the file is missing: a skipped key check is
    // how the app and the signer drift apart unnoticed.
    final text = File('../release/update-signing.pub').readAsStringSync().trim();
    expect(UpdateConfig.embeddedPublicKeyBase64, text);
  });

  test('Round trip with freshly generated keypair', () async {
    final ed25519 = DartEd25519();
    final kp = await ed25519.newKeyPair();
    final pk = await kp.extractPublicKey();
    
    final data = utf8.encode('hello world');
    final sig = await ed25519.sign(data, keyPair: kp);
    
    final sigFileBytes = utf8.encode(base64Encode(sig.bytes));
    
    final ok = await verifyManifestSignature(manifestBytes: data, signatureFileBytes: sigFileBytes, publicKey: pk.bytes);
    expect(ok, isTrue);
  });
}
