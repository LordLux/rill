/// Padding the *script* coordinate space so libass stops cropping overflow.
///
/// Measured (probe_clip.dart / probe_clip2.dart, libass 0.17.5, 2026-08-21):
/// libass crops rasterised glyphs against the **video rectangle**, which is
/// `frame size minus margins` — not against the frame. `ass_set_margins` moves
/// the layout origin and shrinks the content box by exactly the same amount, so
/// growing the frame and adding margins cancels out and the crop rect never
/// moves. Asymmetric margins (l=1500, r=500, frame 3920) crop at 1500 and 3420,
/// i.e. the content edges, not 0 and 3920. `\clip` cannot widen it either: it
/// only ever intersects.
///
/// The one thing that does move the crop rect is `PlayResX`/`PlayResY`, because
/// the video rectangle *is* the play-res box scaled to the frame. So: grow the
/// play res by `padX`/`padY` on every side, shift everything that is expressed
/// in script coordinates by the same amount, and set the frame to the padded
/// play res. The scale factor `frame / PlayRes` is 1 before and after, so font
/// size, border, shadow and wrap width are untouched — the only difference is
/// that the crop rect is now `padX` further out on each side.
///
/// The caller renders into the padded space and subtracts `padX`/`padY` from
/// `dst_x`/`dst_y`, which yields coordinates in the original script space that
/// are free to go negative or past `PlayResX`.
library;

/// A script rewritten into a padded coordinate space, plus the numbers the
/// renderer and the layout need.
class PaddedScript {
  /// The rewritten `.ass` document. Feed this to `ass_process_data`.
  final String source;

  /// Play res of the *original* script — the video's coordinate space.
  final int playResX;
  final int playResY;

  /// Padding applied on each side, in original script units.
  final int padX;
  final int padY;

  const PaddedScript({
    required this.source,
    required this.playResX,
    required this.playResY,
    required this.padX,
    required this.padY,
  });

  /// Frame size to hand `ass_set_frame_size`. Rendering at 1:1 with the padded
  /// play res keeps the scale factor at 1, so `dst_x - padX` is already in
  /// original script units.
  int get frameWidth => playResX + 2 * padX;
  int get frameHeight => playResY + 2 * padY;
}

/// Fields whose values are script-space distances from an edge, and so move
/// with the padding.
const _marginFields = {'marginl': 0, 'marginr': 0, 'marginv': 1}; // 0 = x, 1 = y

/// Rewrites [source] into a coordinate space padded by [padX]/[padY] on every
/// side. Behaviour-preserving: everything renders exactly where it did, just
/// offset by the padding, and overflow past the video edges survives.
PaddedScript padScript(String source, {int padX = 640, int padY = 360}) {
  final eol = source.contains('\r\n') ? '\r\n' : '\n';
  final lines = source.split(RegExp(r'\r?\n'));

  var playResX = 0;
  var playResY = 0;
  for (final line in lines) {
    final m = RegExp(r'^\s*PlayRes([XY])\s*:\s*(-?\d+)', caseSensitive: false)
        .firstMatch(line);
    if (m == null) continue;
    final v = int.parse(m.group(2)!);
    if (m.group(1)!.toUpperCase() == 'X') {
      playResX = v;
    } else {
      playResY = v;
    }
  }
  // Mirror libass' own fallback so a header-less script does not silently
  // change size when we rewrite it.
  if (playResX <= 0 && playResY <= 0) {
    playResX = 384;
    playResY = 288;
  } else if (playResX <= 0) {
    playResX = playResY * 4 ~/ 3;
  } else if (playResY <= 0) {
    playResY = playResX * 3 ~/ 4;
  }

  var section = '';
  List<String> styleFormat = const [];
  List<String> eventFormat = const [];
  var sawPlayResX = false;
  var sawPlayResY = false;

  final out = <String>[];
  for (var line in lines) {
    final trimmed = line.trimLeft();

    if (trimmed.startsWith('[')) {
      section = trimmed.toLowerCase();
      out.add(line);
      continue;
    }

    if (section.startsWith('[script info')) {
      final m = RegExp(r'^(\s*PlayRes([XY])\s*:\s*)(-?\d+)(.*)$',
              caseSensitive: false)
          .firstMatch(line);
      if (m != null) {
        final isX = m.group(2)!.toUpperCase() == 'X';
        if (isX) {
          sawPlayResX = true;
          out.add('${m.group(1)}${playResX + 2 * padX}${m.group(4)}');
        } else {
          sawPlayResY = true;
          out.add('${m.group(1)}${playResY + 2 * padY}${m.group(4)}');
        }
        continue;
      }
    }

    if (section.startsWith('[v4') && trimmed.toLowerCase().startsWith('format:')) {
      styleFormat = _formatFields(trimmed);
      out.add(line);
      continue;
    }
    if (section.startsWith('[events') &&
        trimmed.toLowerCase().startsWith('format:')) {
      eventFormat = _formatFields(trimmed);
      out.add(line);
      continue;
    }

    if (section.startsWith('[v4') && trimmed.toLowerCase().startsWith('style:')) {
      out.add(_padStyle(line, styleFormat, padX, padY));
      continue;
    }

    if (section.startsWith('[events') &&
        (trimmed.toLowerCase().startsWith('dialogue:') ||
            trimmed.toLowerCase().startsWith('comment:'))) {
      out.add(_padEvent(line, eventFormat, padX, padY));
      continue;
    }

    out.add(line);
  }

  // A script with no PlayRes header at all still needs one now, or libass will
  // guess the *padded* frame's aspect and undo the whole point.
  if (!sawPlayResX || !sawPlayResY) {
    final idx = out.indexWhere((l) => l.trimLeft().startsWith('['));
    final header = <String>[
      if (!sawPlayResX) 'PlayResX: ${playResX + 2 * padX}',
      if (!sawPlayResY) 'PlayResY: ${playResY + 2 * padY}',
    ];
    out.insertAll(idx >= 0 ? idx + 1 : 0, header);
  }

  return PaddedScript(
    source: out.join(eol),
    playResX: playResX,
    playResY: playResY,
    padX: padX,
    padY: padY,
  );
}

