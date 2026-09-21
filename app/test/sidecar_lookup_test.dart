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

import 'dart:io';

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

  group('repoSidecarSrc — the stale-sidecar detector looks at the right source', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('rill-stale-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Directory make(String path) => Directory('${tmp.path}/$path')..createSync(recursive: true);

    test('finds the checkout it is run from', () {
      make('repo/sidecar/src');
      make('repo/.git');

      expect(RpcClient.repoSidecarSrc('${tmp.path}/repo')?.path,
          '${tmp.path}/repo/sidecar/src'.replaceAll('/', Platform.pathSeparator == r'\' ? '/' : '/'));
    });

    test('walks up to it from a build output inside the checkout', () {
      // The case the trap actually takes: a release build run from
      // `app/build/windows/x64/runner/Release/`, inside the repository.
      make('repo/sidecar/src');
      make('repo/.git');
      final release = make('repo/app/build/windows/x64/runner/Release');

      expect(RpcClient.repoSidecarSrc(release.path), isNotNull);
    });

    test('ignores a bundled sidecar/src with no checkout above it', () {
      // **The discrimination that makes this worth having.** A release bundle
      // carries its own `sidecar/src`, and it is exactly as stale as the binary
      // beside it — comparing the two would always agree and never warn, which
      // is how the trap hides. Only a real checkout counts.
      final bundle = make('bundle/sidecar/src');

      expect(RpcClient.repoSidecarSrc(bundle.parent.parent.path), isNull);
    });

    test('a shipped app with nothing above it finds nothing, and says nothing', () {
      expect(RpcClient.repoSidecarSrc(make('elsewhere').path), isNull);
    });
  });


  test('client.dart imports no Flutter, because a plain Dart VM runs it', () {
    // `test/orphan_test_helper.dart` imports `data/rpc/client.dart` and runs on
    // the plain Dart VM, which has no `dart:ui`. A single
    // `package:flutter/foundation.dart` import — added 2026-09-21 for
    // `kDebugMode`, removed the same day — made that helper fail to *compile*,
    // and the orphan test then failed with "Helper should print SIDECAR_PID"
    // behind two hundred lines of framework errors. Same shape as CLAUDE.md's
    // `animated_vector_gen` trap: a package re-exports `dart:ui` and drags the
    // framework into a host that has none.
    //
    // One line here instead of that. Use the `assert` trick for debug-mode
    // detection, not `kDebugMode`.
    final source = File('lib/data/rpc/client.dart').readAsStringSync();
    final flutterImports = RegExp(r"^import 'package:flutter/.*$", multiLine: true)
        .allMatches(source)
        .map((m) => m.group(0))
        .toList();

    expect(flutterImports, isEmpty,
        reason: 'client.dart runs on the plain Dart VM via orphan_test_helper.dart');
  });

}
