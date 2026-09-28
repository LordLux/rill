import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/rpc/client.dart';
import '../data/ytdlp/ytdlp_downloader.dart';
import '../data/ytdlp/ytdlp_paths.dart';
import '../data/ytdlp/ytdlp_registry.dart';
import '../data/ytdlp/ytdlp_verifier.dart';
import '../data/update/update_http.dart';
import '../domain/ytdlp/ytdlp_state.dart';

final ytDlpRegistryProvider = Provider<YtDlpRegistryConsent>((ref) => const Win32YtDlpRegistryConsent());

/// Where a working yt-dlp comes from, right now — a `Provider` (rather than
/// calling `resolveYtDlp()` inline) purely so a test can fix it at
/// [YtDlpLocation.onPath] without a real PATH entry, the one case this
/// controller has to treat specially: never touched, never scheduled.
final ytDlpResolutionProvider = Provider<YtDlpResolution>((ref) => resolveYtDlp());
final ytDlpHttpProvider = Provider<UpdateHttp>((ref) => IoUpdateHttp());
final ytDlpDownloaderProvider = Provider<YtDlpDownloader>((ref) => YtDlpDownloader(http: ref.watch(ytDlpHttpProvider)));
final ytDlpClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final ytDlpRandomProvider = Provider<Random>((ref) => Random());

/// Where a freshly downloaded copy is installed — a `Provider` so a test
/// points it at a temp file instead of the real `%LOCALAPPDATA%\rill\bin\`.
final ytDlpTargetProvider = Provider<File>((ref) => appManagedYtDlp());

/// `yt-dlp --version` on the just-installed file — a `Provider` so a test
/// never has to actually spawn the OS on fake binary content (which, on
/// Windows, risks a "this app can't run on your PC" dialog rather than a
/// clean failure).
final ytDlpVersionProbeProvider = Provider<Future<String?> Function(String path)>((ref) => ytDlpVersion);

typedef YtDlpTimerFactory = Timer Function(Duration delay, void Function() callback);
final ytDlpTimerFactoryProvider = Provider<YtDlpTimerFactory>((ref) => Timer.new);

/// Restarts the sidecar so a freshly written `YT_DLP_PATH` takes effect
/// (architecture.md "yt-dlp"). A `Provider` rather than calling
/// `RpcClient.instance` directly, so a test can swap in a no-op.
final ytDlpRestartSidecarProvider = Provider<Future<void> Function(String? path)>(
  (ref) => (path) async {
    RpcClient.instance.extraEnvironment = path == null ? {} : {'YT_DLP_PATH': path};
    await RpcClient.instance.restart();
  },
);

final ytDlpControllerProvider = NotifierProvider<YtDlpController, YtDlpState>(YtDlpController.new);

const ytDlpFirstCheckDelay = Duration(seconds: 30);
const ytDlpCheckInterval = Duration(days: 7);
const ytDlpCheckJitter = Duration(hours: 6);

/// A week ± up to six hours, uniformly — the same shape as the updater's
/// jitter, so a fleet of installs does not all hit GitHub in the same minute.
Duration ytDlpNextCheckDelay(Random random) {
  final offset = random.nextInt(ytDlpCheckJitter.inSeconds * 2 + 1) - ytDlpCheckJitter.inSeconds;
  return Duration(seconds: ytDlpCheckInterval.inSeconds + offset);
}

/// 30 min, doubling, capped at 12 h — identical to `update_controller.dart`'s
/// `failureBackoff`, and for the same reason: an automatic failure must not
/// hammer GitHub every time this runs.
Duration ytDlpFailureBackoff(int consecutiveFailures) {
  if (consecutiveFailures <= 0) return ytDlpCheckInterval;
  const capMinutes = 12 * 60;
  final minutes = 30 * (1 << (consecutiveFailures - 1));
  return Duration(minutes: minutes < capMinutes ? minutes : capMinutes);
}

