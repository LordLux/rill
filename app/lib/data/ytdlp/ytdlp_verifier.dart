import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_pg/dart_pg.dart';

/// Where yt-dlp's release assets live, and the key that signs them — resolved
/// once, here, the same shape as `UpdateConfig` for our own updater.
abstract final class YtDlpConfig {
  static const _base = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/';
  static final exeUrl = Uri.parse('${_base}yt-dlp.exe');
  static final sumsUrl = Uri.parse('${_base}SHA2-256SUMS');
  static final sumsSignatureUrl = Uri.parse('${_base}SHA2-256SUMS.sig');

  /// The exact name `SHA2-256SUMS` uses for the Windows x64 binary.
  static const assetName = 'yt-dlp.exe';

  /// Above every release seen so far (~18 MB) with generous headroom, so a
  /// stream that never stops is cut off rather than filling the disk.
  static const maxDownloadBytes = 150 * 1024 * 1024;

  /// `https://github.com/yt-dlp/yt-dlp/raw/master/public.key`, vendored rather
  /// than fetched at runtime — fetching it over the same channel it is meant
  /// to authenticate would defeat the point, the same reasoning as embedding
  /// our own updater's Ed25519 key rather than serving it from the feed.
  static const publicKeyArmored = '''
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGP78C4BEAD0rF9zjGPAt0thlt5C1ebzccAVX7Nb1v+eqQjk+WEZdTETVCg3
WAM5ngArlHdm/fZqzUgO+pAYrB60GKeg7ffUDf+S0XFKEZdeRLYeAaqqKhSibVal
DjvOBOztu3W607HLETQAqA7wTPuIt2WqmpL60NIcyr27LxqmgdN3mNvZ2iLO+bP0
nKR/C+PgE9H4ytywDa12zMx6PmZCnVOOOu6XZEFmdUxxdQ9fFDqd9LcBKY2LDOcS
Yo1saY0YWiZWHtzVoZu1kOzjnS5Fjq/yBHJLImDH7pNxHm7s/PnaurpmQFtDFruk
t+2lhDnpKUmGr/I/3IHqH/X+9nPoS4uiqQ5HpblB8BK+4WfpaiEg75LnvuOPfZIP
KYyXa/0A7QojMwgOrD88ozT+VCkKkkJ+ijXZ7gHNjmcBaUdKK7fDIEOYI63Lyc6Q
WkGQTigFffSUXWHDCO9aXNhP3ejqFWgGMtCUsrbkcJkWuWY7q5ARy/05HbSM3K4D
U9eqtnxmiV1WQ8nXuI9JgJQRvh5PTkny5LtxqzcmqvWO9TjHBbrs14BPEO9fcXxK
L/CFBbzXDSvvAgArdqqlMoncQ/yicTlfL6qzJ8EKFiqW14QMTdAn6SuuZTodXCTi
InwoT7WjjuFPKKdvfH1GP4bnqdzTnzLxCSDIEtfyfPsIX+9GI7Jkk/zZjQARAQAB
tDdTaW1vbiBTYXdpY2tpICh5dC1kbHAgc2lnbmluZyBrZXkpIDxjb250YWN0QGdy
dWI0ay54eXo+iQJOBBMBCgA4FiEErAy75oSNaoc0ZK9OV89lkztadYEFAmP78C4C
GwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQV89lkztadYEVqQ//cW7TxhXg
7Xbh2EZQzXml0egn6j8QaV9KzGragMiShrlvTO2zXfLXqyizrFP4AspgjSn/4NrI
8mluom+Yi+qr7DXT4BjQqIM9y3AjwZPdywe912Lxcw52NNoPZCm24I9T7ySc8lmR
FQvZC0w4H/VTNj/2lgJ1dwMflpwvNRiWa5YzcFGlCUeDIPskLx9++AJE+xwU3LYm
jQQsPBqpHHiTBEJzMLl+rfd9Fg4N+QNzpFkTDW3EPerLuvJniSBBwZthqxeAtw4M
UiAXh6JvCc2hJkKCoygRfM281MeolvmsGNyQm+axlB0vyldiPP6BnaRgZlx+l6MU
cPqgHblb7RW5j9lfr6OYL7SceBIHNv0CFrt1OnkGo/tVMwcs8LH3Ae4a7UJlIceL
V54aRxSsZU7w4iX+PB79BWkEsQzwKrUuJVOeL4UDwWajp75OFaUqbS/slDDVXvK5
OIeuth3mA/adjdvgjPxhRQjA3l69rRWIJDrqBSHldmRsnX6cvXTDy8wSXZgy51lP
m4IVLHnCy9m4SaGGoAsfTZS0cC9FgjUIyTyrq9M67wOMpUxnuB0aRZgJE1DsI23E
qdvcSNVlO+39xM/KPWUEh6b83wMn88QeW+DCVGWACQq5N3YdPnAJa50617fGbY6I
gXIoRHXkDqe23PZ/jURYCv0sjVtjPoVC+bg=
=bJkn
-----END PGP PUBLIC KEY BLOCK-----''';
}

