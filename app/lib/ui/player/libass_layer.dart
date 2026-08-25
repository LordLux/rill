import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/caption_style.dart';
import '../../domain/player_controls_visibility.dart';
import '../captions_controller.dart';
import '../playback_controller.dart';
import 'caption_geometry.dart';
import 'libass/ass_binding.dart';
import 'libass/ass_padding.dart';
import 'libass/caption_layout.dart';
import 'libass/ass_reposition.dart';

/// The background/window colour LibassLayer actually paints.
///
/// Both are client-only since phase 5 — the document carries no background or
/// window `Dialogue` any more, so there is no authored per-cue value to weigh
/// against the user's choice the way `ass.ts`'s text-colour force flags do.
/// `positional` (via [fallback]) is the closest thing to "the track's own
/// opinion" available here: `LibassLayer.build` passes a transparent
/// [fallback] for a positional track and YouTube's default box otherwise. So
/// "not forced" falls back to that rather than being a no-op — a track's
/// default still means something even though no per-cue value does.
Color _resolveOverlayColor(
  Color? user,
  Color fallback, {
  required bool forceColor,
  required bool forceOpacity,
}) {
  if (user == null) return fallback;
  return Color.from(
    alpha: forceOpacity ? user.a : fallback.a,
    red: forceColor ? user.r : fallback.r,
    green: forceColor ? user.g : fallback.g,
    blue: forceColor ? user.b : fallback.b,
  );
}

class _LibraryWrapper {
  final Pointer<ASS_Library> ptr;
  _LibraryWrapper(this.ptr);
}

class _RendererWrapper {
  final Pointer<ASS_Renderer> ptr;
  _RendererWrapper(this.ptr);
}

class _TrackWrapper {
  final Pointer<ASS_Track> ptr;
  _TrackWrapper(this.ptr);
}

class _RawImage {
  final TransferableTypedData pixels;
  final int w;
  final int h;
  final double x;
  final double y;
  final int type;

  _RawImage(this.pixels, this.w, this.h, this.x, this.y, this.type);
}

class _SubtitleImage {
  final ui.Image image;
  final double x;
  final double y;
  final double w;
  final double h;
  final int group;

  _SubtitleImage({
    required this.image,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.group,
  });
}

class LibassLayer extends ConsumerStatefulWidget {
  final double aspectRatio;
  const LibassLayer({super.key, required this.aspectRatio});

  @override
  ConsumerState<LibassLayer> createState() => _LibassLayerState();
}

class _LibassLayerState extends ConsumerState<LibassLayer> {
  LibAssBindings? _libass;
  _LibraryWrapper? _assLibrary;
  _RendererWrapper? _assRenderer;
  _TrackWrapper? _assTrack;

  String? _currentAss;
  String? _targetAss;
  String _rawAss = '';
  PaddedScript? _padded;

  double? _lastWidth;
  double? _lastHeight;
  double _targetTimeSeconds = 0;

  List<_SubtitleImage> _images = [];
  List<Box> _groupBoxes = const [];
  Offset _dragDelta = Offset.zero;
  List<Offset> _nudges = const [];
  
  bool _isCommittingDrag = false;
  final bool _showBounds = false;

  bool _needsRender = false;
  bool _disposed = false;
  Future<void>? _renderJob;
  StreamSubscription? _posSub;

