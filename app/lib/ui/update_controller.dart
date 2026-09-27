import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/update/update_state.dart';
import '../data/update/update_config.dart';
import '../data/update/update_http.dart';
import '../data/update/update_downloader.dart';
import '../data/update/update_verifier.dart';
import '../data/update/installer_launcher.dart';

final updateConfigProvider = Provider<UpdateConfig>((ref) => UpdateConfig.fromEnvironment());
final updateHttpProvider = Provider<UpdateHttp>((ref) => IoUpdateHttp());
final updateDownloaderProvider = Provider<UpdateDownloader>((ref) => UpdateDownloader(http: ref.watch(updateHttpProvider), root: UpdateDownloader.defaultRoot()));
final updateClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final updateRandomProvider = Provider<Random>((ref) => Random());

typedef UpdateTimerFactory = Timer Function(Duration delay, void Function() callback);
final updateTimerFactoryProvider = Provider<UpdateTimerFactory>((ref) => Timer.new);

typedef InstallerLauncher = Future<int> Function(File installer, List<String> arguments, Future<bool> Function(File) verify);
final updateInstallerLauncherProvider = Provider<InstallerLauncher>((ref) => (f, a, v) => launchVerifiedInstaller(installer: f, arguments: a, verify: v));

final updateExitAppProvider = Provider<Future<void> Function()>((ref) => () async => appWindow.close());

final updateControllerProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

const updateFirstCheckDelay = Duration(seconds: 30);
const updateCheckInterval = Duration(hours: 12);
const updateCheckJitter = Duration(minutes: 10);

/// 12 h ± up to 10 min, uniformly, whole seconds.
Duration nextCheckDelay(Random random) {
  final offset = random.nextInt(updateCheckJitter.inSeconds * 2 + 1) - updateCheckJitter.inSeconds;
  return Duration(seconds: updateCheckInterval.inSeconds + offset);
}

/// After the n-th consecutive automatic failure (n >= 1): 30 min, 1 h, 2 h, ... capped at 12 h.
Duration failureBackoff(int consecutiveFailures) {
  if (consecutiveFailures <= 0) return updateCheckInterval;
  final maxMinutes = updateCheckInterval.inMinutes;
  final minutes = 30 * (1 << (consecutiveFailures - 1));
  return Duration(minutes: minutes < maxMinutes ? minutes : maxMinutes);
}

/// Checks, downloads and installs updates (architecture.md §2.14): 30 s after
/// launch, then every 12 h ± 10 min, and on demand; one check at a time;
/// automatic failures are logged and backed off, manual ones are shown. Nothing
/// is installed except on the user's click.
class UpdateController extends Notifier<UpdateState> {
  Timer? _timer;
  int _consecutiveFailures = 0;
  Future<void>? _pendingCheck;
  bool _noOpLogged = false;

  @override
  UpdateState build() {
    final config = ref.watch(updateConfigProvider);
    stderr.writeln('rill update: config ${config.describe()}, version ${config.currentVersion ?? 'none (dev build)'}');
    if (config.overridden) {
      stderr.writeln('rill update: UPDATER TEST OVERRIDES ACTIVE: ${config.activeOverrides.join('/')}');
    }

    ref.onDispose(() {
      _timer?.cancel();
    });

    _initAsync(config);

    return UpdateState(
      phase: const UpdatePhase.idle(),
      currentVersion: config.currentVersion,
      testOverridesActive: config.overridden,
    );
  }

  Future<void> _initAsync(UpdateConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final lastCheckedMs = prefs.getInt('update_last_checked_ms');
    final dismissedVersion = prefs.getString('update_dismissed_version');
    final autoUpdate = prefs.getBool('update_auto') ?? true;

    state = state.copyWith(
      lastChecked: lastCheckedMs != null ? DateTime.fromMillisecondsSinceEpoch(lastCheckedMs) : null,
      dismissedVersion: dismissedVersion,
      autoUpdate: autoUpdate,
    );

    if (config.enabled && autoUpdate) {
      _scheduleNextCheck(updateFirstCheckDelay);
    }
  }

