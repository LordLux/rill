import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_config.dart';
import 'package:rill/data/update/update_downloader.dart';
import 'package:rill/data/update/update_http.dart';
import 'package:rill/domain/update/update_state.dart';
import 'package:rill/ui/update_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves one signed manifest and one installer from memory.
class FakeUpdateHttp implements UpdateHttp {
  FakeUpdateHttp({required this.manifestBytes, required this.signatureBytes, required this.installerBytes});

  List<int> manifestBytes;
  List<int> signatureBytes;
  List<int> installerBytes;
  bool throwNetwork = false;
  int manifestGets = 0;
  int downloads = 0;

  @override
  Future<Uint8List> getBytes(Uri url, {required int maxBytes}) async {
    if (throwNetwork) throw UpdateNetworkException('fake network error');
    if (url.path.endsWith('.sig')) return Uint8List.fromList(signatureBytes);
    manifestGets++;
    return Uint8List.fromList(manifestBytes);
  }

  @override
  Future<Stream<List<int>>> openStream(Uri url) async {
    if (throwNetwork) throw UpdateNetworkException('fake network error');
    downloads++;
    return Stream.value(installerBytes);
  }
}

class FakeTimer implements Timer {
  FakeTimer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

class FixedRandom implements Random {
  FixedRandom(this.value);
  int value;
  @override
  int nextInt(int max) => value;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

class FakeLauncher {
  int calls = 0;
  File? file;
  List<String>? args;
  bool fail = false;

  Future<int> call(File installer, List<String> arguments, Future<bool> Function(File) verify) async {
    calls++;
    file = installer;
    args = arguments;
    if (fail) throw Exception('launcher failed');
    return 1234;
  }
}

void main() {
  late Directory tempDir;
  late SimpleKeyPair keyPair;
  late String pubBase64;

  setUpAll(() async {
    keyPair = await DartEd25519().newKeyPair();
    pubBase64 = base64Encode((await keyPair.extractPublicKey()).bytes);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rill_updater_test');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // A temp directory is not worth failing a test over.
    }
  });

  UpdateConfig config(String version) => UpdateConfig.resolve(
    releaseMode: false,
    version: version,
    keyOverride: pubBase64,
    prefixOverride: 'http://127.0.0.1:8765/',
    feedOverride: 'http://127.0.0.1:8765/update.json',
  );

  /// A signed feed offering [version]; the manifest's hash is of [hashed], the
  /// server sends [served] (defaults to the same bytes).
  Future<FakeUpdateHttp> feed(String version, {List<int>? hashed, List<int>? served, String? minimumVersion, bool badSignature = false}) async {
    final bytes = hashed ?? List.filled(100, 42);
    final manifest = utf8.encode(jsonEncode({
      'schema': 1,
      'version': version,
      'tag': 'v$version',
      'notes': ['A change'],
      'minimumVersion': minimumVersion,
      'assets': {
        'windows-x64': {
          'name': 'Rill-Setup-x64.exe',
          'url': 'http://127.0.0.1:8765/v$version/Rill-Setup-x64.exe',
          'sha256': crypto.sha256.convert(bytes).toString(),
          'size': bytes.length,
        },
      },
    }));
    final signature = List<int>.of((await DartEd25519().sign(manifest, keyPair: keyPair)).bytes);
    if (badSignature) signature[0] ^= 1;
    return FakeUpdateHttp(
      manifestBytes: manifest,
      signatureBytes: utf8.encode('${base64Encode(signature)}\n'),
      installerBytes: served ?? bytes,
    );
  }

  /// Every test goes through here, so none can reach the real network, the
  /// real `%LOCALAPPDATA%\rill\updates`, a real timer, or a real installer.
  late List<FakeTimer> timers;
  late FakeLauncher launcher;
  late int exits;

