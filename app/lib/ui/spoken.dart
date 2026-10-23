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

/// `1st`, `2nd`, `3rd`, `11th`, `101st`: a position in a list, said as one rather than as a bare
/// number that reads as part of the title.
String spokenOrdinal(int n) {
  final lastTwo = n % 100;
  final suffix = (lastTwo >= 11 && lastTwo <= 13)
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}

final _compactCount = RegExp(r'^(\d+)(?:\.(\d+))?\s?([KkMB])(?![A-Za-z])');
final _plainCount = RegExp(r'^(\d{1,3}(?:,\d{3})+|\d+)(?=\s|$)');
final _shortAge = RegExp(r'^((?:Streamed|Premiered) )?(\d+)\s?(y|mo|w|d|h|m|s) ago$');

const _ones = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', //
  'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const _tens = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];

/// `220` is "two hundred twenty", `5` is "five". A number left to the reader is split by
/// its neighbours ("220M" came out as "two, twenty million"); a word is not. Past a million the
/// digits are left as they are.
String spokenNumber(int n) {
  if (n < 0 || n >= 1000000) return '$n';
  if (n < 20) return _ones[n];
  if (n < 100) return n % 10 == 0 ? _tens[n ~/ 10] : '${_tens[n ~/ 10]}-${_ones[n % 10]}';
  if (n < 1000) return n % 100 == 0 ? '${_ones[n ~/ 100]} hundred' : '${_ones[n ~/ 100]} hundred ${spokenNumber(n % 100)}';
  return n % 1000 == 0 ? '${spokenNumber(n ~/ 1000)} thousand' : '${spokenNumber(n ~/ 1000)} thousand ${spokenNumber(n % 1000)}';
}

/// A display count in words: `7.7M views` is "seven point seven million views", `220M views`
/// "two hundred twenty million views", `1,234 views` "one thousand two hundred thirty-four views".
/// Anything else is returned as it came.
String spokenCount(String text) {
  final trimmed = text.trim();
  final compact = _compactCount.firstMatch(trimmed);
  if (compact != null) {
    final word = switch (compact.group(3)) {
      'K' || 'k' => 'thousand',
      'M' => 'million',
      _ => 'billion',
    };
    final decimals = compact.group(2);
    final point = decimals == null ? '' : ' point ${[for (final d in decimals.split('')) _ones[int.parse(d)]].join(' ')}';
    return '${spokenNumber(int.parse(compact.group(1)!))}$point $word${trimmed.substring(compact.end)}';
  }
  final plain = _plainCount.firstMatch(trimmed);
  if (plain != null) {
    return '${spokenNumber(int.parse(plain.group(1)!.replaceAll(',', '')))}${trimmed.substring(plain.end)}';
  }
  return text;
}

/// A short age in words: `1y ago` is "one year ago", `3mo ago` is "three months ago". YouTube's
/// own long form and anything else is returned as it came.
String spokenAge(String text) {
  final match = _shortAge.firstMatch(text.trim());
  if (match == null) return text;
  final n = int.parse(match.group(2)!);
  final unit = switch (match.group(3)) {
    'y' => 'year',
    'mo' => 'month',
    'w' => 'week',
    'd' => 'day',
    'h' => 'hour',
    'm' => 'minute',
    _ => 'second',
  };
  return '${match.group(1) ?? ''}${spokenNumber(n)} ${n == 1 ? unit : '${unit}s'} ago';
}

/// A tile's views-and-age line (`7.7M views • 1y ago`) as a screen reader says it. The bullet is a
/// pause, not a word, so the parts are joined with a comma.
String spokenStats(String line) => [
      for (final part in line.split('•')) spokenAge(spokenCount(part.trim())),
    ].where((part) => part.isNotEmpty).join(', ');