  void _scheduleNextCheck(Duration delay) {
    _timer?.cancel();
    _timer = ref.read(updateTimerFactoryProvider)(delay, () {
      checkNow(origin: UpdateCheckOrigin.automatic);
    });
  }

  Future<void> checkNow({UpdateCheckOrigin origin = UpdateCheckOrigin.manual}) {
    if (_pendingCheck != null) return _pendingCheck!;
    _pendingCheck = _checkNowInternal(origin).whenComplete(() => _pendingCheck = null);
    return _pendingCheck!;
  }

  Future<void> _checkNowInternal(UpdateCheckOrigin origin) async {
    final config = ref.read(updateConfigProvider);
    if (!config.enabled) {
      if (!_noOpLogged) {
        stderr.writeln('rill update: checkNow is a no-op (updater disabled)');
        _noOpLogged = true;
      }
      return;
    }

    if (!canStartCheck(state.phase)) return;
    
    final oldPhase = state.phase;
    state = state.copyWith(phase: UpdatePhase.checking(origin: origin));

    final http = ref.read(updateHttpProvider);
    final clock = ref.read(updateClockProvider);
    
    try {
      final manifestBytes = await http.getBytes(config.manifestUrl, maxBytes: 64 * 1024);
      final signatureBytes = await http.getBytes(config.signatureUrl, maxBytes: 1024);
      
      final checkResult = await checkManifest(
        manifestBytes: manifestBytes,
        signatureFileBytes: signatureBytes,
        config: config,
      );

      final now = clock();
      state = state.copyWith(lastChecked: now);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('update_last_checked_ms', now.millisecondsSinceEpoch);

      if (checkResult is ManifestNewer) {
        final manifest = checkResult.manifest;
        // Already downloaded and verified: stay ready rather than offering it again.
        if (oldPhase is UpdateReady && oldPhase.manifest.version == manifest.version) {
          state = state.copyWith(phase: oldPhase);
          _succeeded();
          return;
        }
        state = state.copyWith(phase: UpdatePhase.available(manifest: manifest));
        // The failure count is reset only once the download also succeeds, so a
        // release whose installer never verifies backs off instead of being
        // fetched again every half hour (architecture.md §2.14).
        _scheduleNextCheck(nextCheckDelay(ref.read(updateRandomProvider)));
        if (state.autoUpdate) {
          await download(origin: origin);
        }
      } else if (checkResult is ManifestNotNewer || checkResult is ManifestIgnored) {
        if (checkResult is ManifestIgnored) stderr.writeln('rill update: ${checkResult.reason}, ignored');
        state = state.copyWith(phase: const UpdatePhase.upToDate());
        _succeeded();
        await ref.read(updateDownloaderProvider).deleteStale();
      } else if (checkResult is ManifestRejected) {
        _handleError(oldPhase, origin, checkResult.kind, checkResult.message);
      }
    } on UpdateNetworkException catch (e) {
      _handleError(oldPhase, origin, UpdateErrorKind.network, e.toString());
    } catch (e) {
      _handleError(oldPhase, origin, UpdateErrorKind.manifest, e.toString()); 
    }
  }

  void _succeeded() {
    _consecutiveFailures = 0;
    _scheduleNextCheck(nextCheckDelay(ref.read(updateRandomProvider)));
  }

  void _handleError(UpdatePhase oldPhase, UpdateCheckOrigin origin, UpdateErrorKind kind, String message) {
    if (origin == UpdateCheckOrigin.manual) {
      state = state.copyWith(phase: UpdatePhase.error(kind: kind, message: message, origin: origin));
    } else {
      stderr.writeln('rill update: background check failed: $message');
      state = state.copyWith(phase: oldPhase);
    }
    _consecutiveFailures++;
    _scheduleNextCheck(failureBackoff(_consecutiveFailures));
  }