  Future<(ProviderContainer, UpdateController)> start({
    required UpdateConfig config,
    UpdateHttp? http,
    Random? random,
    DateTime Function()? clock,
  }) async {
    timers = [];
    launcher = FakeLauncher();
    exits = 0;
    final client = http ?? (FakeUpdateHttp(manifestBytes: [], signatureBytes: [], installerBytes: [])..throwNetwork = true);
    final container = ProviderContainer(
      overrides: [
        updateConfigProvider.overrideWithValue(config),
        updateHttpProvider.overrideWithValue(client),
        updateDownloaderProvider.overrideWithValue(UpdateDownloader(http: client, root: tempDir)),
        updateTimerFactoryProvider.overrideWithValue((delay, callback) {
          final timer = FakeTimer(delay, callback);
          timers.add(timer);
          return timer;
        }),
        updateRandomProvider.overrideWithValue(random ?? FixedRandom(600)),
        updateClockProvider.overrideWithValue(clock ?? () => DateTime.utc(2026, 9, 27)),
        updateInstallerLauncherProvider.overrideWithValue(launcher.call),
        updateExitAppProvider.overrideWithValue(() async => exits++),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateControllerProvider.notifier);
    // Let the preferences load, which is what schedules the first check.
    await Future<void>.delayed(Duration.zero);
    return (container, controller);
  }

  FakeTimer pending() => timers.lastWhere((t) => !t.cancelled);

  test('the first automatic check is 30 s after launch, the next 12 h ± 10 min after a success', () async {
    final http = await feed('0.1.0');
    final (container, _) = await start(config: config('0.1.0'), http: http);
    expect(timers.single.delay, const Duration(seconds: 30));

    timers.single.callback();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(updateControllerProvider).phase, isA<UpdateUpToDate>());
    expect(pending().delay, const Duration(hours: 12));
    expect(timers.where((t) => !t.cancelled), hasLength(1), reason: 'one pending automatic check at a time');
  });

  test('jitter spans exactly 12 h ± 10 min', () {
    expect(nextCheckDelay(FixedRandom(0)), const Duration(hours: 12) - const Duration(minutes: 10));
    expect(nextCheckDelay(FixedRandom(600)), const Duration(hours: 12));
    expect(nextCheckDelay(FixedRandom(1200)), const Duration(hours: 12) + const Duration(minutes: 10));
  });

  test('failure backoff doubles from 30 min and caps at 12 h', () {
    expect(
      [for (var n = 1; n <= 7; n++) failureBackoff(n).inMinutes],
      [30, 60, 120, 240, 480, 720, 720],
    );
  });

  test('two checks at once fetch the manifest once', () async {
    final http = await feed('0.1.0');
    final (_, controller) = await start(config: config('0.1.0'), http: http);
    final first = controller.checkNow();
    final second = controller.checkNow();
    expect(identical(first, second), isTrue);
    await first;
    expect(http.manifestGets, 1);
  });

  test('a newer version downloads by default and ends ready', () async {
    final http = await feed('0.2.0');
    final (container, controller) = await start(config: config('0.1.0'), http: http);
    await controller.checkNow();
    final phase = container.read(updateControllerProvider).phase;
    expect(phase, isA<UpdateReady>());
    expect(File((phase as UpdateReady).installerPath).readAsBytesSync(), List.filled(100, 42));
  });

  test('with automatic download off a newer version stays available', () async {
    SharedPreferences.setMockInitialValues({'update_auto': false});
    final http = await feed('0.2.0');
    final (container, controller) = await start(config: config('0.1.0'), http: http);
    expect(timers, isEmpty, reason: 'automatic checking is off too');
    await controller.checkNow();
    expect(container.read(updateControllerProvider).phase, isA<UpdateAvailable>());
    expect(http.downloads, 0);
  });

  test('a manual re-check keeps an update that is already ready, even with automatic download off', () async {
    final http = await feed('0.2.0');
    final (container, controller) = await start(config: config('0.1.0'), http: http);
    await controller.checkNow();
    expect(container.read(updateControllerProvider).phase, isA<UpdateReady>());
    await controller.setAutoUpdate(false);
    await controller.checkNow();
    expect(container.read(updateControllerProvider).phase, isA<UpdateReady>());
    expect(http.downloads, 1);
  });

  test('the same version and an older one are both up to date, and nothing downloads', () async {
    for (final offered in ['0.1.0', '0.0.9']) {
      final http = await feed(offered);
      final (container, controller) = await start(config: config('0.1.0'), http: http);
      await controller.checkNow();
      expect(container.read(updateControllerProvider).phase, isA<UpdateUpToDate>(), reason: offered);
      expect(http.downloads, 0, reason: offered);
    }
  });

  test('a bad signature: silent and backed off when automatic, shown when manual', () async {
    final http = await feed('0.2.0', badSignature: true);
    final (container, controller) = await start(config: config('0.1.0'), http: http);

    await controller.checkNow(origin: UpdateCheckOrigin.automatic);
    expect(container.read(updateControllerProvider).phase, isA<UpdateIdle>());
    expect(pending().delay, const Duration(minutes: 30));
    expect(http.downloads, 0);

    await controller.checkNow();
    final phase = container.read(updateControllerProvider).phase;
    expect(phase, isA<UpdateError>());
    expect((phase as UpdateError).kind, UpdateErrorKind.signature);
    expect(pending().delay, const Duration(hours: 1), reason: 'the second failure in a row');
  });

