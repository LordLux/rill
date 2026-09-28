import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_pg/dart_pg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_http.dart';
import 'package:rill/data/ytdlp/ytdlp_downloader.dart';
import 'package:rill/data/ytdlp/ytdlp_paths.dart';
import 'package:rill/data/ytdlp/ytdlp_registry.dart';
import 'package:rill/domain/ytdlp/ytdlp_state.dart';
import 'package:rill/ui/ytdlp_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeYtDlpHttp implements UpdateHttp {
  FakeYtDlpHttp({required this.sumsBytes, required this.signatureBytes, required this.exeBytes});
  List<int> sumsBytes;
  List<int> signatureBytes;
  List<int> exeBytes;
  bool throwNetwork = false;
  int exeFetches = 0;

  @override
  Future<Uint8List> getBytes(Uri url, {required int maxBytes}) async {
    if (throwNetwork) throw UpdateNetworkException('fake network error');
    if (url.path.endsWith('.sig')) return Uint8List.fromList(signatureBytes);
    return Uint8List.fromList(sumsBytes);
  }

  @override
  Future<Stream<List<int>>> openStream(Uri url) async {
    if (throwNetwork) throw UpdateNetworkException('fake network error');
    exeFetches++;
    return Stream.value(exeBytes);
  }
}

class FakeYtDlpRegistryConsent implements YtDlpRegistryConsent {
  FakeYtDlpRegistryConsent(this.value);
  String? value;
  @override
  String? read() => value;
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

void main() {
  final keyPair = OpenPGP.generateKey(['test <test@example.com>'], 'pass', type: KeyType.curve25519, signOnly: true);
  final publicKeyArmored = keyPair.publicKey.armor();

  Uint8List sign(List<int> sumsBytes) {
    final message = OpenPGP.createLiteralMessage(Uint8List.fromList(sumsBytes));
    return OpenPGP.signDetached(message, [keyPair]).packetList.encode();
  }

  FakeYtDlpHttp fakeFor(List<int> exeBytes) {
    final sumsText = utf8.encode('${crypto.sha256.convert(exeBytes)}  yt-dlp.exe\n');
    return FakeYtDlpHttp(sumsBytes: sumsText, signatureBytes: sign(sumsText), exeBytes: exeBytes);
  }

  late Directory home;
  late List<FakeTimer> timers;
  late List<String?> restarts;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('ytdlp_controller_test_');
    SharedPreferences.setMockInitialValues({});
    timers = [];
    restarts = [];
  });

  tearDown(() async {
    try {
      await home.delete(recursive: true);
    } on FileSystemException {
      // Not worth failing a test over.
    }
  });

  Future<(ProviderContainer, YtDlpController)> start({
    String? registryConsent,
    FakeYtDlpHttp? http,
    YtDlpResolution resolution = const YtDlpResolution(location: YtDlpLocation.missing),
  }) async {
    final client = http ?? (FakeYtDlpHttp(sumsBytes: [], signatureBytes: [], exeBytes: [])..throwNetwork = true);
    final container = ProviderContainer(
      overrides: [
        ytDlpRegistryProvider.overrideWithValue(FakeYtDlpRegistryConsent(registryConsent)),
        ytDlpResolutionProvider.overrideWithValue(resolution),
        ytDlpHttpProvider.overrideWithValue(client),
        ytDlpDownloaderProvider.overrideWithValue(YtDlpDownloader(http: client, publicKeyArmored: publicKeyArmored)),
        ytDlpTargetProvider.overrideWithValue(File('${home.path}\\yt-dlp.exe')),
        ytDlpVersionProbeProvider.overrideWithValue((path) async => '2026.01.01'),
        ytDlpTimerFactoryProvider.overrideWithValue((delay, callback) {
          final timer = FakeTimer(delay, callback);
          timers.add(timer);
          return timer;
        }),
        ytDlpRandomProvider.overrideWithValue(FixedRandom(0)),
        ytDlpClockProvider.overrideWithValue(() => DateTime.utc(2026, 9, 28)),
        ytDlpRestartSidecarProvider.overrideWithValue((path) async => restarts.add(path)),
      ],
    );
    addTearDown(container.dispose);
    container.read(ytDlpControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    return (container, container.read(ytDlpControllerProvider.notifier));
  }

  FakeTimer pending() => timers.lastWhere((t) => !t.cancelled);

  test('no registry answer and nothing installed: shown as info, nothing scheduled', () async {
    final (container, _) = await start();
    final state = container.read(ytDlpControllerProvider);
    expect(state.location, YtDlpLocation.missing);
    expect(state.choice, isNull);
    expect(state.severity, YtDlpRowSeverity.info);
    expect(timers, isEmpty);
  });

  test('registry says yes, seeds the choice once and starts checking', () async {
    final http = fakeFor(utf8.encode('binary'));
    final (container, _) = await start(registryConsent: 'yes', http: http);
    expect(container.read(ytDlpControllerProvider).choice, YtDlpChoice.download);
    expect(timers.single.delay, ytDlpFirstCheckDelay);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ytdlp_choice'), 'download');
  });

  test('registry says no, seeds declined: still shown as info, nothing scheduled', () async {
    final (container, _) = await start(registryConsent: 'no');
    final state = container.read(ytDlpControllerProvider);
    expect(state.choice, YtDlpChoice.declined);
    expect(state.severity, YtDlpRowSeverity.info, reason: 'declining stops auto-download, not the quiet row');
    expect(timers, isEmpty, reason: 'declined and nothing to maintain');
  });

  test('an existing stored choice is never re-seeded from the registry', () async {
    SharedPreferences.setMockInitialValues({'ytdlp_choice': 'declined'});
    final (container, _) = await start(registryConsent: 'yes');
    expect(container.read(ytDlpControllerProvider).choice, YtDlpChoice.declined);
  });

  test('the scheduled check downloads, installs, and restarts the sidecar', () async {
    final exeBytes = utf8.encode('a fake yt-dlp binary');
    final http = fakeFor(exeBytes);
    final (container, controller) = await start(registryConsent: 'yes', http: http);

    timers.single.callback();
    // The timer's own callback is fire-and-forget (`Timer` callbacks are
    // void), but `sync()` is idempotent-guarded: calling it again right after
    // returns the exact in-flight future the callback already started,
    // rather than counting `Future.delayed(Duration.zero)` ticks against a
    // chain of real awaits (two HTTP round trips, a file write, a version
    // probe, two preference writes, a restart call).
    await controller.sync();

    final state = container.read(ytDlpControllerProvider);
    expect(state.location, YtDlpLocation.appManaged);
    expect(state.severity, YtDlpRowSeverity.none);
    expect(restarts, hasLength(1));
    expect(restarts.single, isNotNull);
    expect(File(restarts.single!).readAsBytesSync(), exeBytes);
    expect(pending().delay, greaterThan(const Duration(days: 6)));
  });

  test('download() records the choice immediately, even if the fetch then fails', () async {
    final (container, controller) = await start();
    await controller.download();
    final state = container.read(ytDlpControllerProvider);
    expect(state.choice, YtDlpChoice.download);
    expect(state.severity, YtDlpRowSeverity.problem, reason: 'an actual attempt failed, not just an ordinary absence');
    expect(state.phase, isA<YtDlpPhaseError>());
  });

  test('decline() stops scheduling; the row stays as a quiet info entry', () async {
    final (container, controller) = await start(registryConsent: 'yes', http: fakeFor(utf8.encode('x')));
    expect(timers.single.cancelled, isFalse);

    await controller.decline();
    final state = container.read(ytDlpControllerProvider);
    expect(state.choice, YtDlpChoice.declined);
    expect(state.severity, YtDlpRowSeverity.info);
    expect(timers.single.cancelled, isTrue);
  });

  test('a PATH copy is never touched: no schedule, sync is a no-op, no restart', () async {
    final (container, controller) = await start(
      registryConsent: 'yes',
      resolution: const YtDlpResolution(location: YtDlpLocation.onPath, path: r'C:\somewhere\yt-dlp.exe'),
    );
    expect(timers, isEmpty, reason: 'a PATH copy needs no maintenance');
    expect(container.read(ytDlpControllerProvider).severity, YtDlpRowSeverity.none);

    await controller.sync(manual: true);
    expect(restarts, isEmpty);
  });

  test('jitter spans a week ± 6 h', () {
    expect(ytDlpNextCheckDelay(FixedRandom(0)), ytDlpCheckInterval - const Duration(hours: 6));
    expect(ytDlpNextCheckDelay(FixedRandom(21600)), ytDlpCheckInterval);
    expect(ytDlpNextCheckDelay(FixedRandom(43200)), ytDlpCheckInterval + const Duration(hours: 6));
  });

  test('failure backoff doubles from 30 min and caps at 12 h', () {
    expect(
      [for (var n = 1; n <= 7; n++) ytDlpFailureBackoff(n).inMinutes],
      [30, 60, 120, 240, 480, 720, 720],
    );
  });
}