  /// [origin] decides whether a failure is shown or only logged; a click on
  /// "Download" is manual.
  Future<void> download({UpdateCheckOrigin origin = UpdateCheckOrigin.manual}) async {
    final phase = state.phase;
    final manifest = phase.manifest;
    if (manifest == null) return;
    if (phase is! UpdateAvailable && phase is! UpdateError) return;
    
    state = state.copyWith(phase: UpdatePhase.downloading(manifest: manifest, received: 0, total: manifest.windowsX64.size));
    
    final downloader = ref.read(updateDownloaderProvider);
    final stopwatch = Stopwatch()..start();
    
    try {
      final file = await downloader.download(
        manifest,
        onProgress: (received, total) {
          if (stopwatch.elapsedMilliseconds >= 100) {
            state = state.copyWith(
              phase: UpdatePhase.downloading(manifest: manifest, received: received, total: total)
            );
            stopwatch.reset();
          }
        },
      );
      state = state.copyWith(phase: UpdatePhase.ready(manifest: manifest, installerPath: file.path));
      _succeeded();
      await downloader.deleteStale(keepVersion: manifest.version.toString());
    } catch (e) {
      final kind = switch (e) {
        UpdateIntegrityException() => UpdateErrorKind.integrity,
        UpdateDiskException() => UpdateErrorKind.disk,
        UpdateNetworkException() => UpdateErrorKind.network,
        _ => UpdateErrorKind.manifest,
      };
      stderr.writeln('rill update: download failed (${kind.name}): $e');
      state = state.copyWith(
        phase: origin == UpdateCheckOrigin.manual
            ? UpdatePhase.error(kind: kind, message: e.toString(), origin: origin, manifest: manifest)
            : UpdatePhase.available(manifest: manifest),
      );
      _consecutiveFailures++;
      _scheduleNextCheck(failureBackoff(_consecutiveFailures));
    }
  }

  Future<void> install() async {
    final phase = state.phase;
    if (!canInstall(phase)) return;
    
    final manifest = phase.manifest!;
    final readyPhase = phase as UpdateReady;
    final file = File(readyPhase.installerPath);
    
    state = state.copyWith(phase: UpdatePhase.installing(manifest: manifest));
    
    final downloader = ref.read(updateDownloaderProvider);
    final launcher = ref.read(updateInstallerLauncherProvider);
    
    try {
      final root = downloader.root.path;
      final args = [
        '/VERYSILENT', 
        '/SUPPRESSMSGBOXES', 
        '/NORESTART', 
        '/CLOSEAPPLICATIONS', 
        '/RELAUNCH=1', 
        '/LOG="$root\\install-${manifest.version}.log"'
      ];
      
      await launcher(
        file, 
        args, 
        (f) => verifyFile(f, size: manifest.windowsX64.size, sha256: manifest.windowsX64.sha256)
      );
      
      await ref.read(updateExitAppProvider)();
    } catch (e) {
      stderr.writeln('rill update: install failed: $e');
      state = state.copyWith(phase: UpdatePhase.error(kind: UpdateErrorKind.install, message: e.toString(), origin: UpdateCheckOrigin.manual, manifest: manifest));
    }
  }

  Future<void> dismiss() async {
    final manifest = state.phase.manifest;
    if (manifest == null) return;
    if (state.isMandatory) return;
    
    final versionStr = manifest.version.toString();
    state = state.copyWith(dismissedVersion: versionStr);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update_dismissed_version', versionStr);
  }

  Future<void> setAutoUpdate(bool v) async {
    if (state.autoUpdate == v) return;
    state = state.copyWith(autoUpdate: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('update_auto', v);
    
    if (v) {
      if (state.phase is UpdateAvailable) {
        unawaited(download());
      } else {
        final config = ref.read(updateConfigProvider);
        if (config.enabled && _timer == null) {
           _scheduleNextCheck(updateFirstCheckDelay);
        }
      }
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }
}
