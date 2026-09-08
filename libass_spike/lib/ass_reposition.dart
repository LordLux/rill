/// Committing a drag back into the script.
///
/// This edits the *authored* script, never the padded copy, so nothing
/// accumulates across drags. (The previous version prepended a fresh
/// `\clip(-1000,-1000,3000,3000)` on every commit, so a line's override block
/// grew by one dead tag per gesture.)
///
/// Three cases per event, in the order libass itself resolves them:
///  - `\move` wins over `\pos`, so if it is present only its first four
///    arguments move (the last two are timings).
///  - `\pos` moves, along with `\org` and any `\clip`, which are in the same
///    screen space and would otherwise be left behind.
///  - Neither: the event is laid out from its alignment and margins, and there
///    is nothing to add a delta to. It is converted to an explicit
///    `\an<N>\pos(x,y)` anchored exactly where libass had put it, then shifted.
///    Wrapping is unaffected — libass still wraps a `\pos`ed line at the margin
///    box — so the only thing lost is auto-layout, which is what the user just
///    overrode by dragging.
library;

class _Style {
  final int alignment;
  final double marginL;
  final double marginR;
  final double marginV;
  const _Style(this.alignment, this.marginL, this.marginR, this.marginV);
}

/// Shifts every dialogue in [source] by ([dx], [dy]), expressed in script
/// units. Pure string work — no dart:ui — so it runs under the plain Dart VM
/// and can be checked offline against libass (see probe_reposition.dart).
String repositionScript(String source, double dx, double dy) {
  if (dx == 0 && dy == 0) return source;

  final eol = source.contains('\r\n') ? '\r\n' : '\n';
  final lines = source.split(RegExp(r'\r?\n'));

  var playResX = 384.0;
  var playResY = 288.0;
  for (final line in lines) {
    final m = RegExp(r'^\s*PlayRes([XY])\s*:\s*(-?\d+)', caseSensitive: false)
        .firstMatch(line);
    if (m == null) continue;
    final v = double.parse(m.group(2)!);
    if (m.group(1)!.toUpperCase() == 'X') {
      playResX = v;
    } else {
      playResY = v;
    }
  }

  final styles = <String, _Style>{};
  var section = '';
  List<String> styleFormat = const [];
  List<String> eventFormat = const [];

  // Pass 1: styles.
  for (final line in lines) {
    final t = line.trimLeft();
    if (t.startsWith('[')) {
      section = t.toLowerCase();
      continue;
    }
    if (!section.startsWith('[v4')) continue;
    final lower = t.toLowerCase();
    if (lower.startsWith('format:')) {
      styleFormat = _fields(t);
    } else if (lower.startsWith('style:') && styleFormat.isNotEmpty) {
      final vals = t.substring(t.indexOf(':') + 1).split(',');
      String? at(String name) {
        final i = styleFormat.indexOf(name);
        return (i >= 0 && i < vals.length) ? vals[i].trim() : null;
      }

      final name = at('name');
      if (name == null) continue;
      styles[name] = _Style(
        int.tryParse(at('alignment') ?? '') ?? 2,
        double.tryParse(at('marginl') ?? '') ?? 0,
        double.tryParse(at('marginr') ?? '') ?? 0,
        double.tryParse(at('marginv') ?? '') ?? 0,
      );
    }
  }

  // Pass 2: events.
  section = '';
  final out = <String>[];
  for (final line in lines) {
    final t = line.trimLeft();
    if (t.startsWith('[')) {
      section = t.toLowerCase();
      out.add(line);
      continue;
    }
    if (!section.startsWith('[events')) {
      out.add(line);
      continue;
    }
    final lower = t.toLowerCase();
    if (lower.startsWith('format:')) {
      eventFormat = _fields(t);
      out.add(line);
      continue;
    }
    if (!lower.startsWith('dialogue:') || eventFormat.isEmpty) {
      out.add(line);
      continue;
    }

    final colon = line.indexOf(':');
    final head = line.substring(0, colon + 1);
    final fields = _splitEvent(line.substring(colon + 1), eventFormat.length);
    if (fields.length != eventFormat.length) {
      out.add(line);
      continue;
    }

    final textIdx = eventFormat.indexOf('text');
    if (textIdx < 0) {
      out.add(line);
      continue;
    }

    double? evMargin(String name) {
      final i = eventFormat.indexOf(name);
      if (i < 0) return null;
      final v = double.tryParse(fields[i].trim());
      // 0 means "inherit the style".
      return (v == null || v == 0) ? null : v;
    }

    final style = styles[fields[eventFormat.indexOf('style')].trim()] ??
        const _Style(2, 0, 0, 0);

    fields[textIdx] = _shiftText(
      fields[textIdx],
      dx,
      dy,
      style: style,
      marginL: evMargin('marginl') ?? style.marginL,
      marginR: evMargin('marginr') ?? style.marginR,
      marginV: evMargin('marginv') ?? style.marginV,
      playResX: playResX,
      playResY: playResY,
    );
    out.add('$head${fields.join(',')}');
  }

  return out.join(eol);
}

