import 'package:freezed_annotation/freezed_annotation.dart';

import 'app_version.dart';
import 'update_manifest.dart';

part 'update_state.freezed.dart';

enum UpdateErrorKind { network, signature, manifest, integrity, disk, install }
enum UpdateCheckOrigin { automatic, manual }

@freezed
sealed class UpdatePhase with _$UpdatePhase {
  const factory UpdatePhase.idle() = UpdateIdle;
  const factory UpdatePhase.checking({required UpdateCheckOrigin origin}) = UpdateChecking;
  const factory UpdatePhase.upToDate() = UpdateUpToDate;
  const factory UpdatePhase.available({required UpdateManifest manifest}) = UpdateAvailable;
  const factory UpdatePhase.downloading({required UpdateManifest manifest, required int received, required int total}) = UpdateDownloading;
  const factory UpdatePhase.ready({required UpdateManifest manifest, required String installerPath}) = UpdateReady;
  const factory UpdatePhase.installing({required UpdateManifest manifest}) = UpdateInstalling;
  const factory UpdatePhase.error({required UpdateErrorKind kind, required String message, required UpdateCheckOrigin origin, UpdateManifest? manifest}) = UpdateError;
}

@freezed
abstract class UpdateState with _$UpdateState {
  const factory UpdateState({
    required UpdatePhase phase,
    AppVersion? currentVersion,
    DateTime? lastChecked,
    String? dismissedVersion,
    @Default(true) bool autoUpdate,
    @Default(false) bool testOverridesActive,
  }) = _UpdateState;
}

extension UpdatePhaseManifest on UpdatePhase {
  /// The update on offer, if this phase has one.
  UpdateManifest? get manifest => switch (this) {
    UpdateAvailable(:final manifest) ||
    UpdateDownloading(:final manifest) ||
    UpdateReady(:final manifest) ||
    UpdateInstalling(:final manifest) => manifest,
    UpdateError(:final manifest) => manifest,
    _ => null,
  };
}

extension UpdateStateExt on UpdateState {
  /// `minimumVersion` above the running version: shown prominently, and "Later"
  /// does not hide it (architecture.md §2.14).
  bool get isMandatory {
    final minimum = phase.manifest?.minimumVersion;
    final current = currentVersion;
    return minimum != null && current != null && current < minimum;
  }

  /// Whether the avatar dot and the menu should call attention to an update:
  /// one is ready (or on offer with automatic download off), and it has not
  /// been dismissed — unless it is mandatory.
  bool get showsNotice {
    final manifest = switch (phase) {
      UpdateReady(:final manifest) => manifest,
      UpdateAvailable(:final manifest) when !autoUpdate => manifest,
      _ => null,
    };
    if (manifest == null) return false;
    return isMandatory || dismissedVersion != manifest.version.toString();
  }
}

/// The state machine's two gates (architecture.md §2.14): no second check while
/// one is running or a download or install is under way, and install only from
/// a verified, ready file.
bool canStartCheck(UpdatePhase p) => switch (p) {
  UpdateChecking() || UpdateDownloading() || UpdateInstalling() => false,
  _ => true,
};

bool canInstall(UpdatePhase p) => p is UpdateReady;