  static const int kPadX = 960;
  static const int kPadY = 540;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(playbackEngineProvider).setSubtitleVisible(false);
    });
  }

  /// Whether `libass-9.dll` could not be opened. Tried once, never retried.
  ///
  /// **This layer is unconditional since phase 5**, so it mounts wherever
  /// `PlayerShell` does — including a `flutter test` process, which has no
  /// libmpv beside it and so no `libass-9.dll` on its search path. `dlopen`
  /// throwing out of `build()` there takes down the whole widget tree with an
  /// `ArgumentError`, which is how ~57 unrelated widget tests failed the first
  /// time the debug toggle came out. A missing renderer means no caption
  /// overlay; it must not mean no player.
  bool _assUnavailable = false;

  void _setupAss() {
    if (_assLibrary != null || _assUnavailable) return;

    final DynamicLibrary dylib;
    try {
      dylib = DynamicLibrary.open('libass-9.dll');
    } on Object catch (e) {
      _assUnavailable = true;
      debugPrint('LibassLayer: libass-9.dll unavailable, captions will not render ($e)');
      return;
    }
    _libass = LibAssBindings(dylib);

    final libPtr = _libass!.ass_library_init();
    if (libPtr == nullptr) return;
    _assLibrary = _LibraryWrapper(libPtr);
    
    final rendPtr = _libass!.ass_renderer_init(libPtr);
    if (rendPtr == nullptr) return;
    _assRenderer = _RendererWrapper(rendPtr);

    final defaultFont = 'Arial'.toNativeUtf8();
    final defaultFamily = 'Arial'.toNativeUtf8();
    _libass!.ass_set_fonts(rendPtr, defaultFont, defaultFamily, 1, nullptr, 1);
    malloc.free(defaultFont);
    malloc.free(defaultFamily);

    _posSub = ref.read(playbackEngineProvider).positionStream.listen((dur) {
      _scheduleRender(dur.inMicroseconds / 1000000.0);
    });
  }

  void _installScriptToC(String? raw) {
    if (raw == null) {
      debugPrint('LibassLayer: raw is null, freeing track');
      if (_assTrack != null) _libass!.ass_free_track(_assTrack!.ptr);
      _assTrack = null;
      _padded = null;
      _rawAss = '';
      return;
    }
    _rawAss = raw;
    debugPrint('LibassLayer: raw is not null, padding script');
    
    _padded = padScript(raw, padX: kPadX, padY: kPadY);
    
    _libass!.ass_set_margins(_assRenderer!.ptr, 0, 0, 0, 0);
    _libass!.ass_set_use_margins(_assRenderer!.ptr, 0);
    _libass!.ass_set_pixel_aspect(_assRenderer!.ptr, 1.0);

    debugPrint('LibassLayer: freeing old track before allocating new one');
    if (_assTrack != null) {
      _libass!.ass_free_track(_assTrack!.ptr);
      _assTrack = null;
    }

    debugPrint('LibassLayer: allocating new track');
    final trackPtr = _libass!.ass_new_track(_assLibrary!.ptr);
    if (trackPtr != nullptr) {
      debugPrint('LibassLayer: new track allocated, processing data');
      _assTrack = _TrackWrapper(trackPtr);
      final data = _padded!.source.toNativeUtf8();
      _libass!.ass_process_data(trackPtr, data, data.length);
      malloc.free(data);
    } else {
      debugPrint('LibassLayer: ass_new_track returned nullptr!');
    }
  }

  void _scheduleRender(double timeSeconds) {
    if (_disposed) return;
    _targetTimeSeconds = timeSeconds;
    _needsRender = true;
    if (_renderJob == null) {
      _renderJob = _renderLoop();
      _renderJob!.whenComplete(() {
        if (mounted) _renderJob = null;
      });
    }
  }

  Future<void> _renderLoop() async {
    try {
      while (_needsRender && !_disposed) {
        _needsRender = false;

        debugPrint('LibassLayer: _renderLoop starting. currentAss length: ${_currentAss?.length}, targetAss length: ${_targetAss?.length}');

        if (_currentAss != _targetAss) {
          _currentAss = _targetAss;
          debugPrint('LibassLayer: installing script to C');
          _installScriptToC(_currentAss);
        }

        if (_assRenderer == null || _assTrack == null || _padded == null || _lastWidth == null) {
          debugPrint('LibassLayer: skipping render. renderer: ${_assRenderer != null}, track: ${_assTrack != null}, padded: ${_padded != null}, lastWidth: $_lastWidth');
          continue;
        }

        final physWidth = _lastWidth! * (_padded!.frameWidth / _padded!.playResX);
        final physHeight = _lastHeight! * (_padded!.frameHeight / _padded!.playResY);
        
        _libass!.ass_set_frame_size(
          _assRenderer!.ptr,
          math.max(1, physWidth.toInt()),
          math.max(1, physHeight.toInt()),
        );
        
        final physPadX = _lastWidth! * (kPadX / _padded!.playResX);
        final physPadY = _lastHeight! * (kPadY / _padded!.playResY);
        final nowMs = (_targetTimeSeconds * 1000).toInt();

        final rendererAddr = _assRenderer!.ptr.address;
        final trackAddr = _assTrack!.ptr.address;

        final rawImages = await _runRenderIsolate(rendererAddr, trackAddr, nowMs, physPadX, physPadY);

        if (_disposed || !mounted) break;

        final sx = _lastWidth! / _padded!.playResX;
        final sy = _lastHeight! / _padded!.playResY;

        // Grouping boxes must be converted back to script space.
        final boxes = [for (final r in rawImages) Box(r.x / sx, r.y / sy, (r.x + r.w) / sx, (r.y + r.h) / sy)];
        final groups = groupImages([for (final r in rawImages) r.type]);
        final newBoxes = groupBoxes(boxes, groups);

        final newImages = <_SubtitleImage>[];
        for (int i = 0; i < rawImages.length; i++) {
          final raw = rawImages[i];
          final comp = Completer<ui.Image>();
          ui.decodeImageFromPixels(
            raw.pixels.materialize().asUint8List(),
            raw.w,
            raw.h,
            ui.PixelFormat.rgba8888,
            comp.complete,
          );
          newImages.add(_SubtitleImage(
            image: await comp.future,
            x: raw.x,
            y: raw.y,
            w: raw.w.toDouble(), // Already in physical screen pixels!
            h: raw.h.toDouble(), // Already in physical screen pixels!
            group: groups[i],
          ));
        }

        if (_disposed || !mounted) {
          for (final img in newImages) img.image.dispose();
          break;
        }

        final previous = _images;
        setState(() {
          final captions = ref.read(captionsProvider);
          final track = captions.tracks.where((t) => t.id == captions.selectedId).firstOrNull;
          final isDraggable = track == null || track.positional != true;

          _images = newImages;
          _groupBoxes = newBoxes;
          _nudges = isDraggable
              ? _computeNudges(newBoxes, nowMs)
              : List.filled(newBoxes.length, Offset.zero);
          if (_isCommittingDrag) {
            _dragDelta = Offset.zero;
            _isCommittingDrag = false;
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final i in previous) i.image.dispose();
        });
      }
    } catch (e, st) {
      debugPrint('LibassLayer _renderLoop error: $e\n$st');
    }
  }

  static Future<List<_RawImage>> _runRenderIsolate(int rendererPtr, int trackPtr, int nowMs, double padX, double padY) {
    return Isolate.run(() => _renderIsolate(rendererPtr, trackPtr, nowMs, padX, padY));
  }

  static List<_RawImage> _renderIsolate(int rendererPtr, int trackPtr, int nowMs, double padX, double padY) {
    final dylib = DynamicLibrary.open('libass-9.dll');
    final bindings = LibAssBindings(dylib);

    final renderer = Pointer<ASS_Renderer>.fromAddress(rendererPtr);
    final track = Pointer<ASS_Track>.fromAddress(trackPtr);
    
    final changePtr = malloc<Int32>();
    final imagePtr = bindings.ass_render_frame(renderer, track, nowMs, changePtr);
    malloc.free(changePtr);

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

        rawImages.add(_RawImage(
          TransferableTypedData.fromList([rgbaPixels]),
          img.w,
          img.h,
          (img.dst_x - padX).toDouble(),
          (img.dst_y - padY).toDouble(),
          img.type,
        ));
      }
      current = img.next;
    }
    
    return rawImages;
  }

  /// How much of the frame's bottom, in document (`PlayRes`) pixels, the
  /// visible control bar currently covers — 0 when it is hidden, or has not
  /// laid out yet.
  ///
  /// Read from the bar's own rendered size (`playerControlsBarKey`) rather
  /// than a guessed constant, because the bar's height differs between the
  /// windowed and fullscreen layouts and is not fixed even within one of
  /// them (the vertical layout's row wraps). Converted with the same `sy`
  /// this class already uses everywhere else, so it lines up with the boxes
  /// libass actually rendered rather than an independent estimate of them —
  /// the mistake `CaptionMetrics` was retired for (`architecture.md` §2.9).
  double get _reservedBottomDocPx {
    if (!ref.read(playerControlsVisibleProvider)) return 0;
    if (_lastHeight == null || _padded == null) return 0;
    final box = playerControlsBarKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return 0;
    final sy = _lastHeight! / _padded!.playResY;
    return box.size.height / sy;
  }

  List<Offset> _computeNudges(List<Box> boxes, int nowMs) {
    if (boxes.isEmpty) return const [];
    final h = _padded!.playResY - _reservedBottomDocPx;
    final out = List<Offset>.filled(boxes.length, Offset.zero);
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i].shift(_dragDelta.dx, _dragDelta.dy);
      final clamp = clampOffset(b, _padded!.playResX.toDouble(), h);
      out[i] = Offset(_dragDelta.dx + clamp[0], _dragDelta.dy + clamp[1]);
    }
    return out;
  }

  Offset _nudgeFor(int group) => group < _nudges.length ? _nudges[group] : Offset.zero;

  Offset get _largestNudge {
    var maxSq = -1.0;
    var largest = Offset.zero;
    for (final n in _nudges) {
      final d = n.dx * n.dx + n.dy * n.dy;
      if (d > maxSq) {
        maxSq = d;
        largest = n;
      }
    }
    return largest;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_groupBoxes.isEmpty || _padded == null || _lastWidth == null) return;
    
    final sx = _lastWidth! / _padded!.playResX;
    final sy = _lastHeight! / _padded!.playResY;

    var dx = _dragDelta.dx + details.delta.dx / sx;
    var dy = _dragDelta.dy + details.delta.dy / sy;

    // Same reservation `_computeNudges` applies passively on every render —
    // here so a live drag cannot be thrown past the bar either.
    final safeBottom = _padded!.playResY - _reservedBottomDocPx;

    var loX = double.negativeInfinity, hiX = double.infinity;
    var loY = double.negativeInfinity, hiY = double.infinity;
    for (var i = 0; i < _groupBoxes.length; i++) {
      final b = _groupBoxes[i];

      final padX = 8.0 / sx;
      final padY = 4.0 / sy;
      final bPadded = Box(b.left - padX, b.top - padY, b.right + padX, b.bottom + padY);

      loX = math.max(loX, -bPadded.left);
      hiX = math.min(hiX, _padded!.playResX - bPadded.right);
      loY = math.max(loY, -bPadded.top);
      hiY = math.min(hiY, safeBottom - bPadded.bottom);
    }

    if (dx < loX) dx = loX;
    if (dx > hiX) dx = hiX;
    if (dy < loY) dy = loY;
    if (dy > hiY) dy = hiY;

    setState(() {
      _dragDelta = Offset(dx, dy);
      _nudges = _computeNudges(_groupBoxes, 0);
    });
  }

  void _commitDrag() {
    final shift = _largestNudge;
    if (shift == Offset.zero) return;

    _targetAss = repositionScript(_rawAss, shift.dx, shift.dy);
    _isCommittingDrag = true;
    
    if (_padded != null) {
      final currentOffset = ref.read(captionsProvider).offset;
      final fracX = shift.dx / _padded!.playResX;
      final fracY = shift.dy / _padded!.playResY;
      unawaited(ref.read(captionsProvider.notifier).setOffset(
        CaptionOffset(currentOffset.dx + fracX, currentOffset.dy + fracY)
      ));
    }

    final engine = ref.read(playbackEngineProvider);
    _scheduleRender(engine.position.inMicroseconds / 1000000.0);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _disposed = true;

    final lib = _assLibrary;
    final rend = _assRenderer;
    final trk = _assTrack;
    final job = _renderJob;

    void freeC() {
      if (trk != null) _libass?.ass_free_track(trk.ptr);
      if (rend != null) _libass?.ass_renderer_done(rend.ptr);
      if (lib != null) _libass?.ass_library_done(lib.ptr);
    }

    if (job != null) {
      job.whenComplete(freeC);
    } else {
      freeC();
    }

    for (final i in _images) {
      i.image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_assLibrary == null) _setupAss();
    if (_assUnavailable) return const SizedBox.shrink();

    ref.watch(captionsProvider);
    // The render loop re-nudges on every position tick anyway, but a paused
    // video has no ticks — and the control bar can only ever come *back*
    // while paused (`_restartHideTimer` never hides it then), so without this
    // a caption revealed by that path would sit under the bar until the next
    // seek or play.
    ref.listen(playerControlsVisibleProvider, (previous, next) {
      if (previous != next) _scheduleRender(_targetTimeSeconds);
    });

    final engine = ref.read(playbackEngineProvider);
    debugPrint('LibassLayer build: engine.subtitle length: ${engine.subtitle?.length}, _currentAss length: ${_currentAss?.length}, _targetAss length: ${_targetAss?.length}, _isCommittingDrag: $_isCommittingDrag');
    if (engine.subtitle != _currentAss && !_isCommittingDrag && engine.subtitle != _targetAss) {
      _targetAss = engine.subtitle;
      _dragDelta = Offset.zero;
      _nudges = const [];
      _groupBoxes = const [];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scheduleRender(engine.position.inMicroseconds / 1000000.0);
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth == 0 || constraints.maxHeight == 0) return const SizedBox.shrink();
        
        final videoRect = videoRectIn(constraints.biggest, widget.aspectRatio);
        if (videoRect.width == 0 || videoRect.height == 0) return const SizedBox.shrink();

        if (_lastWidth != videoRect.width || _lastHeight != videoRect.height) {
          _lastWidth = videoRect.width;
          _lastHeight = videoRect.height;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scheduleRender(engine.position.inMicroseconds / 1000000.0);
          });
        }

        if (_padded == null) return const SizedBox.shrink();
        final sx = _lastWidth! / _padded!.playResX;
        final sy = _lastHeight! / _padded!.playResY;

        final captions = ref.read(captionsProvider);
        final track = captions.tracks.where((t) => t.id == captions.selectedId).firstOrNull;
        final isPositional = track?.positional == true;
        final isDraggable = !isPositional;
        
        final defaultBg = isPositional ? const Color(0x00000000) : captionDefaultBackground;
        final backgroundColor = _resolveOverlayColor(
          captions.style.background,
          defaultBg,
          forceColor: captions.style.forceBackgroundColor,
          forceOpacity: captions.style.forceBackgroundOpacity,
        );
        final windowColor = _resolveOverlayColor(
          captions.style.window,
          const Color(0x00000000),
          forceColor: captions.style.forceWindowColor,
          forceOpacity: captions.style.forceWindowOpacity,
        );

        return Stack(
          children: [
            Positioned.fromRect(
              rect: videoRect,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var g = 0; g < _groupBoxes.length; g++)
                    _CaptionGroup(
                      key: ValueKey(g),
                      nudge: Offset(_nudgeFor(g).dx * sx, _nudgeFor(g).dy * sy),
                      images: _images.where((i) => i.group == g).toList(),
                      sx: sx,
                      sy: sy,
                      backgroundColor: backgroundColor,
                      windowColor: windowColor,
                      groupBox: _groupBoxes[g],
                      showBounds: _showBounds,
                      onPanUpdate: isDraggable ? _onPanUpdate : null,
                      onPanEnd: isDraggable ? (_) => _commitDrag() : null,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CaptionGroup extends StatelessWidget {
  final Offset nudge;
  final List<_SubtitleImage> images;
  final double sx;
  final double sy;
  final Color backgroundColor;
  final Color windowColor;
  final Box groupBox;
  final bool showBounds;
  final void Function(DragUpdateDetails)? onPanUpdate;
  final void Function(DragEndDetails)? onPanEnd;

  const _CaptionGroup({
    super.key,
    required this.nudge,
    required this.images,
    required this.sx,
    required this.sy,
    required this.backgroundColor,
    required this.windowColor,
    required this.groupBox,
    required this.showBounds,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    final List<Rect> lineRects = [];
    if (images.isNotEmpty) {
      final sorted = List<_SubtitleImage>.from(images)..sort((a, b) => a.y.compareTo(b.y));
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

    return TweenAnimationBuilder<Offset>(
      tween: Tween<Offset>(begin: nudge, end: nudge),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (_, off, child) => Positioned(
        left: groupBox.left * sx + off.dx,
        top: groupBox.top * sy + off.dy,
        width: groupBox.width * sx,
        height: groupBox.height * sy,
        child: child!,
      ),
      child: MouseRegion(
        cursor: onPanUpdate != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: onPanUpdate,
          onPanEnd: onPanEnd,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (backgroundColor.a > 0 || windowColor.a > 0)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BackgroundPainter(
                      lines: lineRects,
                      windowBox: groupBox,
                      sx: sx,
                      sy: sy,
                      backgroundColor: backgroundColor,
                      windowColor: windowColor,
                    ),
                  ),
                ),
              if (showBounds)
                Positioned.fill(
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
                  // The image coordinates are ALREADY physical screen pixels. 
                  // We just offset them by the group box's top-left to place them correctly in this local Stack!
                  left: img.x - (groupBox.left * sx),
                  top: img.y - (groupBox.top * sy),
                  width: img.w,
                  height: img.h,
                  child: RawImage(image: img.image, filterQuality: FilterQuality.high),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws the per-line background and the window rectangle.
///
/// **`_verticalNudge` is a reported-not-measured correction.** Both boxes are
/// built from the exact same glyph boxes `RawImage` paints from — there is no
/// code path that can put them out of step with the text — so the fix for
/// "the background sits slightly low" cannot be a positioning bug in this
/// class as written; it is a small uniform shift applied on top. If it turns
/// out wrong or over/under-corrected, this constant is the one place to
/// change — it is not derived from anything and does not need to be.
class _BackgroundPainter extends CustomPainter {
  final List<Rect> lines;
  final Box windowBox;
  final double sx;
  final double sy;
  final Color backgroundColor;
  final Color windowColor;

  _BackgroundPainter({
    required this.lines,
    required this.windowBox,
    required this.sx,
    required this.sy,
    required this.backgroundColor,
    required this.windowColor,
  });

  /// A manual visual correction, not a measured one — see the class doc.
  static const double _verticalNudge = -3.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (backgroundColor.a == 0 && windowColor.a == 0) return;

    canvas.translate(0, _verticalNudge);
    final paint = Paint()..style = PaintingStyle.fill;
    final path = Path();

    if (backgroundColor.a > 0) {
      for (final line in lines) {
        // Translate the global physical coordinates into the local space of this CustomPaint
        final localLeft = line.left - (windowBox.left * sx);
        final localTop = line.top - (windowBox.top * sy);
        final localRight = line.right - (windowBox.left * sx);
        final localBottom = line.bottom - (windowBox.top * sy);

        final padded = Rect.fromLTRB(
          localLeft - 8.0,
          localTop - 4.0,
          localRight + 8.0,
          localBottom + 4.0,
        );
        path.addRRect(RRect.fromRectAndRadius(padded, const Radius.circular(4.0)));
      }
      paint.color = backgroundColor;
      canvas.drawPath(path, paint);
    }

    if (windowColor.a > 0) {
      final windowPath = Path();
      final scaledWindow = Rect.fromLTRB(0, 0, size.width, size.height);
      windowPath.addRect(scaledWindow);
      paint.color = windowColor;
      canvas.drawPath(windowPath, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BackgroundPainter oldDelegate) => true;
}