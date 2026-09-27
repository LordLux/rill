import 'dart:io';

import '../../domain/update/update_manifest.dart';
import 'update_http.dart';
import 'update_verifier.dart';

class UpdateIntegrityException implements Exception {
  UpdateIntegrityException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdateDiskException implements Exception {
  UpdateDiskException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fetches a manifest's installer into `<root>\<version>\` (architecture.md
/// §2.14): streamed to `<name>.partial`, stopped the moment it passes the
/// manifest's size, verified for size and SHA-256, and only then renamed to its
/// real name. A file that fails any check is deleted, never kept.
class UpdateDownloader {
  UpdateDownloader({required this.http, required this.root});

  final UpdateHttp http;
  final Directory root;

  /// `%LOCALAPPDATA%\rill\updates`, beside the release logs.
  static Directory defaultRoot() => Directory('${Platform.environment['LOCALAPPDATA']}\\rill\\updates');

  /// A bare file name only: no separator, no drive, no stream suffix, nothing
  /// that could leave the version directory.
  static final _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  /// Where [manifest]'s installer lives once verified.
  File installerFor(UpdateManifest manifest) =>
      File('${root.path}\\${manifest.version}\\${manifest.windowsX64.name}');

  Future<File> download(UpdateManifest manifest, {void Function(int received, int total)? onProgress}) async {
    final asset = manifest.windowsX64;
    if (!_safeName.hasMatch(asset.name) || asset.name.contains('..')) {
      throw UpdateIntegrityException('refusing installer name "${asset.name}"');
    }
    final target = installerFor(manifest);
    final partial = File('${target.path}.partial');

    try {
      if (await target.exists()) {
        if (await verifyFile(target, size: asset.size, sha256: asset.sha256)) return target;
        await target.delete();
      }
      await target.parent.create(recursive: true);
      if (await partial.exists()) await partial.delete();
    } on FileSystemException catch (e) {
      throw UpdateDiskException('$e');
    }

    try {
      await _fetch(asset, partial, onProgress);
      if (!await verifyFile(partial, size: asset.size, sha256: asset.sha256)) {
        throw UpdateIntegrityException('the downloaded installer does not match the manifest\'s SHA-256');
      }
      return await partial.rename(target.path);
    } on Object catch (error) {
      await _deleteQuietly(partial);
      if (error is UpdateIntegrityException || error is UpdateNetworkException) rethrow;
      if (error is FileSystemException) throw UpdateDiskException('$error');
      throw UpdateNetworkException('$error');
    }
  }

  Future<void> _fetch(UpdateAsset asset, File partial, void Function(int, int)? onProgress) async {
    final stream = await http.openStream(asset.url);
    final sink = partial.openWrite();
    var received = 0;
    try {
      await for (final chunk in stream) {
        received += chunk.length;
        if (received > asset.size) {
          throw UpdateIntegrityException('the installer is larger than the manifest\'s ${asset.size} bytes');
        }
        sink.add(chunk);
        onProgress?.call(received, asset.size);
      }
    } finally {
      await sink.close();
    }
    if (received != asset.size) {
      throw UpdateIntegrityException('the installer is $received bytes, the manifest says ${asset.size}');
    }
  }

  /// Deletes every version directory but [keepVersion]. A locked file is
  /// logged and left for next time; it never fails the caller.
  Future<void> deleteStale({String? keepVersion}) async {
    try {
      if (!await root.exists()) return;
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final name = entity.path.split(RegExp(r'[\\/]')).last;
        if (name == keepVersion) continue;
        try {
          await entity.delete(recursive: true);
        } on FileSystemException catch (e) {
          stderr.writeln('rill update: could not delete stale ${entity.path} ($e)');
        }
      }
    } on FileSystemException catch (e) {
      stderr.writeln('rill update: could not list ${root.path} ($e)');
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (e) {
      stderr.writeln('rill update: could not delete ${file.path} ($e)');
    }
  }
}