List<String> _fields(String t) => t
    .substring(t.indexOf(':') + 1)
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .toList();

/// Text is the last field and may contain commas.
List<String> _splitEvent(String body, int count) {
  final fields = <String>[];
  var start = 0;
  for (var i = 0; i < count - 1; i++) {
    final c = body.indexOf(',', start);
    if (c < 0) break;
    fields.add(body.substring(start, c));
    start = c + 1;
  }
  fields.add(body.substring(start));
  return fields;
}

final _moveRe = RegExp(r'\\move\(([^)]*)\)');
final _posRe = RegExp(r'\\(pos|org)\(([^)]*)\)');
final _clipRe = RegExp(r'\\(i?clip)\(([^)]*)\)');
final _anRe = RegExp(r'\\an\s*([1-9])');
final _legacyARe = RegExp(r'\\a\s*(\d{1,2})(?![0-9])');

String _shiftText(
  String text,
  double dx,
  double dy, {
  required _Style style,
  required double marginL,
  required double marginR,
  required double marginV,
  required double playResX,
  required double playResY,
}) {
  var out = text;
  final hasMove = _moveRe.hasMatch(out);
  final hasPos = RegExp(r'\\pos\(').hasMatch(out);

  if (hasMove || hasPos) {
    if (hasMove) {
      out = out.replaceAllMapped(_moveRe,
          (m) => '\\move(${_shiftArgs(m.group(1)!, dx, dy, 4)})');
      // A \pos alongside \move is dead, but leaving it stale is a trap for
      // whoever reads the file next.
      out = out.replaceAllMapped(_posRe,
          (m) => '\\${m.group(1)}(${_shiftArgs(m.group(2)!, dx, dy, 2)})');
    } else {
      out = out.replaceAllMapped(_posRe,
          (m) => '\\${m.group(1)}(${_shiftArgs(m.group(2)!, dx, dy, 2)})');
    }
    out = out.replaceAllMapped(
        _clipRe, (m) => '\\${m.group(1)}(${_shiftClip(m.group(2)!, dx, dy)})');
    return out;
  }

  // No explicit position: pin it where libass would have put it, then shift.
  final an = _alignment(out) ?? style.alignment;
  final anchor = _anchorFor(an, marginL, marginR, marginV, playResX, playResY);
  final x = anchor[0] + dx;
  final y = anchor[1] + dy;
  final tag = '{\\an$an\\pos(${_fmt(x)},${_fmt(y)})}';

  // Merge into a leading override block if there is one, so we do not end up
  // with {..}{..} and a needless second parse.
  if (out.startsWith('{')) {
    final close = out.indexOf('}');
    if (close > 0) {
      return '{\\an$an\\pos(${_fmt(x)},${_fmt(y)})${out.substring(1, close)}}'
          '${out.substring(close + 1)}';
    }
  }
  return '$tag$out';
}

int? _alignment(String text) {
  final m = _anRe.firstMatch(text);
  if (m != null) return int.parse(m.group(1)!);
  final l = _legacyARe.firstMatch(text);
  if (l == null) return null;
  // Legacy \a: 1..3 bottom, 5..7 top, 9..11 middle; low two bits are the column.
  const map = {
    1: 1, 2: 2, 3: 3, //
    5: 7, 6: 8, 7: 9, //
    9: 4, 10: 5, 11: 6,
  };
  return map[int.parse(l.group(1)!)];
}

/// Where libass anchors an un-positioned event, given its alignment. Matches
/// the `\an` anchor semantics so `\an<N>\pos(anchor)` reproduces the layout.
List<double> _anchorFor(int an, double marginL, double marginR, double marginV,
    double playResX, double playResY) {
  final col = (an - 1) % 3; // 0 left, 1 centre, 2 right
  final row = (an - 1) ~/ 3; // 0 bottom, 1 middle, 2 top

  final double x;
  switch (col) {
    case 0:
      x = marginL;
      break;
    case 2:
      x = playResX - marginR;
      break;
    default:
      x = (marginL + (playResX - marginR)) / 2;
  }

  final double y;
  switch (row) {
    case 0:
      y = playResY - marginV;
      break;
    case 2:
      y = marginV;
      break;
    default:
      y = playResY / 2;
  }
  return [x, y];
}

String _shiftArgs(String args, double dx, double dy, int count) {
  final parts = args.split(',');
  for (var i = 0; i < parts.length && i < count; i++) {
    final v = double.tryParse(parts[i].trim());
    if (v == null) continue;
    parts[i] = _fmt(v + (i.isEven ? dx : dy));
  }
  return parts.join(',');
}

