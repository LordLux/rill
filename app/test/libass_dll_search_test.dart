/// `findLibassBundleDir` — the pure half of `openLibass()`'s fallback
/// (`lib/ui/player/libass/dll_search.dart`). The DLL-loading half needs a real
/// Windows process to mean anything; this is the part that can be driven with
/// injected values, the same split `RpcClient.findSidecarRoot`'s own test uses.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/player/libass/dll_search.dart';

void main() {
  group('findLibassBundleDir', () {
    test('finds it directly under cwd — the flutter test case', () {
      final found = findLibassBundleDir(
        cwd: r'C:\project\app',
        hasBundleDir: (path) => path == r'C:\project\app/windows/libass_bundle',
      );
      expect(found, r'C:\project\app/windows/libass_bundle');
    });

    test('walks up when invoked from a subdirectory of the package root', () {
      final found = findLibassBundleDir(
        cwd: r'C:\project\app\test',
        hasBundleDir: (path) => path == r'C:\project\app/windows/libass_bundle',
      );
      expect(found, r'C:\project\app/windows/libass_bundle');
    });

    test('gives up after 8 levels rather than walking to the drive root forever', () {
      var calls = 0;
      final found = findLibassBundleDir(
        cwd: r'C:\a\b\c\d\e\f\g\h\i\j',
        hasBundleDir: (_) {
          calls++;
          return false;
        },
      );
      expect(found, isNull);
      expect(calls, lessThanOrEqualTo(8));
    });

    test('returns null rather than throwing when nothing matches', () {
      final found = findLibassBundleDir(cwd: r'C:\nowhere', hasBundleDir: (_) => false);
      expect(found, isNull);
    });
  });
}
