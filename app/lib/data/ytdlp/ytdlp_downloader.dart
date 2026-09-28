import 'dart:convert';
import 'dart:io';

import '../update/update_http.dart';
import 'ytdlp_verifier.dart';

class YtDlpFetchException implements Exception {
  YtDlpFetchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fetches, PGP- and SHA-256-verifies, and installs yt-dlp's Windows binary
/// (docs/todo.md 49) — the same streamed-to-`.partial`, verify-then-rename
/// shape as `update/update_downloader.dart`, reusing its [UpdateHttp] rather
/// than a second HTTP client.
class YtDlpDownloader {
  YtDlpDownloader({
    required this.http,
    this.publicKeyArmored = YtDlpConfig.publicKeyArmored,
    this.maxDownloadBytes = YtDlpConfig.maxDownloadBytes,
  });

  final UpdateHttp http;

  /// Overridable only for tests — a real run always verifies against yt-dlp's
  /// own vendored key.
  final String publicKeyArmored;

  /// Overridable only for tests, so the size-cap test does not have to move
  /// 150 MB through a fake stream to prove the cap is enforced.
  final int maxDownloadBytes;

  /// The hash `SHA2-256SUMS` gives for yt-dlp.exe, after checking the listing
  /// itself is signed by yt-dlp's key. Cheap (well under a kilobyte both
  /// ways) and downloads no binary — a refresh check calls this alone to
  /// decide whether the installed copy is already current before fetching
  /// 18 MB it may not need.
  Future<String> fetchVerifiedHash() async {
    final sums = await http.getBytes(YtDlpConfig.sumsUrl, maxBytes: 64 * 1024);
    final signature = await http.getBytes(YtDlpConfig.sumsSignatureUrl, maxBytes: 8 * 1024);
    if (!verifySha256SumsSignature(sumsBytes: sums, signatureBytes: signature, publicKeyArmored: publicKeyArmored)) {
      throw YtDlpFetchException("SHA2-256SUMS's PGP signature does not verify");
    }
    final hashes = parseSha256Sums(utf8.decode(sums));
    final hash = hashes[YtDlpConfig.assetName];
    if (hash == null) {
      throw YtDlpFetchException('SHA2-256SUMS has no entry for ${YtDlpConfig.assetName}');
    }
    return hash;
  }

  /// Downloads `yt-dlp.exe` to `<target>.partial`, checks it against
  /// [expectedSha256] and the size cap, and renames it into place. The
  /// partial is always deleted on failure — nothing half-written is ever left
  /// where [target] would be mistaken for a real copy.
  Future<File> download(
    String expectedSha256,
    File target, {
    void Function(int received)? onProgress,
  }) async {
    final partial = File('${target.path}.partial');
    await target.parent.create(recursive: true);
    if (await partial.exists()) await partial.delete();

    try {
      final stream = await http.openStream(YtDlpConfig.exeUrl);
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in stream) {
          received += chunk.length;
          if (received > maxDownloadBytes) {
            throw YtDlpFetchException('yt-dlp.exe is larger than the $maxDownloadBytes-byte cap');
          }
          sink.add(chunk);
          onProgress?.call(received);
        }
      } finally {
        await sink.close();
      }
      if (!await verifyYtDlpFile(partial, sha256: expectedSha256)) {
        throw YtDlpFetchException('the downloaded yt-dlp.exe does not match SHA2-256SUMS');
      }
      return await partial.rename(target.path);
    } on Object catch (error) {
      await _deleteQuietly(partial);
      if (error is YtDlpFetchException || error is UpdateNetworkException) rethrow;
      throw YtDlpFetchException('$error');
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (e) {
      stderr.writeln('rill yt-dlp: could not delete ${file.path} ($e)');
    }
  }
}
