import 'package:freezed_annotation/freezed_annotation.dart';

part 'ytdlp_state.freezed.dart';

/// What the user has said about yt-dlp, persisted with a timestamp
/// (`ytdlp_choice` / `ytdlp_choice_at_ms` in shared_preferences). `null` means
/// no choice has ever been made — the installer's registry value seeds this
/// once, on first launch; after that this is the only source of truth
/// (docs/todo.md 49).
enum YtDlpChoice { download, declined }

/// Where a working yt-dlp actually comes from, resolved fresh at startup and
/// after every download: PATH always wins over the app-managed copy, and is
/// never touched or updated by this app.
enum YtDlpLocation { onPath, appManaged, missing }

@freezed
sealed class YtDlpPhase with _$YtDlpPhase {
  const factory YtDlpPhase.idle() = YtDlpIdle;
  const factory YtDlpPhase.checking() = YtDlpChecking;
  const factory YtDlpPhase.downloading({required int received, required int total}) = YtDlpDownloading;
  const factory YtDlpPhase.error({required String message}) = YtDlpPhaseError;
}

@freezed
abstract class YtDlpState with _$YtDlpState {
  const factory YtDlpState({
    required YtDlpPhase phase,
    @Default(YtDlpLocation.missing) YtDlpLocation location,
    String? onPathPath,
    String? appManagedVersion,
    YtDlpChoice? choice,
    DateTime? choiceAt,
    DateTime? lastChecked,
  }) = _YtDlpState;
}

/// How urgently the yt-dlp row should read. yt-dlp is optional — most videos
/// play the same with or without it — so its ordinary absence is not treated
/// as an emergency; only an actual failure is. Revised 2026-09-28 after live
/// testing: the first version raised the same "a problem" framing for every
/// missing case, which read as alarming for the common, harmless one.
enum YtDlpRowSeverity {
  /// PATH or an app-managed copy already resolves it. Nothing to say.
  none,

  /// Missing, but nothing has actively gone wrong — declined, undecided, or a
  /// download in progress. Worth a quiet, permanent mention, not a dot.
  info,

  /// A download that was attempted and failed. This is what lights the
  /// avatar's attention dot.
  problem,
}

extension YtDlpStateExt on YtDlpState {
  YtDlpRowSeverity get severity {
    if (location != YtDlpLocation.missing) return YtDlpRowSeverity.none;
    if (phase is YtDlpPhaseError) return YtDlpRowSeverity.problem;
    return YtDlpRowSeverity.info;
  }
}