/// Owns the yt-dlp consent choice, the app-managed copy, and keeping it fresh
/// (docs/todo.md 49, architecture.md "yt-dlp"). Mirrors `UpdateController`'s
/// shape: one background timer, automatic failures logged and backed off,
/// manual ones shown, nothing downloaded except on consent.
class YtDlpController extends Notifier<YtDlpState> {
  Timer? _timer;
  int _consecutiveFailures = 0;
  Future<void>? _pendingSync;

  @override
  YtDlpState build() {
    ref.onDispose(() => _timer?.cancel());
    _initAsync();
    return const YtDlpState(phase: YtDlpPhase.idle());
  }

  Future<void> _initAsync() async {
    final resolution = ref.read(ytDlpResolutionProvider);

    String? version;
    YtDlpChoice? choice;
    DateTime? choiceAt;
    DateTime? lastChecked;
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedChoice = prefs.getString('ytdlp_choice');
      if (storedChoice == null) {
        // First launch with no in-app answer yet: seed from the installer's
        // registry value, once. After this the preference is the only thing
        // ever read again (todo.md 49).
        final registryConsent = ref.read(ytDlpRegistryProvider).read();
        final seeded = switch (registryConsent) {
          'yes' => YtDlpChoice.download,
          'no' => YtDlpChoice.declined,
          _ => null,
        };
        if (seeded != null) {
          choice = seeded;
          choiceAt = ref.read(ytDlpClockProvider)();
          await prefs.setString('ytdlp_choice', seeded.name);
          await prefs.setInt('ytdlp_choice_at_ms', choiceAt.millisecondsSinceEpoch);
        }
      } else {
        choice = YtDlpChoice.values.firstWhere((c) => c.name == storedChoice, orElse: () => YtDlpChoice.declined);
        final atMs = prefs.getInt('ytdlp_choice_at_ms');
        choiceAt = atMs != null ? DateTime.fromMillisecondsSinceEpoch(atMs) : null;
      }
      version = prefs.getString('ytdlp_version');
      final checkedMs = prefs.getInt('ytdlp_last_checked_ms');
      lastChecked = checkedMs != null ? DateTime.fromMillisecondsSinceEpoch(checkedMs) : null;
    } on Object catch (e) {
      stderr.writeln('rill yt-dlp: preferences unavailable ($e); using defaults');
    }
    if (!ref.mounted) return;

    state = state.copyWith(
      location: resolution.location,
      onPathPath: resolution.location == YtDlpLocation.onPath ? resolution.path : null,
      appManagedVersion: resolution.location == YtDlpLocation.appManaged ? version : null,
      choice: choice,
      choiceAt: choiceAt,
      lastChecked: lastChecked,
    );

    _logStartupLine();

