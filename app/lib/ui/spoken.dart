/// Durations as a screen reader should say them.
///
/// "12:50" is read as "twelve fifty"; what is meant is "12 minutes and 50 seconds".
library;

String _unit(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';

/// `1 hour, 5 minutes and 3 seconds`; `12 minutes and 50 seconds`; `45 seconds`.
String spokenDuration(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final parts = [
    if (h > 0) _unit(h, 'hour'),
    if (m > 0) _unit(m, 'minute'),
    if (s > 0 || (h == 0 && m == 0)) _unit(s, 'second'),
  ];
  if (parts.length == 1) return parts.single;
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}

/// [spokenDuration] of a clock string — `12:50` or `1:05:03` — or null if it is not one.
String? spokenClock(String clock) {
  final bits = clock.trim().split(':');
  if (bits.length < 2 || bits.length > 3) return null;
  final n = [for (final b in bits) int.tryParse(b)];
  if (n.any((v) => v == null)) return null;
  final v = n.cast<int>();
  final seconds = v.length == 3 ? v[0] * 3600 + v[1] * 60 + v[2] : v[0] * 60 + v[1];
  return spokenDuration(Duration(seconds: seconds));
}

/// "1 video" / "24 videos" — a playlist's or mix's size, shown and spoken alike.
String videoCountLabel(int count) => _unit(count, 'video');

/// How long a video is, or what stands in for it, as a screen reader says it: "Live",
/// "Station", or "`<spoken clock> long`"; null when there is nothing to say. [clock] is the
/// display text (`12:50`).
String? spokenLength({required bool isLive, required bool isStation, String? clock}) {
  if (isStation) return 'Station';
  if (isLive) return 'Live';
  return spokenClockLength(clock);
}

/// "12 minutes and 50 seconds long" for the display clock `12:50`; null for no clock. For a
/// tile, whose kind ("Live", "Station") is announced first and so is not repeated as a length.
String? spokenClockLength(String? clock) => clock == null ? null : '${spokenClock(clock) ?? clock} long';
