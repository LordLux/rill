import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../../domain/update/update_manifest.dart';
import '../../domain/update/update_state.dart';
import 'update_config.dart';

/// Ed25519 over the manifest's EXACT bytes, as `release/make-manifest.ts` signs
/// them. Never re-encodes. [signatureFileBytes] is `update.json.sig` as served:
/// base64 of a 64-byte signature, trailing whitespace allowed. Any failure,
/// malformed input included, is `false`.
Future<bool> verifyManifestSignature({
  required List<int> manifestBytes,
  required List<int> signatureFileBytes,
  required List<int> publicKey,
}) async {
  try {
    if (publicKey.length != 32) return false;
    final signature = base64Decode(ascii.decode(signatureFileBytes).trim());
    if (signature.length != 64) return false;
    // The pure-Dart implementation explicitly: the same code in a unit test and
    // in the app, with no platform plugin in between.
    return await DartEd25519().verify(
      manifestBytes,
      signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  } on Object {
    return false;
  }
}

sealed class ManifestCheck {}

/// Refused: a bad signature, an invalid manifest, or an asset URL outside the
/// allowed prefix.
final class ManifestRejected extends ManifestCheck {
  ManifestRejected(this.kind, this.message);
  final UpdateErrorKind kind;
  final String message;
}

/// Validly signed, but a schema this build does not know.
final class ManifestIgnored extends ManifestCheck {
  ManifestIgnored(this.reason);
  final String reason;
}

/// The same version or an older one — which is how a replayed old manifest
/// fails to downgrade anyone.
final class ManifestNotNewer extends ManifestCheck {
  ManifestNotNewer(this.manifest);
  final UpdateManifest manifest;
}

final class ManifestNewer extends ManifestCheck {
  ManifestNewer(this.manifest);
  final UpdateManifest manifest;
}

/// The signature is checked before a single field is read (architecture.md
/// §2.14); only then parsed, the URL checked against the one allowed prefix,
/// and the version compared.
Future<ManifestCheck> checkManifest({
  required List<int> manifestBytes,
  required List<int> signatureFileBytes,
  required UpdateConfig config,
}) async {
  final signed = await verifyManifestSignature(
    manifestBytes: manifestBytes,
    signatureFileBytes: signatureFileBytes,
    publicKey: config.publicKey,
  );
  if (!signed) return ManifestRejected(UpdateErrorKind.signature, 'the update manifest signature does not verify');

  final UpdateManifest manifest;
  switch (parseUpdateManifest(manifestBytes)) {
    case ManifestOk(manifest: final parsed):
      manifest = parsed;
    case ManifestUnknownSchema(:final schema):
      return ManifestIgnored('unknown manifest schema $schema');
    case ManifestInvalid(:final reason):
      return ManifestRejected(UpdateErrorKind.manifest, 'the update manifest is invalid ($reason)');
  }

  if (!manifest.windowsX64.url.toString().startsWith(config.allowedAssetPrefix)) {
    return ManifestRejected(UpdateErrorKind.manifest, 'the installer URL is outside ${config.allowedAssetPrefix}');
  }
  final current = config.currentVersion;
  if (current == null || manifest.version <= current) return ManifestNotNewer(manifest);
  return ManifestNewer(manifest);
}

/// True iff [file] is exactly [size] bytes and hashes to [sha256] (lowercase
/// hex). Streams the file; hashes only when the size already matches.
Future<bool> verifyFile(File file, {required int size, required String sha256}) async {
  try {
    if (await file.length() != size) return false;
    final digest = await crypto.sha256.bind(file.openRead()).single;
    return digest.toString() == sha256;
  } on FileSystemException {
    return false;
  }
}
