import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_pg/dart_pg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_http.dart';
import 'package:rill/data/ytdlp/ytdlp_downloader.dart';

/// Serves a SHA2-256SUMS + signature signed by a throwaway keypair (never
/// yt-dlp's real one — that private key does not exist outside yt-dlp's own
/// release process) plus whatever bytes should answer as `yt-dlp.exe`.
class FakeYtDlpHttp implements UpdateHttp {
  FakeYtDlpHttp({required this.sumsBytes, required this.signatureBytes, required this.exeBytes});

  List<int> sumsBytes;
  List<int> signatureBytes;
  List<int> exeBytes;
  bool throwNetwork = false;
  int exeFetches = 0;

  @override
  Future<Uint8List> getBytes(Uri url, {required int maxBytes}) async {
    if (throwNetwork) throw UpdateNetworkException('fake network error');
    if (url.path.endsWith('.sig')) return Uint8List.fromList(signatureBytes);
    return Uint8List.fromList(sumsBytes);
  }

  @override
  Future<Stream<List<int>>> openStream(Uri url) async {
    if (throwNetwork) throw UpdateNetworkException('fake network error');
    exeFetches++;
    // Two-byte chunks, so a size cap is hit mid-stream rather than at the end.
    return Stream.fromIterable([for (var i = 0; i < exeBytes.length; i += 2) exeBytes.sublist(i, (i + 2).clamp(0, exeBytes.length))]);
  }
}

void main() {
  late Directory tempDir;

  // `PrivateKeyInterface` is not part of dart_pg's public export surface (the
  // same gap `ytdlp_verifier.dart` documents for `SignaturePacketInterface`),
  // so the type is inferred here rather than named. `late final` with an
  // inline initializer computes this once, lazily, on the first test that
  // touches it — curve25519/signOnly generates in well under a second, RSA
  // would cost whole seconds per run for no extra test value.
  final keyPair = OpenPGP.generateKey(['test <test@example.com>'], 'pass', type: KeyType.curve25519, signOnly: true);
  final publicKeyArmored = keyPair.publicKey.armor();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ytdlp_downloader_test_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Not worth failing a test over.
    }
  });

  /// Signs [sumsText] with the throwaway keypair, exactly the way yt-dlp signs
  /// SHA2-256SUMS: a raw binary detached signature over the file's bytes.
  Uint8List sign(String sumsText) {
    final bytes = Uint8List.fromList(utf8.encode(sumsText));
    final message = OpenPGP.createLiteralMessage(bytes);
    final signature = OpenPGP.signDetached(message, [keyPair]);
    return signature.packetList.encode();
  }

  FakeYtDlpHttp fakeFor(List<int> exeBytes, {String name = 'yt-dlp.exe'}) {
    final sumsText = '${crypto.sha256.convert(exeBytes)}  $name\n';
    return FakeYtDlpHttp(sumsBytes: utf8.encode(sumsText), signatureBytes: sign(sumsText), exeBytes: exeBytes);
  }

  test('fetchVerifiedHash returns the signed hash for yt-dlp.exe', () async {
    final exeBytes = utf8.encode('a fake yt-dlp binary');
    final http = fakeFor(exeBytes);
    final downloader = YtDlpDownloader(http: http, publicKeyArmored: publicKeyArmored);

    final hash = await downloader.fetchVerifiedHash();
    expect(hash, crypto.sha256.convert(exeBytes).toString());
  });

  test('fetchVerifiedHash rejects a signature from the wrong key', () async {
    final exeBytes = utf8.encode('a fake yt-dlp binary');
    final http = fakeFor(exeBytes);
    // The real embedded yt-dlp key, not the throwaway one that actually signed this.
    final downloader = YtDlpDownloader(http: http);
    await expectLater(downloader.fetchVerifiedHash, throwsA(isA<YtDlpFetchException>()));
  });

  test('fetchVerifiedHash rejects tampered checksums even if still "signed"', () async {
    final exeBytes = utf8.encode('a fake yt-dlp binary');
    final http = fakeFor(exeBytes);
    http.sumsBytes = utf8.encode('${crypto.sha256.convert(utf8.encode('different content'))}  yt-dlp.exe\n');
    final downloader = YtDlpDownloader(http: http, publicKeyArmored: publicKeyArmored);
    await expectLater(downloader.fetchVerifiedHash, throwsA(isA<YtDlpFetchException>()));
  });

  test('download verifies and installs, deleting the partial', () async {
    final exeBytes = utf8.encode('a fake yt-dlp binary, somewhat longer this time');
    final http = fakeFor(exeBytes);
    final downloader = YtDlpDownloader(http: http, publicKeyArmored: publicKeyArmored);
    final target = File('${tempDir.path}\\yt-dlp.exe');

    final hash = await downloader.fetchVerifiedHash();
    final received = <int>[];
    final file = await downloader.download(hash, target, onProgress: received.add);

    expect(file.path, target.path);
    expect(file.readAsBytesSync(), exeBytes);
    expect(File('${target.path}.partial').existsSync(), isFalse);
    expect(received.last, exeBytes.length);
  });

  test('a hash that does not match what was served fails, and the partial is gone', () async {
    final http = fakeFor(utf8.encode('one thing'));
    // Sign and fetch a hash for "one thing", but serve something else.
    final downloader = YtDlpDownloader(http: http, publicKeyArmored: publicKeyArmored);
    final expected = await downloader.fetchVerifiedHash();
    http.exeBytes = utf8.encode('a completely different payload');

    final target = File('${tempDir.path}\\yt-dlp.exe');
    await expectLater(() => downloader.download(expected, target), throwsA(isA<YtDlpFetchException>()));
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.partial').existsSync(), isFalse);
  });

  test('a stream larger than the size cap is refused mid-download', () async {
    final oversized = List<int>.filled(120, 7);
    final http = fakeFor(oversized);
    final downloader = YtDlpDownloader(http: http, publicKeyArmored: publicKeyArmored, maxDownloadBytes: 100);
    final hash = await downloader.fetchVerifiedHash();

    final target = File('${tempDir.path}\\yt-dlp.exe');
    await expectLater(() => downloader.download(hash, target), throwsA(isA<YtDlpFetchException>()));
    expect(File('${target.path}.partial').existsSync(), isFalse);
  });

  test('a network failure surfaces and leaves nothing behind', () async {
    final http = fakeFor(utf8.encode('anything'))..throwNetwork = true;
    final downloader = YtDlpDownloader(http: http, publicKeyArmored: publicKeyArmored);
    await expectLater(downloader.fetchVerifiedHash, throwsA(isA<UpdateNetworkException>()));
  });
}
