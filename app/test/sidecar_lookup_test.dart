/// Where the app looks for the sidecar.
///
/// The bug these pin: a copied build directory could not start. The lookup
/// walked up from `Directory.current` only, so it found the sidecar in a dev
/// checkout and nowhere else — and "nowhere else" includes every machine the
/// app might be handed to. It surfaced as `Failed to start sidecar process`,
/// which reads like the sidecar crashed rather than like it was never found.
///
/// Filesystem-free on purpose: the whole point is the layouts this machine does
/// *not* have.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';

/// A fake tree: the set of directories that contain a `sidecar/` child.
bool Function(String) treeWith(Set<String> roots) => roots.contains;

void main() {
  group('findSidecarRoot', () {
    test('prefers the executable directory — a copied build must just run', () {
      final root = RpcClient.findSidecarRoot(
        exeDir: r'D:\Rill',
        cwd: r'C:\Users\someone\Desktop',
        hasSidecarDir: treeWith({r'D:\Rill'}),
      );
      expect(root, r'D:\Rill');
    });

    test('falls back to walking up from the working directory, for flutter run', () {
      // `flutter run` starts in `app/`; the sidecar lives at the repo root.
      final root = RpcClient.findSidecarRoot(
        exeDir: r'C:\Projects\NativeYouTube\app\build\windows\x64\runner\Debug',
        cwd: r'C:\Projects\NativeYouTube\app',
        hasSidecarDir: treeWith({r'C:\Projects\NativeYouTube'}),
      );
      expect(root, r'C:\Projects\NativeYouTube');
    });

    test('the executable wins when both layouts exist', () {
      // A copied build inside a checkout must use its own bundled sidecar, not
      // whichever one happens to be up the tree.
      final root = RpcClient.findSidecarRoot(
        exeDir: r'C:\Projects\NativeYouTube\app\build\windows\x64\runner\Release',
        cwd: r'C:\Projects\NativeYouTube\app',
        hasSidecarDir: treeWith({
          r'C:\Projects\NativeYouTube\app\build\windows\x64\runner\Release',
          r'C:\Projects\NativeYouTube',
        }),
      );
      expect(root, r'C:\Projects\NativeYouTube\app\build\windows\x64\runner\Release');
    });

    test('answers null when there is no sidecar anywhere', () {
      // Null rather than a guess. The caller still has to do something, but a
      // wrong root is what turned "not packaged" into "process failed to start".
      final root = RpcClient.findSidecarRoot(
        exeDir: r'D:\Rill',
        cwd: r'C:\Users\someone\Desktop',
        hasSidecarDir: treeWith(const {}),
      );
      expect(root, isNull);
    });

    test('the upward walk is bounded and terminates at the drive root', () {
      var probed = 0;
      final root = RpcClient.findSidecarRoot(
        exeDir: r'D:\Rill',
        cwd: r'C:\a\b\c\d\e\f\g\h\i\j',
        hasSidecarDir: (path) {
          probed++;
          return false;
        },
      );
      expect(root, isNull);
      // One for the exe plus at most eight rungs — an unbounded walk on a deep
      // path is a stat storm at every launch.
      expect(probed, lessThanOrEqualTo(9));
    });
  });
}
