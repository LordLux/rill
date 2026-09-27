import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/ytdlp/ytdlp_verifier.dart';

void main() {
  // Real assets from a yt-dlp release (test/ytdlp_fixtures/), so this is a
  // known-answer test against the actual thing being verified, not a
  // synthetic stand-in — the same reasoning as `update_signature_test.dart`.
  final sums = File('test/ytdlp_fixtures/SHA2-256SUMS').readAsBytesSync();
  final signature = File('test/ytdlp_fixtures/SHA2-256SUMS.sig').readAsBytesSync();

  test('real SHA2-256SUMS verifies against the vendored key', () {
    expect(verifySha256SumsSignature(sumsBytes: sums, signatureBytes: signature), isTrue);
  });

  test('a flipped byte in the checksums file fails verification', () {
    final tampered = Uint8List.fromList(sums);
    tampered[0] ^= 1;
    expect(verifySha256SumsSignature(sumsBytes: tampered, signatureBytes: signature), isFalse);
  });

  test('a flipped byte in the signature fails verification', () {
    final tampered = Uint8List.fromList(signature);
    tampered[tampered.length - 1] ^= 1;
    expect(verifySha256SumsSignature(sumsBytes: sums, signatureBytes: tampered), isFalse);
  });

  test('an unrelated public key fails verification', () {
    // A different, unrelated real-world armored key (this app's own update
    // signing... no — that one is Ed25519, not PGP. Use a syntactically valid
    // but wrong PGP key: swap one byte inside the vendored key's material.
    final tampered = YtDlpConfig.publicKeyArmored.replaceFirst('mQINBGP78C4B', 'mQINBGP78C4C');
    expect(
      verifySha256SumsSignature(sumsBytes: sums, signatureBytes: signature, publicKeyArmored: tampered),
      isFalse,
    );
  });

  test('garbage signature bytes fail rather than throw', () {
    expect(verifySha256SumsSignature(sumsBytes: sums, signatureBytes: utf8.encode('not a signature')), isFalse);
  });

  test('SHA2-256SUMS lists a 64-hex-char entry for yt-dlp.exe', () {
    final hashes = parseSha256Sums(utf8.decode(sums));
    expect(hashes[YtDlpConfig.assetName], matches(RegExp(r'^[0-9a-f]{64}$')));
  });
}
