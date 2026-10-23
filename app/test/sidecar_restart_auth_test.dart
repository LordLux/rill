/// A restarted sidecar is anonymous, so the app signs it in again — `todo.md` 96.
///
/// Reported 2026-10-21 on 0.10.2: the account showed, the feed worked, and like
/// and subscribe failed. The log had the cause: thirty seconds after launch the
/// yt-dlp check installed a newer copy and restarted the sidecar, and the new
/// process came up `cookie=no … auth state=anonymous` while the app's own state
/// still said `authenticated`. Nothing re-sent the cookie.
///
/// Against the real client and the fake sidecar, which is a new process on every
/// start and keeps the cookies it was given (`test.authLog`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/auth/credential_store.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/ytdlp_controller.dart' show ytDlpSidecarNeedsRestart;

const _cookie = 'SAPISID=abc; SID=def';

Future<Map<Object?, Object?>> _authLog() async =>
    await RpcClient.instance.call('test.authLog', {}) as Map<Object?, Object?>;

/// Real time, until [done] says so.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDown(() => RpcClient.instance.killForTestAndWait());

  group('the after-restart hook', () {
    test('is not called by the first start, and is called once by a restart', () async {
      var calls = 0;
      RpcClient.instance.onRestarted = () async => calls++;

      await RpcClient.instance.call('test.echo', {'msg': 'up'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 0, reason: 'a first start is not a restart');

      await RpcClient.instance.restart();
      await _until(() => calls > 0);
      expect(calls, 1);

      await RpcClient.instance.call('test.echo', {'msg': 'still up'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 1, reason: 'one restart, one call');
    });

    test('a crash, and a call made while the client waits to restart, still fires it once', () async {
      // The supervised path: the process dies, the client schedules a restart after a backoff,
      // and a call that arrives in that window starts the new process itself. The hook is for
      // that restart as much as for the timer's.
      var calls = 0;
      RpcClient.instance.onRestarted = () async => calls++;
      await RpcClient.instance.call('test.echo', {'msg': 'up'});

      // The crash answers nothing, so the call is failed by the exit (`UPSTREAM_ERROR`).
      await expectLater(RpcClient.instance.call('test.crash', {}), throwsA(isA<RpcException>()));
      expect(RpcClient.instance.pendingCallCount, 0);

      // During the backoff, before its timer has fired.
      expect(await RpcClient.instance.call('test.echo', {'msg': 'after the crash'}), 'after the crash');
      await _until(() => calls > 0);
      // Past the backoff, so the timer's own start has had its turn too.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(calls, 1, reason: 'one process died, the hook ran once, not never and not twice');
    });

    test('a call that is waiting for the sidecar to start is counted as pending', () async {
      await RpcClient.instance.killForTestAndWait();
      RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];

      final call = RpcClient.instance.call('test.echo', {'msg': 'first'});
      expect(RpcClient.instance.pendingCallCount, 1, reason: 'not yet written to a sidecar that is still starting');
      expect(await call, 'first');
      expect(RpcClient.instance.pendingCallCount, 0);
    });

    test('an error in it is not an error in start', () async {
      RpcClient.instance.onRestarted = () async => throw StateError('hook failed');
      await RpcClient.instance.restart();
      expect(await RpcClient.instance.call('test.echo', {'msg': 'fine'}), 'fine');
    });
  });

  test('a restarted sidecar is given the stored cookie again, and the app stays signed in', () async {
    final store = InMemoryCredentialStore()..value = _cookie;
    final container = ProviderContainer(overrides: [credentialStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    restoreAuthWhenSidecarRestarts(container);

    await container.read(authProvider.notifier).restore();
    expect(container.read(authProvider).status, AuthStatus.authenticated);
    expect((await _authLog())['cookies'], [_cookie]);

    await RpcClient.instance.restart();
    // The new process knows nothing until it is told; the hook does that.
    final cookies = <Object?>[];
    for (var i = 0; i < 100 && cookies.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cookies.addAll((await _authLog())['cookies'] as List);
    }

    expect(cookies, [_cookie], reason: 'the new sidecar was signed in with the stored cookie');
    expect((await _authLog())['state'], 'authenticated');
    expect(container.read(authProvider).status, AuthStatus.authenticated);
  });

  test('a signed-out app is not signed in again by a restart', () async {
    final store = InMemoryCredentialStore();
    final container = ProviderContainer(overrides: [credentialStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    restoreAuthWhenSidecarRestarts(container);

    await container.read(authProvider.notifier).restore();
    await RpcClient.instance.restart();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect((await _authLog())['cookies'], isEmpty, reason: 'nothing stored, nothing sent');
  });

  group('yt-dlp restarts the sidecar only when the path it was started with changes', () {
    test('a first download restarts it, an update in place does not', () {
      expect(ytDlpSidecarNeedsRestart({}, {'YT_DLP_PATH': r'C:\x\yt-dlp.exe'}), isTrue, reason: 'none → a path');
      expect(
        ytDlpSidecarNeedsRestart({'YT_DLP_PATH': r'C:\x\yt-dlp.exe'}, {'YT_DLP_PATH': r'C:\x\yt-dlp.exe'}),
        isFalse,
        reason: 'the same file replaced: the sidecar runs it by path',
      );
      expect(ytDlpSidecarNeedsRestart({'YT_DLP_PATH': r'C:\x\yt-dlp.exe'}, {}), isTrue, reason: 'a path → none');
    });
  });
}
