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

extension YtDlpStateExt on YtDlpState {
  /// The Problems row shows and the avatar's attention dot lights up while
  /// this is true: nothing playable is installed, and either nobody has ever
  /// said what to do about it, or they asked for it and it is not there yet
  /// (a download that failed, or has not run since the choice was made).
  bool get hasProblem => location == YtDlpLocation.missing && (choice == null || choice == YtDlpChoice.download);
}
