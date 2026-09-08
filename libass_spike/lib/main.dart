import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:ui' as ui;

import 'ass_binding.dart';
import 'ass_padding.dart';
import 'ass_reposition.dart';
import 'caption_layout.dart';

/// Script-space padding on each side. libass crops against the video rectangle
/// (see ass_padding.dart), so this is how much overflow survives to Dart. It
/// costs nothing at render time — the returned bitmaps are glyph-sized either
/// way — so it is set generously.
const int kPadX = 960;
const int kPadY = 540;

void _addDllDirectory(String path) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setDllDir = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('SetDllDirectoryW');

    final pathPtr = path.toNativeUtf16();
    setDllDir(pathPtr);
    malloc.free(pathPtr);
  } catch (e) {
    debugPrint('Failed to set DLL directory: $e');
  }
}

void main() {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LibAss Spike',
      theme: ThemeData.dark(),
      home: const SubtitleTestPage(),
    );
  }
}

class SubtitleTestPage extends StatefulWidget {
  const SubtitleTestPage({super.key});

  @override
  State<SubtitleTestPage> createState() => _SubtitleTestPageState();
}

class _SubtitleTestPageState extends State<SubtitleTestPage>
    with SingleTickerProviderStateMixin {
  late final DynamicLibrary _dylib;
  late final LibAssBindings _libass;
  Pointer<ASS_Library>? _assLibrary;
  Pointer<ASS_Renderer>? _assRenderer;
  Pointer<ASS_Track>? _assTrack;

  double _currentTime = 0;
  double _duration = 10.0;
  bool _initialized = false;
  String _error = '';

  late final Ticker _ticker;
  bool _isPlaying = false;
  Duration _lastElapsed = Duration.zero;

  bool _isRendering = false;
  double? _pendingTime;

  /// The script as authored. Every reposition edits this; the padded copy is
  /// derived, never edited, so nothing accumulates across drags.
  String _rawAss = '';
  late PaddedScript _padded;
  List<AssEventSpan> _spans = const [];

  /// This frame's images, and their per-group union boxes in script units.
  List<SubtitleImage> _currentImages = [];
  List<Box> _groupBoxes = const [];

  /// Drag offset in *script* units, so committing it is a plain addition.
  Offset _dragDelta = Offset.zero;

  /// Display-time correction keeping overflowing captions on screen, one entry
  /// per caption group. Visual only until the next commit folds it in.
  ///
  /// Per group, not per frame: a track can put several independently placed
  /// captions on screen at once — `L-BgxLtMxh0.ass` shows six scattered words
  /// at 32 s — and clamping their union moves five of them for the sixth.
  List<Offset> _nudges = const [];

  double _currentScaleX = 1.0;
  double _currentScaleY = 1.0;

  bool _isCommittingDrag = false;
  bool _isDraggable = true;
  bool _showBounds = false;
  bool _drawBackground = false;
  bool _drawWindow = false;

  /// The delta a commit folds in. The drag is global, so this is the largest
  /// clamp currently on screen.
  Offset get _largestNudge {
    var best = Offset.zero;
    for (final n in _nudges) {
      if (n.distanceSquared > best.distanceSquared) best = n;
    }
    return best;
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (!_isPlaying) {
        _lastElapsed = elapsed;
        return;
      }
      final delta = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
      _lastElapsed = elapsed;

      setState(() {
        _currentTime += delta;
        if (_currentTime > _duration) {
          _currentTime = _duration;
          _isPlaying = false;
          _ticker.stop();
        }
      });
      _renderFrame(_currentTime);
    });
    _initAss();
  }

  void _togglePlay() {
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        if (_currentTime >= _duration) {
          _currentTime = 0;
        }
        _lastElapsed = Duration.zero;
        _ticker.start();
      } else {
        _ticker.stop();
      }
    });
  }

  double _parseAssDuration(String contents) {
    double maxTime = 0.0;
    for (final line in contents.split('\n')) {
      if (!line.startsWith('Dialogue:')) continue;
      final parts = line.split(',');
      if (parts.length < 3) continue;
      final timeParts = parts[2].trim().split(':');
      if (timeParts.length != 3) continue;
      final h = int.tryParse(timeParts[0]) ?? 0;
      final m = int.tryParse(timeParts[1]) ?? 0;
      final s = double.tryParse(timeParts[2]) ?? 0.0;
      final time = h * 3600 + m * 60 + s;
      if (time > maxTime) maxTime = time;
    }
    return maxTime > 0 ? maxTime + 1.0 : 10.0;
  }

  /// Installs [raw] as the current script: pads it, reconfigures the renderer
  /// for the padded frame, and rebuilds the track.
  void _installScript(String raw) {
    // Strip libass backgrounds (force BorderStyle=1)
    final styleRegex = RegExp(r'^(Style:(?:[^,]*,){15})3(,)', multiLine: true);
    final strippedRaw = raw.replaceAllMapped(styleRegex, (m) => '${m.group(1)}1${m.group(2)}');

    _rawAss = strippedRaw;
    _padded = padScript(strippedRaw, padX: kPadX, padY: kPadY);
    _spans = parseEventSpans(strippedRaw);

    // Margins are deliberately zero. They do not widen the crop rect — they
    // move the origin and shrink the content box by the same amount, so they
    // cancel. All the padding lives in the script now.
    _libass.ass_set_frame_size(_assRenderer!, _padded.frameWidth, _padded.frameHeight);
    _libass.ass_set_margins(_assRenderer!, 0, 0, 0, 0);
    _libass.ass_set_use_margins(_assRenderer!, 0);
    // The padded frame is no longer an isotropic scale of the video, so libass'
    // default PAR guess would be wrong. Script pixels are square.
    _libass.ass_set_pixel_aspect(_assRenderer!, 1.0);

    if (_assTrack != null && _assTrack != nullptr) {
      _libass.ass_free_track(_assTrack!);
    }
    _assTrack = _libass.ass_new_track(_assLibrary!);
    final data = _padded.source.toNativeUtf8();
    _libass.ass_process_data(_assTrack!, data, data.length);
    malloc.free(data);
  }

  void _commitDrag() {
    final shift = _dragDelta + _largestNudge;
    if (shift == Offset.zero) return;

    _installScript(repositionScript(_rawAss, shift.dx, shift.dy));

    _isCommittingDrag = true;
    _renderFrame(_currentTime);
  }

  void _loadAssFile(String path) {
    if (!_initialized) return;
    final contents = File(path).readAsStringSync();

    _installScript(contents);

    setState(() {
      _duration = _parseAssDuration(contents);
      _currentTime = 0;
      _isPlaying = false;
      _ticker.stop();
      _dragDelta = Offset.zero;
      _nudges = const [];
      _groupBoxes = const [];
      _disposeImages(_currentImages);
      _currentImages = [];
    });

    _renderFrame(0);
  }

  void _initAss() {
    try {
      final dllPath = r'C:\msys64\msys64\mingw64\bin\libass-9.dll';
      _dylib = DynamicLibrary.open(dllPath);
      _libass = LibAssBindings(_dylib);

      _assLibrary = _libass.ass_library_init();
      if (_assLibrary == nullptr) {
        throw Exception('ass_library_init failed');
      }

      _assRenderer = _libass.ass_renderer_init(_assLibrary!);
      if (_assRenderer == nullptr) {
        throw Exception('ass_renderer_init failed');
      }

      final defaultFont = 'Arial'.toNativeUtf8();
      final defaultFamily = 'Arial'.toNativeUtf8();
      _libass.ass_set_fonts(
          _assRenderer!, defaultFont, defaultFamily, 1, nullptr, 1);
      malloc.free(defaultFont);
      malloc.free(defaultFamily);

      _installScript(_demoScript);

      setState(() {
        _initialized = true;
        _duration = _parseAssDuration(_demoScript);
      });
      _renderFrame(_currentTime);
    } catch (e, st) {
      setState(() {
        _error = '$e\n$st';
      });
    }
  }

  void _renderFrame(double timeSeconds) async {
    if (!_initialized) return;

    if (_isRendering) {
      _pendingTime = timeSeconds;
      return;
    }

    _isRendering = true;

    try {
      final nowMs = (timeSeconds * 1000).toInt();

      final changePtr = malloc<Int32>();
      final imagePtr =
          _libass.ass_render_frame(_assRenderer!, _assTrack!, nowMs, changePtr);
      malloc.free(changePtr);

      // The linked list is owned by the renderer and dies on the next
      // ass_render_frame, so every byte is copied out before any await.
      final rawImages = <_RawImage>[];
      Pointer<ASS_Image> current = imagePtr;

      while (current != nullptr) {
        final img = current.ref;

        if (img.w > 0 && img.h > 0) {
          final color = img.color;
          final r = (color >> 24) & 0xFF;
          final g = (color >> 16) & 0xFF;
          final b = (color >> 8) & 0xFF;
          final a = color & 0xFF;

          final rgbaPixels = Uint8List(img.w * img.h * 4);
          final mask = img.bitmap.asTypedList(img.stride * img.h);

          for (int y = 0; y < img.h; y++) {
            for (int x = 0; x < img.w; x++) {
              final maskVal = mask[y * img.stride + x];
              final outIdx = (y * img.w + x) * 4;
              final finalAlpha = (maskVal * (255 - a)) ~/ 255;
              rgbaPixels[outIdx] = (r * finalAlpha) ~/ 255;
              rgbaPixels[outIdx + 1] = (g * finalAlpha) ~/ 255;
              rgbaPixels[outIdx + 2] = (b * finalAlpha) ~/ 255;
              rgbaPixels[outIdx + 3] = finalAlpha;
            }
          }

          // Back into the original script's coordinate space. These are now
          // free to be negative or to exceed PlayResX/Y — that is the point.
          rawImages.add(_RawImage(
            rgbaPixels,
            img.w,
            img.h,
            (img.dst_x - _padded.padX).toDouble(),
            (img.dst_y - _padded.padY).toDouble(),
            img.type,
          ));
        }

        current = img.next;
      }

      final boxes = [
        for (final r in rawImages) Box(r.x, r.y, r.x + r.w, r.y + r.h)
      ];
      final groups = groupImages([for (final r in rawImages) r.type]);
      final newBoxes = groupBoxes(boxes, groups);

      final newImages = <SubtitleImage>[];
      for (var i = 0; i < rawImages.length; i++) {
        final raw = rawImages[i];
        final comp = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          raw.pixels,
          raw.w,
          raw.h,
          ui.PixelFormat.rgba8888,
          comp.complete,
        );
        newImages.add(SubtitleImage(
          image: await comp.future,
          x: raw.x,
          y: raw.y,
          w: raw.w.toDouble(),
          h: raw.h.toDouble(),
          group: groups[i],
        ));
      }

      final previous = _currentImages;
      setState(() {
        _currentImages = newImages;
        _groupBoxes = newBoxes;
        _nudges = _isDraggable
            ? _computeNudges(newBoxes, nowMs)
            : List.filled(newBoxes.length, Offset.zero);
        if (_isCommittingDrag) {
          _dragDelta = Offset.zero;
          _isCommittingDrag = false;
        }
      });
      // The widgets holding these are gone as of this frame.
      SchedulerBinding.instance
          .addPostFrameCallback((_) => _disposeImages(previous));
    } finally {
      _isRendering = false;
      if (_pendingTime != null) {
        final nextTime = _pendingTime!;
        _pendingTime = null;
        _renderFrame(nextTime);
      }
    }
  }

  void _disposeImages(List<SubtitleImage> images) {
    for (final i in images) {
      i.image.dispose();
    }
  }

  /// Where the moving events are right now. A caption group sitting on one of
  /// these anchors is travelling on purpose and is left alone — the demo's
  /// `{\move(-200,800,2000,800)}` slides in from off screen, and before the
  /// crop was fixed that case was invisible because libass discarded it.
  List<List<double>> _movingAnchors(int nowMs) {
    final out = <List<double>>[];
    for (final s in _spans) {
      if (!s.contains(nowMs)) continue;
      final a = s.anchorAt(nowMs);
      if (a != null) out.add(a);
    }
    return out;
  }

  /// One clamp per caption group.
  List<Offset> _computeNudges(List<Box> boxes, int nowMs) {
    final w = _padded.playResX.toDouble();
    final h = _padded.playResY.toDouble();
    final moving = _movingAnchors(nowMs);

    return [
      for (final b in boxes)
        if (moving.any((a) => b.containsPoint(a[0], a[1], slack: 8)))
          Offset.zero
        else
          _clampOf(b, w, h)
    ];
  }

  Offset _clampOf(Box b, double w, double h) {
    final padX = 8.0 / _currentScaleX;
    final padY = 4.0 / _currentScaleY;
    final bPadded = Box(b.left - padX, b.top - padY, b.right + padX, b.bottom + padY);
    
    final d = clampOffset(bPadded, w, h);
    return Offset(d[0], d[1]);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _disposeImages(_currentImages);
    if (_assTrack != null && _assTrack != nullptr) {
      _libass.ass_free_track(_assTrack!);
    }
    if (_assRenderer != null && _assRenderer != nullptr) {
      _libass.ass_renderer_done(_assRenderer!);
    }
    if (_assLibrary != null && _assLibrary != nullptr) {
      _libass.ass_library_done(_assLibrary!);
    }
    super.dispose();
  }

  Offset _nudgeFor(int group) =>
      group < _nudges.length ? _nudges[group] : Offset.zero;

  void _onPanUpdate(DragUpdateDetails details) {
    if (_groupBoxes.isEmpty) return;
    final w = _padded.playResX.toDouble();
    final h = _padded.playResY.toDouble();

    var dx = _dragDelta.dx + details.delta.dx / _currentScaleX;
    var dy = _dragDelta.dy + details.delta.dy / _currentScaleY;

    // Intersect the allowed range over every group that fits, rather than
    // clamping the union box — with several captions on screen the union is far
    // larger than any of them and would refuse almost any drag.
    var loX = double.negativeInfinity, hiX = double.infinity;
    var loY = double.negativeInfinity, hiY = double.infinity;
    for (var i = 0; i < _groupBoxes.length; i++) {
      final n = _nudgeFor(i);
      final b = _groupBoxes[i].shift(n.dx, n.dy);
      
      final padX = 8.0 / _currentScaleX;
      final padY = 4.0 / _currentScaleY;
      final bPadded = Box(b.left - padX, b.top - padY, b.right + padX, b.bottom + padY);

      final rx = dragRange(bPadded.left, bPadded.right, w);
      if (rx != null) {
        if (rx[0] > loX) loX = rx[0];
        if (rx[1] < hiX) hiX = rx[1];
      }
      final ry = dragRange(bPadded.top, bPadded.bottom, h);
      if (ry != null) {
        if (ry[0] > loY) loY = ry[0];
        if (ry[1] < hiY) hiY = ry[1];
      }
    }
    if (loX <= hiX) dx = dx.clamp(loX, hiX);
    if (loY <= hiY) dy = dy.clamp(loY, hiY);

    setState(() => _dragDelta = Offset(dx, dy));
  }

  @override
  Widget build(BuildContext context) {
    final playResX = _initialized ? _padded.playResX.toDouble() : 1920.0;
    final playResY = _initialized ? _padded.playResY.toDouble() : 1080.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LibAss Spike'),
        actions: [
          Row(
            children: [
              const Text('Draw Background'),
              Switch(
                value: _drawBackground,
                onChanged: (v) => setState(() => _drawBackground = v),
              ),
              const SizedBox(width: 12),
              const Text('Draw Window'),
              Switch(
                value: _drawWindow,
                onChanged: (v) => setState(() => _drawWindow = v),
              ),
              const SizedBox(width: 12),
              const Text('Show bounds'),
              Switch(
                value: _showBounds,
                onChanged: (v) => setState(() => _showBounds = v),
              ),
              const SizedBox(width: 12),
              const Text('Is Styled Track'),
              Switch(
                value: !_isDraggable, // If it IS styled, draggable is false
                onChanged: (val) {
                  setState(() => _isDraggable = !val);
                  _renderFrame(_currentTime);
                },
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.file_open),
            onPressed: () async {
              final result = await FilePicker.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['ass'],
              );
              if (result.isNotEmpty && result.single.path != null) {
                _loadAssFile(result.single.path!);
              }
            },
          )
        ],
      ),
      body: Column(
        children: [
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: Container(
              color: Colors.black,
              child: Center(
                child: AspectRatio(
                  aspectRatio: playResX / playResY,
                  child: Container(
                    color: Colors.white,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        _currentScaleX = constraints.maxWidth / playResX;
                        _currentScaleY = constraints.maxHeight / playResY;
                        final sx = _currentScaleX;
                        final sy = _currentScaleY;
                    
                        return GestureDetector(
                          onPanUpdate: _isDraggable ? _onPanUpdate : null,
                          onPanEnd: _isDraggable ? (_) => _commitDrag() : null,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              const Positioned.fill(
                                child: Center(
                                  child: Text('Video Area',
                                      style: TextStyle(
                                          color: Colors.white24, fontSize: 30)),
                                ),
                              ),
                              Positioned(
                                left: 16,
                                top: 16,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    _isDraggable
                                        ? 'Drag: Unlocked'
                                        : 'Drag: Locked (Styled)',
                                    style: TextStyle(
                                      color: _isDraggable
                                          ? Colors.greenAccent
                                          : Colors.redAccent,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                    
                              // The drag is one global, instantaneous offset. The
                              // clamps are per group and eased, so each caption
                              // settles on its own.
                              Positioned.fill(
                                child: Transform.translate(
                                  offset: Offset(
                                      _dragDelta.dx * sx, _dragDelta.dy * sy),
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      for (var g = 0; g < _groupBoxes.length; g++)
                                        _CaptionGroup(
                                          key: ValueKey(g),
                                          nudge: Offset(_nudgeFor(g).dx * sx,
                                              _nudgeFor(g).dy * sy),
                                          images: _currentImages.where((img) => img.group == g).toList(),
                                          sx: sx,
                                          sy: sy,
                                          drawBackground: _drawBackground,
                                          drawWindow: _drawWindow,
                                          groupBox: _groupBoxes[g],
                                          showBounds: _showBounds,
                                          isDraggable: _isDraggable,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: _togglePlay,
              ),
              Expanded(
                child: Slider(
                  value: _currentTime.clamp(0, _duration),
                  min: 0,
                  max: _duration,
                  onChanged: (val) {
                    setState(() {
                      _currentTime = val;
                      _lastElapsed = Duration.zero;
                    });
                    _renderFrame(val);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 16.0),
                child: Text('Time: ${_currentTime.toStringAsFixed(2)} s   '
                    'groups: ${_groupBoxes.length}   '
                    'clamped: ${_nudges.where((n) => n != Offset.zero).length}'),
              ),
            ],
          )
        ],
      ),
    );
  }

  /// Debug overlay: the true (unclipped) box libass now hands us, per group.
  Widget _boundsBox(Box b, double sx, double sy) => Positioned(
        left: b.left * sx,
        top: b.top * sy,
        width: b.width * sx,
        height: b.height * sy,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.cyanAccent, width: 1),
            ),
          ),
        ),
      );
}

/// One caption's images, offset by that caption's own clamp.
///
/// The clamp eases; the caption's pixels do not. A group that has just appeared
/// starts *at* its clamped position rather than sliding in from zero — that is
/// what `begin == end` on the first build buys. After the first build
/// [TweenAnimationBuilder] ignores `begin` and animates from wherever it is, so
/// a caption already on screen whose text reflows does slide.
class _BackgroundPainter extends CustomPainter {
  final List<Rect> lines;
  final Box windowBox;
  final double sx;
  final double sy;
  final bool drawBackground;
  final bool drawWindow;

  _BackgroundPainter({
    required this.lines,
    required this.windowBox,
    required this.sx,
    required this.sy,
    required this.drawBackground,
    required this.drawWindow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!drawBackground && !drawWindow) return;

    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    final path = Path();

    if (drawBackground) {
      for (final line in lines) {
        final scaledRect = Rect.fromLTRB(
          line.left * sx,
          line.top * sy,
          line.right * sx,
          line.bottom * sy,
        );
        final padded = Rect.fromLTRB(
          scaledRect.left - 8.0,
          scaledRect.top - 4.0,
          scaledRect.right + 8.0,
          scaledRect.bottom + 4.0,
        );
        path.addRRect(RRect.fromRectAndRadius(padded, const Radius.circular(4.0)));
      }
    }

    if (drawWindow) {
      final scaledWindow = Rect.fromLTRB(
        windowBox.left * sx,
        windowBox.top * sy,
        windowBox.right * sx,
        windowBox.bottom * sy,
      );
      final padded = Rect.fromLTRB(
        scaledWindow.left - 8.0,
        scaledWindow.top - 4.0,
        scaledWindow.right + 8.0,
        scaledWindow.bottom + 4.0,
      );
      path.addRRect(RRect.fromRectAndRadius(padded, const Radius.circular(4.0)));
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BackgroundPainter oldDelegate) => true;
}

class _CaptionGroup extends StatelessWidget {
  const _CaptionGroup({
    super.key,
    required this.nudge,
    required this.images,
    required this.sx,
    required this.sy,
    required this.drawBackground,
    required this.drawWindow,
    required this.groupBox,
    required this.showBounds,
    required this.isDraggable,
  });

  final Offset nudge;
  final List<SubtitleImage> images;
  final double sx;
  final double sy;
  final bool drawBackground;
  final bool drawWindow;
  final Box groupBox;
  final bool showBounds;
  final bool isDraggable;

  @override
  Widget build(BuildContext context) {
    final List<Rect> lineRects = [];
    if (images.isNotEmpty) {
      final sorted = List<SubtitleImage>.from(images)..sort((a, b) => a.y.compareTo(b.y));
      Rect currentLine = Rect.fromLTWH(sorted.first.x, sorted.first.y, sorted.first.w, sorted.first.h);
      
      for (int i = 1; i < sorted.length; i++) {
        final img = sorted[i];
        final rect = Rect.fromLTWH(img.x, img.y, img.w, img.h);
        final rectCenter = rect.top + rect.height / 2;
        if (rectCenter > currentLine.top && rectCenter < currentLine.bottom) {
          currentLine = currentLine.expandToInclude(rect);
        } else {
          lineRects.add(currentLine);
          currentLine = rect;
        }
      }
      lineRects.add(currentLine);
    }

    final children = <Widget>[
      if (drawBackground || drawWindow)
        Positioned.fill(
          child: CustomPaint(
            painter: _BackgroundPainter(
              lines: lineRects,
              windowBox: groupBox,
              sx: sx,
              sy: sy,
              drawBackground: drawBackground,
              drawWindow: drawWindow,
            ),
          ),
        ),
      if (showBounds)
        Positioned(
          left: groupBox.left * sx,
          top: groupBox.top * sy,
          width: groupBox.width * sx,
          height: groupBox.height * sy,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.cyanAccent, width: 1),
              ),
            ),
          ),
        ),
      for (final img in images)
        Positioned(
          left: img.x * sx,
          top: img.y * sy,
          width: img.w * sx,
          height: img.h * sy,
          child: RawImage(image: img.image, filterQuality: FilterQuality.high),
        ),
      if (isDraggable)
        Positioned(
          left: groupBox.left * sx,
          top: groupBox.top * sy,
          width: groupBox.width * sx,
          height: groupBox.height * sy,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: const SizedBox.expand(),
          ),
        ),
    ];

    return TweenAnimationBuilder<Offset>(
      tween: Tween<Offset>(begin: nudge, end: nudge),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (_, off, child) =>
          Transform.translate(offset: off, child: child),
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }
}

