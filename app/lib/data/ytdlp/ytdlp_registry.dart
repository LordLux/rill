import 'package:win32_registry/win32_registry.dart';

/// The installer's record of the yt-dlp consent checkbox
/// (`HKCU\Software\Rill\YtDlpConsent` = `"yes"` / `"no"`, `release/rill.iss`).
///
/// Read exactly once, to seed the app's own stored choice when it has none —
/// after that the in-app choice is the source of truth and this is never read
/// again (docs/todo.md 49). The installer removes the value on uninstall; a
/// silent update re-installing over an existing choice can rewrite it back to
/// the checkbox's default, which is harmless here precisely because nothing
/// re-reads it once the app has its own answer.
abstract interface class YtDlpRegistryConsent {
  /// `"yes"`, `"no"`, or `null` if the value is absent (a pre-49 install, or
  /// one where the key was never created).
  String? read();
}

class Win32YtDlpRegistryConsent implements YtDlpRegistryConsent {
  /// [subkeyPath] defaults to the installer's real location; a test points it
  /// at a throwaway subkey instead of touching `Software\Rill`, which may be a
  /// real install's own state on the machine running the test.
  const Win32YtDlpRegistryConsent({this.subkeyPath = r'Software\Rill'});

  final String subkeyPath;

  @override
  String? read() {
    try {
      final key = Registry.openPath(RegistryHive.currentUser, path: subkeyPath);
      try {
        return key.getStringValue('YtDlpConsent');
      } finally {
        key.close();
      }
    } on Object {
      // No key, no value, or a registry error — all read the same as "the
      // installer never recorded an answer".
      return null;
    }
  }
}
