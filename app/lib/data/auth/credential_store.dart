import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the cookie lives between launches.
///
/// Task 22 §5: **the OS credential store**, not `SharedPreferences`, not a
/// file, not the repo. `flutter_secure_storage` is what the task names, and it
/// is what this uses — but what that package actually does on Windows is worth
/// stating, because it is not quite what §5 says it is.
///
/// **It is not DPAPI, as of `flutter_secure_storage_windows` 3.1.2.** The
/// plugin generates a 16-byte AES key, stores *that* in Windows Credential
/// Manager (`CredWriteW`, `CRED_TYPE_GENERIC`), and writes the values
/// AES-GCM-encrypted into a file under the app's data directory. So the secret
/// that protects the cookie is in the OS credential store and the ciphertext is
/// beside the app. The practical difference from DPAPI is small — both are
/// user-scoped and neither survives being copied to another machine — but the
/// difference between "the cookie is in Credential Manager" and "a key that
/// decrypts it is" is the kind of thing worth knowing before trusting it.
///
/// It also matters for a reason that is not about security: Credential
/// Manager's blob limit is 2560 bytes and a YouTube cookie header is commonly
/// larger than that. The older, straight-to-`CredWrite` versions of this plugin
/// would have failed on a real cookie. This one does not, because the thing it
/// writes there is a fixed 16 bytes.
abstract class CredentialStore {
  /// The stored cookie, or null when there is none.
  Future<String?> read();

  /// Replace the stored cookie.
  Future<void> write(String cookie);

  /// Remove it. Must leave the store genuinely empty — Task 22's mutation
  /// check is that a sign-out is asserted on *this* being empty afterwards,
  /// not on a flag having flipped.
  Future<void> clear();
}

/// The real one.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              // Windows ignores these; they are here so the same store behaves
              // on a dev machine that is not Windows rather than silently
              // choosing a weaker backend.
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  /// One key. Multiple accounts are explicitly out of scope (Task 22).
  static const String _key = 'rill.youtube.cookie';

  @override
  Future<String?> read() async {
    try {
      final value = await _storage.read(key: _key);
      if (value == null || value.trim().isEmpty) return null;
      return value.trim();
    } on Object catch (error) {
      // A store that cannot be read is anonymous, not a crash at startup. The
      // key lives in Credential Manager and can be absent for reasons that
      // have nothing to do with this app — a restored profile, a policy, a
      // roaming account. Never log `error` with a value in scope; this one
      // carries none.
      stderr.writeln('rill auth: credential store unreadable ($error) — starting anonymous');
      return null;
    }
  }

  @override
  Future<void> write(String cookie) => _storage.write(key: _key, value: cookie);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// For tests. Holds the value in memory and nowhere else.
class InMemoryCredentialStore implements CredentialStore {
  String? value;

  /// Whether anything is stored — what a sign-out test asserts on.
  bool get isEmpty => value == null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String cookie) async => value = cookie;

  @override
  Future<void> clear() async => value = null;
}

final credentialStoreProvider = Provider<CredentialStore>((ref) => SecureCredentialStore());
