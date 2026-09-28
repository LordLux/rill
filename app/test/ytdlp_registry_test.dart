import 'package:flutter_test/flutter_test.dart';
import 'package:win32_registry/win32_registry.dart';
import 'package:rill/data/ytdlp/ytdlp_registry.dart';

void main() {
  // A throwaway HKCU subkey, never the installer's real
  // `Software\Rill` — that may be a real install's own state on whatever
  // machine runs this test. HKCU needs no elevation, so this runs on CI the
  // same as anywhere else.
  const testPath = r'Software\RillTest_ytdlp_registry';
  const reader = Win32YtDlpRegistryConsent(subkeyPath: testPath);

  tearDown(() {
    try {
      Registry.openPath(RegistryHive.currentUser).deleteKey(testPath, recursive: true);
    } on Object {
      // Nothing to clean up.
    }
  });

  test('reads a value the installer would have written', () {
    final key = Registry.openPath(RegistryHive.currentUser, desiredAccessRights: AccessRights.allAccess).createKey(testPath);
    key.createValue(const StringValue('YtDlpConsent', 'yes'));
    key.close();

    expect(reader.read(), 'yes');
  });

  test('a declined install reads "no"', () {
    final key = Registry.openPath(RegistryHive.currentUser, desiredAccessRights: AccessRights.allAccess).createKey(testPath);
    key.createValue(const StringValue('YtDlpConsent', 'no'));
    key.close();

    expect(reader.read(), 'no');
  });

  test('a missing key reads as null, not a thrown error', () {
    expect(reader.read(), isNull);
  });
}