class _RawImage {
  final Uint8List pixels;
  final int w;
  final int h;
  final double x;
  final double y;
  final int type;
  const _RawImage(this.pixels, this.w, this.h, this.x, this.y, this.type);
}

class SubtitleImage {
  final ui.Image image;
  final double x;
  final double y;
  final double w;
  final double h;
  final int group;

  SubtitleImage({
    required this.image,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.group,
  });
}

const String _demoScript = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,2,2,10,10,10,1
Style: Title,Impact,120,&H0000FFFF,&H000000FF,&H00FFFFFF,&H80000000,1,0,0,0,100,100,5,0,1,5,0,5,10,10,10,1
Style: Karaoke,Comic Sans MS,80,&H0000FF00,&H00FFFFFF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,4,0,8,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:10.00,Title,,0,0,0,,{\t(0,2000,\frz360\c&HFF00FF&)\pos(960,300)}Advanced libass Rendering!
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,{\fad(500,500)\pos(960,600)}Smooth Alpha Fading In and Out
Dialogue: 0,0:00:02.00,0:00:10.00,Default,,0,0,0,,{\move(-200,800,2000,800)}Moving across the screen...
Dialogue: 0,0:00:03.00,0:00:08.00,Karaoke,,0,0,0,,{\k50}Ka{\k50}ra{\k50}o{\k50}ke {\k50}Ef{\k50}fect!
Dialogue: 0,0:00:04.00,0:00:10.00,Default,,0,0,0,,{\pos(400,900)\org(400,900)\t(\frz3600)}Spinning
Dialogue: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,{\blur15\pos(1500,900)}Gaussian Blur
''';