    final needsMaintenance = resolution.location == YtDlpLocation.appManaged || (resolution.location == YtDlpLocation.missing && choice == YtDlpChoice.download);
    if (needsMaintenance) _scheduleNext(ytDlpFirstCheckDelay);
  }

  void _logStartupLine() {
    final s = state;
    final line = switch (s.location) {
      YtDlpLocation.onPath => 'on PATH at ${s.onPathPath}',
      YtDlpLocation.appManaged => 'app-managed ${s.appManagedVersion ?? '(unknown version)'} at ${ref.read(ytDlpTargetProvider).path}',
      YtDlpLocation.missing when s.choice == YtDlpChoice.download => 'missing, download pending',
      YtDlpLocation.missing when s.choice == YtDlpChoice.declined => 'missing, declined by user on ${s.choiceAt?.toIso8601String() ?? 'unknown date'}',
      YtDlpLocation.missing => 'missing, no choice yet',
    };
    stderr.writeln('rill: yt-dlp: $line');
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    _timer = ref.read(ytDlpTimerFactoryProvider)(delay, () => sync(manual: false));
  }

  /// Checks whether the installed copy still matches yt-dlp's own checksums,
  /// downloading a fresh one if not. A no-op when a PATH copy is in charge —
  /// that one is never touched or updated by this app.
  Future<void> sync({bool manual = false}) {
    if (state.location == YtDlpLocation.onPath) return Future.value();
    if (_pendingSync != null) return _pendingSync!;
    _pendingSync = _syncInternal(manual).whenComplete(() => _pendingSync = null);
    return _pendingSync!;
  }

  Future<void> _syncInternal(bool manual) async {
    state = state.copyWith(phase: const YtDlpPhase.checking());
    final downloader = ref.read(ytDlpDownloaderProvider);
    try {
      final expectedHash = await downloader.fetchVerifiedHash();
      final currentHash = state.location == YtDlpLocation.appManaged ? await sha256OfFile(ref.read(ytDlpTargetProvider)) : null;
      if (currentHash == expectedHash) {
        await _markChecked();
        _succeeded();
        return;
      }
      await _downloadAndInstall(downloader, expectedHash);
    } on Object catch (error) {
      _handleFailure(manual, '$error');
    }
  }

  Future<void> _downloadAndInstall(YtDlpDownloader downloader, String expectedHash) async {
    final target = ref.read(ytDlpTargetProvider);
    state = state.copyWith(phase: const YtDlpPhase.downloading(received: 0, total: 0));
    final stopwatch = Stopwatch()..start();

    final file = await downloader.download(
      expectedHash,
      target,
      onProgress: (received) {
        if (stopwatch.elapsedMilliseconds >= 100) {
          state = state.copyWith(phase: YtDlpPhase.downloading(received: received, total: 0));
          stopwatch.reset();
        }
      },
    );

    final version = await ref.read(ytDlpVersionProbeProvider)(file.path);
    final prefs = await SharedPreferences.getInstance();
    if (version != null) await prefs.setString('ytdlp_version', version);

    if (!ref.mounted) return;
    state = state.copyWith(
      phase: const YtDlpPhase.idle(),
      location: YtDlpLocation.appManaged,
      appManagedVersion: version,
    );
    await _markChecked();
    _succeeded();

    await ref.read(ytDlpRestartSidecarProvider)(file.path);
  }

  Future<void> _markChecked() async {
    final now = ref.read(ytDlpClockProvider)();
    state = state.copyWith(lastChecked: now);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('ytdlp_last_checked_ms', now.millisecondsSinceEpoch);
    } on Object catch (e) {
      stderr.writeln('rill yt-dlp: could not persist last-checked ($e)');
    }
  }

  void _succeeded() {
    _consecutiveFailures = 0;
    _scheduleNext(ytDlpNextCheckDelay(ref.read(ytDlpRandomProvider)));
  }

  void _handleFailure(bool manual, String message) {
    if (manual) {
      state = state.copyWith(phase: YtDlpPhase.error(message: message));
    } else {
      stderr.writeln('rill yt-dlp: background refresh failed: $message');
      state = state.copyWith(phase: const YtDlpPhase.idle());
    }
    _consecutiveFailures++;
    _scheduleNext(ytDlpFailureBackoff(_consecutiveFailures));
  }

  /// The Problems page's "Download yt-dlp", and the Updates page's "Download"
  /// info-row action. Records the choice immediately, before the download
  /// even starts, so a failure still leaves "the user asked for this" on
  /// record for the automatic retry to keep backing off against — matching
  /// `YtDlpStateExt.hasProblem`.
  Future<void> download() async {
    await _setChoice(YtDlpChoice.download);
    await sync(manual: true);
  }

  /// The Problems page's "I don't want it". No download is attempted; the
  /// Problems row disappears because `hasProblem` is now false.
  Future<void> decline() async {
    _timer?.cancel();
    _timer = null;
    await _setChoice(YtDlpChoice.declined);
    state = state.copyWith(phase: const YtDlpPhase.idle());
  }

  Future<void> _setChoice(YtDlpChoice choice) async {
    final now = ref.read(ytDlpClockProvider)();
    state = state.copyWith(choice: choice, choiceAt: now);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ytdlp_choice', choice.name);
      await prefs.setInt('ytdlp_choice_at_ms', now.millisecondsSinceEpoch);
    } on Object catch (e) {
      stderr.writeln('rill yt-dlp: could not persist choice ($e)');
    }
  }
}
