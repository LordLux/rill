import 'dart:io';

import '../../domain/ytdlp/ytdlp_state.dart';

/// Where this app's own copy of yt-dlp lives — never on `PATH`, so it can
/// never shadow or collide with one the user installed themselves.
File appManagedYtDlp() => File('${Platform.environment['LOCALAPPDATA']}\\rill\\bin\\yt-dlp.exe');

/// The names `where` (and the sidecar's own `Bun.which`) will find, in the
/// order a shell would.
const _pathNames = ['yt-dlp.exe', 'yt-dlp.bat', 'yt-dlp.cmd', 'yt-dlp'];

/// A yt-dlp already on `PATH`, independent of anything this app manages —
/// searched the same way the sidecar resolves the bare name (`Bun.which`,
/// `sidecar/src/capabilities.ts`), so the two processes agree on what "on
/// PATH" means. Returns the first match's full path, or `null`.
///
/// A plain directory walk rather than shelling out to `where`: cheaper, and
/// it runs at every startup.
String? ytDlpOnPath({String? pathEnv}) {
  final raw = pathEnv ?? Platform.environment['PATH'] ?? '';
  for (final dir in raw.split(';')) {
    if (dir.isEmpty) continue;
    for (final name in _pathNames) {
      final candidate = File('$dir\\$name');
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

/// Where a working yt-dlp comes from right now, resolved fresh — PATH always
/// wins. Call this before spawning the sidecar (to decide `YT_DLP_PATH`) and
/// from `YtDlpController` (to seed its state); both must agree, so both go
/// through this one function rather than repeating the PATH-then-app-managed
/// order separately.
class YtDlpResolution {
  const YtDlpResolution({required this.location, this.path});
  final YtDlpLocation location;

  /// The resolved path for [YtDlpLocation.onPath] or [YtDlpLocation.appManaged];
  /// `null` for [YtDlpLocation.missing].
  final String? path;
}

YtDlpResolution resolveYtDlp() {
  final onPath = ytDlpOnPath();
  if (onPath != null) return YtDlpResolution(location: YtDlpLocation.onPath, path: onPath);
  final managed = appManagedYtDlp();
  if (managed.existsSync()) return YtDlpResolution(location: YtDlpLocation.appManaged, path: managed.path);
  return const YtDlpResolution(location: YtDlpLocation.missing);
}

/// `yt-dlp --version`'s first line, or `null` if it cannot be run or answers
/// nothing — spawned only right after a fresh download verifies, so the
/// version shown in the Problems and Updates pages is cached rather than
/// re-read from a process on every rebuild.
Future<String?> ytDlpVersion(String exePath) async {
  try {
    final result = await Process.run(exePath, ['--version']);
    if (result.exitCode != 0) return null;
    final line = (result.stdout as String).split(RegExp(r'\r?\n')).first.trim();
    return line.isEmpty ? null : line;
  } on Object {
    return null;
  }
}