  test('a network failure is silent when automatic and shown when manual', () async {
    final (container, controller) = await start(config: config('0.1.0'));
    await controller.checkNow(origin: UpdateCheckOrigin.automatic);
    expect(container.read(updateControllerProvider).phase, isA<UpdateIdle>());
    await controller.checkNow();
    final phase = container.read(updateControllerProvider).phase;
    expect((phase as UpdateError).kind, UpdateErrorKind.network);
  });

  test('a hash mismatch leaves no file, and a repeat does not reset the backoff', () async {
    final http = await feed('0.2.0', hashed: List.filled(10, 1), served: List.filled(10, 2));
    final (container, controller) = await start(config: config('0.1.0'), http: http);

    await controller.checkNow();
    final phase = container.read(updateControllerProvider).phase;
    expect((phase as UpdateError).kind, UpdateErrorKind.integrity);
    expect(tempDir.listSync(recursive: true).whereType<File>(), isEmpty);
    expect(pending().delay, const Duration(minutes: 30));

    // The next automatic check sees the same release, and the same bad file:
    // the wait grows instead of starting over.
    await controller.checkNow(origin: UpdateCheckOrigin.automatic);
    expect(container.read(updateControllerProvider).phase, isA<UpdateAvailable>());
    expect(pending().delay, const Duration(hours: 1));
  });

  test('last-checked and the dismissed version survive a restart', () async {
    final http = await feed('0.2.0');
    final (container, controller) = await start(config: config('0.1.0'), http: http, clock: () => DateTime.utc(2026, 9, 27, 8));
    await controller.checkNow();
    expect(container.read(updateControllerProvider).showsNotice, isTrue);
    await controller.dismiss();
    expect(container.read(updateControllerProvider).showsNotice, isFalse);

    final (restarted, _) = await start(config: config('0.1.0'), http: http);
    final state = restarted.read(updateControllerProvider);
    expect(state.lastChecked, DateTime.utc(2026, 9, 27, 8).toLocal());
    expect(state.dismissedVersion, '0.2.0');
  });

  test('a mandatory update cannot be dismissed', () async {
    final http = await feed('0.2.0', minimumVersion: '0.2.0');
    final (container, controller) = await start(config: config('0.1.0'), http: http);
    await controller.checkNow();
    expect(container.read(updateControllerProvider).isMandatory, isTrue);
    await controller.dismiss();
    final state = container.read(updateControllerProvider);
    expect(state.dismissedVersion, isNull);
    expect(state.showsNotice, isTrue);
  });

  test('install starts the verified installer with the updater flags, then exits', () async {
    final http = await feed('0.2.0');
    final (container, controller) = await start(config: config('0.1.0'), http: http);

    await controller.install();
    expect(launcher.calls, 0, reason: 'nothing is ready yet');

    await controller.checkNow();
    final ready = container.read(updateControllerProvider).phase as UpdateReady;
    await controller.install();
    expect(launcher.calls, 1);
    expect(launcher.file!.path, ready.installerPath);
    expect(launcher.args, [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
      '/RELAUNCH=1',
      '/LOG="${tempDir.path}\\install-0.2.0.log"',
    ]);
    expect(exits, 1);
  });

  test('a failed launch is an install error and the app does not exit', () async {
    final http = await feed('0.2.0');
    final (container, controller) = await start(config: config('0.1.0'), http: http);
    await controller.checkNow();
    launcher.fail = true;
    await controller.install();
    final phase = container.read(updateControllerProvider).phase;
    expect((phase as UpdateError).kind, UpdateErrorKind.install);
    expect(exits, 0);
  });

  test('a dev build schedules nothing and checks nothing', () async {
    final http = await feed('0.2.0');
    final (container, controller) = await start(config: config(''), http: http);
    expect(timers, isEmpty);
    await controller.checkNow();
    expect(container.read(updateControllerProvider).phase, isA<UpdateIdle>());
    expect(http.manifestGets, 0);
  });

  test('turning automatic updates off cancels the pending check', () async {
    final (_, controller) = await start(config: config('0.1.0'));
    expect(timers.single.cancelled, isFalse);
    await controller.setAutoUpdate(false);
    expect(timers.single.cancelled, isTrue);
  });
}