/// `SHA2-256SUMS` is a plain sha256sum listing: `<64 hex> [*| ]<name>` per
/// line. Returns filename → lowercase hex digest.
Map<String, String> parseSha256Sums(String text) {
  final pattern = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$');
  final result = <String, String>{};
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    result[match.group(2)!] = match.group(1)!.toLowerCase();
  }
  return result;
}

/// `SHA2-256SUMS.sig` is a raw binary OpenPGP detached signature — the
/// `gpg --verify SHA2-256SUMS.sig SHA2-256SUMS` kind, not an ASCII-armored
/// `--clearsign` message — so this treats [sumsBytes] as opaque binary
/// literal data, exactly what `gpg` hashes for a binary-type signature.
/// `Signature.fromArmored` only reads the armored kind, hence decoding the
/// packet list directly rather than going through `OpenPGP.readSignature`.
///
/// Any failure — a bad signature, an unparseable key, corrupt packets — is
/// `false`. Never throws.
///
/// `SignaturePacketInterface` (the type the package's own `Signature.verify`
/// takes) is never exported from `package:dart_pg/dart_pg.dart` — only the
/// concrete `SignaturePacket` is, via `packet/base_packet.dart`'s `export
/// 'signature.dart';` — so this calls the packet's own `verify` directly
/// rather than going through the unreachable message-level wrapper.
bool verifySha256SumsSignature({
  required Uint8List sumsBytes,
  required Uint8List signatureBytes,
  String publicKeyArmored = YtDlpConfig.publicKeyArmored,
}) {
  try {
    final publicKey = OpenPGP.readPublicKey(publicKeyArmored);
    final keyPacket = publicKey.publicKey.keyPacket;
    final signaturePackets = PacketList.decode(signatureBytes).whereType<SignaturePacket>();
    if (signaturePackets.isEmpty) return false;
    for (final packet in signaturePackets) {
      try {
        if (packet.verify(keyPacket, sumsBytes)) return true;
      } on Object {
        // Wrong issuer, expired, or a bad digest — try the next packet rather
        // than letting one throw sink every other signature on the message.
        continue;
      }
    }
    return false;
  } on Object {
    return false;
  }
}

/// True iff [file] is exactly [size] bytes (when given) and hashes to
/// [sha256] (lowercase hex). Mirrors `update_verifier.dart`'s `verifyFile`;
/// duplicated rather than shared because yt-dlp's checksum listing carries no
/// size, so the check here is sometimes hash-only.
Future<bool> verifyYtDlpFile(File file, {required String sha256, int? size}) async {
  try {
    if (size != null && await file.length() != size) return false;
    final digest = await crypto.sha256.bind(file.openRead()).single;
    return digest.toString() == sha256;
  } on FileSystemException {
    return false;
  }
}

/// The installed file's own hash, or `null` if it does not exist or cannot be
/// read — used to decide whether a refresh actually needs to download
/// anything (`ytdlp_controller.dart`).
Future<String?> sha256OfFile(File file) async {
  try {
    if (!await file.exists()) return null;
    final digest = await crypto.sha256.bind(file.openRead()).single;
    return digest.toString();
  } on FileSystemException {
    return null;
  }
}
