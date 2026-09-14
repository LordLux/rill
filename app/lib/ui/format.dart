/// Display formatting for counts.
///
/// Kept out of the widgets that use it so the rounding can be tested as
/// arithmetic, which is what it is and where the mistakes live.
library;

/// `4642098` → `"4.6M views"`.
///
/// **Truncated, not rounded, because that is what YouTube does.** 1,999 reads
/// as "1.9K" on youtube.com, not "2K"; rounding up would make this app claim a
/// milestone a video has not reached, and the difference is most visible
/// exactly where people care (999,999 → "999K", never "1M").
///
/// One decimal place only while the mantissa is below ten — "1.2K", "12K",
/// "123K" — which is YouTube's own pattern and keeps the string short enough to
/// sit in a metadata row at every magnitude.
///
/// **This is English, and deliberately so.** The app's UI strings are English
/// throughout; the moment that stops being true, the right fix is not to
/// localise this function but to stop calling it — YouTube ships its own
/// localised short form (`shortViewCountText`, `extraShortViewCount`) and the
/// sidecar can carry that instead.
String formatCompactViews(int count) {
  if (count < 0) return '';
  if (count < 1000) return count == 1 ? '1 view' : '$count views';
  return '${_compact(count)} views';
}

/// The number part alone — for anywhere the word "views" is supplied by the
/// surrounding layout rather than by this string.
String formatCompactCount(int count) {
  if (count < 0) return '';
  if (count < 1000) return '$count';
  return _compact(count);
}

const List<(int, String)> _units = [
  (1000000000, 'B'),
  (1000000, 'M'),
  (1000, 'K'),
];

String _compact(int count) {
  for (final (threshold, suffix) in _units) {
    if (count < threshold) continue;

    // Truncate to one decimal, then decide whether to show it. Integer maths
    // rather than `toStringAsFixed`, which rounds — 1999 must not become 2.0K.
    final tenths = (count * 10) ~/ threshold;
    final whole = tenths ~/ 10;
    final decimal = tenths % 10;

    if (whole >= 10 || decimal == 0) return '$whole$suffix';
    return '$whole.$decimal$suffix';
  }
  return '$count';
}