String _shiftClip(String args, double dx, double dy) {
  final parts = args.split(',');
  if (parts.length == 4 &&
      parts.every((p) => double.tryParse(p.trim()) != null)) {
    return _shiftArgs(args, dx, dy, 4);
  }
  var scale = 1;
  var drawing = args;
  if (parts.length >= 2) {
    final s = int.tryParse(parts[0].trim());
    if (s != null && s >= 1) {
      scale = s;
      drawing = parts.sublist(1).join(',');
    }
  }
  final mult = (1 << (scale - 1)).toDouble();
  var isX = true;
  final shifted =
      drawing.replaceAllMapped(RegExp(r'-?\d+(?:\.\d+)?|[a-zA-Z]'), (m) {
    final tok = m.group(0)!;
    if (RegExp(r'^[a-zA-Z]$').hasMatch(tok)) return tok;
    final v = double.parse(tok) + (isX ? dx : dy) * mult;
    isX = !isX;
    return _fmt(v);
  });
  return scale == 1 && parts.length < 2 ? shifted : '$scale,$shifted';
}

String _fmt(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  // Six decimals, trailing zeros stripped. Two was not enough: Untitled.ass
  // carries `\move(441.333,...)`, and rounding that to 441.33 shifted a
  // rasterisation boundary far enough to change a shadow bitmap by one pixel.
  // toString() would be exact but can emit exponent form, which no ASS parser
  // accepts.
  var s = v.toStringAsFixed(6);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

/// One event's time span, and its `\move` path if it has one.
///
/// The keep-on-screen clamp exists for the case where a caption's *text* grew
/// past the edge. It must not fight a line written to travel off screen —
/// `{\move(-200,800,2000,800)}` slides in from the left on purpose, and before
/// the crop was fixed that case was invisible because libass threw the pixels
/// away.
///
/// Only `\move` counts as "deliberately off screen". An earlier version also
/// flagged any `\pos` outside the video, which was wrong in a way that killed
/// the whole feature: a drag shifts *every* line, so any incidental line pushed
/// out of frame flagged itself, and the clamp went silent for that line's whole
/// span. Measured on `L-BgxLtMxh0.ass` with a (340, -60) drag: 30 of 265 events
/// self-flagged and 10 of 19 overflowing frames were suppressed.
class AssEventSpan {
  final int startMs;
  final int endMs;

  /// `[x1, y1, x2, y2, t1, t2]` in script units and ms-from-event-start, or
  /// null when the event does not move.
  final List<double>? move;

  const AssEventSpan(this.startMs, this.endMs, this.move);

  bool contains(int ms) => ms >= startMs && ms < endMs;

  /// The anchor this event is drawn at, at [ms]. Null when it does not move.
  List<double>? anchorAt(int ms) {
    final m = move;
    if (m == null) return null;
    final rel = (ms - startMs).toDouble();
    final t1 = m[4];
    final t2 = m[5] > m[4] ? m[5] : (endMs - startMs).toDouble();
    final f = t2 <= t1 ? 1.0 : ((rel - t1) / (t2 - t1)).clamp(0.0, 1.0);
    return [m[0] + (m[2] - m[0]) * f, m[1] + (m[3] - m[1]) * f];
  }
}

/// Scans [source] once so the renderer can ask, per frame, where the moving
/// events currently are.
List<AssEventSpan> parseEventSpans(String source) {
  final lines = source.split(RegExp(r'\r?\n'));
  final spans = <AssEventSpan>[];
  var section = '';
  List<String> eventFormat = const [];

  for (final line in lines) {
    final t = line.trimLeft();
    if (t.startsWith('[')) {
      section = t.toLowerCase();
      continue;
    }
    if (!section.startsWith('[events')) continue;
    final lower = t.toLowerCase();
    if (lower.startsWith('format:')) {
      eventFormat = _fields(t);
      continue;
    }
    if (!lower.startsWith('dialogue:') || eventFormat.isEmpty) continue;

    final fields =
        _splitEvent(t.substring(t.indexOf(':') + 1), eventFormat.length);
    if (fields.length != eventFormat.length) continue;
    final si = eventFormat.indexOf('start');
    final ei = eventFormat.indexOf('end');
    final ti = eventFormat.indexOf('text');
    if (si < 0 || ei < 0 || ti < 0) continue;

    List<double>? move;
    final m = _moveRe.firstMatch(fields[ti]);
    if (m != null) {
      final a = m
          .group(1)!
          .split(',')
          .map((v) => double.tryParse(v.trim()))
          .toList();
      if (a.length >= 4 && !a.take(4).any((v) => v == null)) {
        move = [
          a[0]!, a[1]!, a[2]!, a[3]!, //
          a.length > 4 ? (a[4] ?? 0) : 0,
          a.length > 5 ? (a[5] ?? 0) : 0,
        ];
      }
    }
    spans.add(
        AssEventSpan(_parseTime(fields[si]), _parseTime(fields[ei]), move));
  }
  return spans;
}

int _parseTime(String v) {
  final p = v.trim().split(':');
  if (p.length != 3) return 0;
  final h = int.tryParse(p[0]) ?? 0;
  final m = int.tryParse(p[1]) ?? 0;
  final s = double.tryParse(p[2]) ?? 0;
  return ((h * 3600 + m * 60 + s) * 1000).round();
}