List<String> _formatFields(String trimmed) => trimmed
    .substring(trimmed.indexOf(':') + 1)
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .toList();

String _padStyle(String line, List<String> format, int padX, int padY) {
  if (format.isEmpty) return line;
  final colon = line.indexOf(':');
  final head = line.substring(0, colon + 1);
  final fields = line.substring(colon + 1).split(',');
  for (var i = 0; i < fields.length && i < format.length; i++) {
    final axis = _marginFields[format[i]];
    if (axis == null) continue;
    final v = int.tryParse(fields[i].trim());
    if (v == null) continue;
    // Style margins are always live, so every one of them shifts.
    fields[i] = '${v + (axis == 0 ? padX : padY)}';
  }
  return '$head${fields.join(',')}';
}

String _padEvent(String line, List<String> format, int padX, int padY) {
  if (format.isEmpty) return line;
  final colon = line.indexOf(':');
  final head = line.substring(0, colon + 1);
  final body = line.substring(colon + 1);

  // Text is the last field and may contain commas, so split only the first
  // (n - 1) of them.
  final fields = <String>[];
  var start = 0;
  for (var i = 0; i < format.length - 1; i++) {
    final c = body.indexOf(',', start);
    if (c < 0) break;
    fields.add(body.substring(start, c));
    start = c + 1;
  }
  fields.add(body.substring(start));
  if (fields.length != format.length) return line; // malformed; leave alone

  for (var i = 0; i < fields.length; i++) {
    final axis = _marginFields[format[i]];
    if (axis == null) continue;
    final v = int.tryParse(fields[i].trim());
    // 0 means "inherit the style's margin", which is already padded. Shifting
    // it here would double-count.
    if (v == null || v == 0) continue;
    fields[i] = '${v + (axis == 0 ? padX : padY)}';
  }

  final textIdx = format.indexOf('text');
  if (textIdx >= 0) {
    fields[textIdx] = _padOverrides(fields[textIdx], padX, padY);
  }
  return '$head${fields.join(',')}';
}

final _posRe = RegExp(r'\\(pos|org|move|i?clip)\(([^)]*)\)');

/// Shifts every script-space coordinate carried by an override tag.
String _padOverrides(String text, int padX, int padY) {
  return text.replaceAllMapped(_posRe, (m) {
    final tag = m.group(1)!;
    final args = m.group(2)!;
    switch (tag) {
      case 'pos':
      case 'org':
        return '\\$tag(${_shiftNumbers(args, padX, padY, count: 2)})';
      case 'move':
        // \move(x1,y1,x2,y2) or \move(x1,y1,x2,y2,t1,t2) — timings must not move.
        return '\\move(${_shiftNumbers(args, padX, padY, count: 4)})';
      case 'clip':
      case 'iclip':
        return '\\$tag(${_shiftClip(args, padX, padY)})';
    }
    return m.group(0)!;
  });
}

/// Shifts the first [count] comma-separated numbers, alternating x, y.
String _shiftNumbers(String args, int padX, int padY, {required int count}) {
  final parts = args.split(',');
  for (var i = 0; i < parts.length && i < count; i++) {
    final v = double.tryParse(parts[i].trim());
    if (v == null) continue;
    parts[i] = _fmt(v + (i.isEven ? padX : padY));
  }
  return parts.join(',');
}

/// `\clip` has two forms: a rectangle `(x1,y1,x2,y2)` and a vector
/// `([scale,] drawing)`. Both carry script coordinates; the vector form's are
/// pre-divided by `2^(scale-1)`, so the shift has to be pre-multiplied to match.
String _shiftClip(String args, int padX, int padY) {
  final parts = args.split(',');
  if (parts.length == 4 &&
      parts.every((p) => double.tryParse(p.trim()) != null)) {
    return _shiftNumbers(args, padX, padY, count: 4);
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
  final mult = 1 << (scale - 1);
  final shifted = _shiftDrawing(drawing, padX * mult, padY * mult);
  return scale == 1 && parts.length < 2 ? shifted : '$scale,$shifted';
}

/// Every number in an ASS drawing is one half of a coordinate pair, and every
/// command that takes arguments takes them in pairs, so a single global x/y
/// alternation is correct across the whole path.
String _shiftDrawing(String drawing, int padX, int padY) {
  var isX = true;
  return drawing.replaceAllMapped(RegExp(r'-?\d+(?:\.\d+)?|[a-zA-Z]'), (m) {
    final tok = m.group(0)!;
    if (RegExp(r'^[a-zA-Z]$').hasMatch(tok)) return tok;
    final v = double.parse(tok);
    final out = _fmt(v + (isX ? padX : padY));
    isX = !isX;
    return out;
  });
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
