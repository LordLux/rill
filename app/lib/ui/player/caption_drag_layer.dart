/// Drag the caption anywhere in the player — Task 19.
///
/// **What is dragged is not the caption.** libass composites the real one into
/// the video texture and media_kit exposes no separate surface, so there is
/// nothing on the Flutter side to move (`architecture.md` §2.9, Decision 1). The
/// gesture moves a **ghost** — one line of already-known text, drawn here, for
/// the duration of the gesture only — while the real caption stays exactly where
/// it is. On release the delta is committed, the sidecar regenerates the
/// document, `sub-add` replaces it, and the ghost disappears.
///
/// That is worth naming plainly so nobody mistakes it for a second caption
/// renderer arriving by the back door. It renders one string at a known size,
/// and it is never on screen at the same time as the caption it stands in for.
///
/// Three things fall out of dragging a ghost rather than the real thing, and all
/// three are the reason for it:
///
///  - **Smoothness is a property, not a target.** libass and the FFI boundary
///    are out of the loop for the whole gesture.
///  - **The text cannot reflow underneath the cursor.** Re-rendering mid-drag
///    would re-wrap lines as the available width changed, so the caption would
///    change shape while being moved.
///  - **The hover cursor is a `MouseRegion`** over the same rectangle, and that
///    is the entire implementation of it.
///
/// The fourth thing is the cost: the rectangle is an *estimate*
/// (`caption_geometry.dart`), so the clamp stops the drag a few pixels short of
/// a corner rather than exactly at it. That is the direction it is biased in on
/// purpose.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/caption_style.dart';
import '../captions_controller.dart';
import '../playback_controller.dart';
import 'caption_geometry.dart';

/// The invisible grab handle, for the widget test that has to find it.
const Key captionDragHandleKey = ValueKey('caption-drag-handle');

/// The ghost, which exists only while a drag is in progress.
const Key captionDragGhostKey = ValueKey('caption-drag-ghost');

class CaptionDragLayer extends ConsumerStatefulWidget {
  const CaptionDragLayer({super.key, required this.aspectRatio});

  /// The decoded stream's aspect ratio. The caption belongs to the *picture*,
  /// and the picture is letterboxed inside this widget, so a handle placed
  /// against the widget's own bounds drifts on everything but a 16:9 window.
  final double aspectRatio;

  @override
  ConsumerState<CaptionDragLayer> createState() => _CaptionDragLayerState();
}

class _CaptionDragLayerState extends ConsumerState<CaptionDragLayer> {
  /// Where the ghost is, relative to the committed offset. Null when not dragging.
  CaptionOffset? _dragging;

  /// The offset the gesture started from, so an update is absolute rather than
  /// accumulated — accumulating drifts once the clamp starts refusing movement.
  CaptionOffset _origin = CaptionOffset.zero;

  @override
  Widget build(BuildContext context) {
    final captions = ref.watch(captionsProvider);
    final layout = captions.layout;
    if (!captions.isOn || layout == null || captions.metrics == null) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<String?>(
      stream: ref.read(playbackEngineProvider).subtitleTextStream,
      builder: (context, snapshot) {
        final text = snapshot.data;
        if (text == null) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, constraints) {
            final video = videoRectIn(constraints.biggest, widget.aspectRatio);
            final offset = _dragging ?? captions.offset;
            final rect = captionRect(
              text: text,
              layout: layout,
              metrics: captions.metrics,
              offset: offset,
              video: video,
            );
            if (rect == null) return const SizedBox.shrink();

            return Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: _handle(
                    context: context,
                    text: text,
                    layout: layout,
                    metrics: captions.metrics!,
                    video: video,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// The grab handle, and — while a drag is running — the ghost inside it.
  ///
  /// Sized to the estimated rectangle and nothing more, so it intercepts the
  /// pointer over the caption and nowhere else. A full-surface `Listener` would
  /// swallow every click the player's own controls need.
  Widget _handle({
    required BuildContext context,
    required String text,
    required CaptionLayout layout,
    required CaptionMetrics metrics,
    required Rect video,
  }) {
    final captions = ref.read(captionsProvider);
    final size = captionSize(text: text, layout: layout, metrics: metrics);

    return MouseRegion(
      cursor: _dragging == null ? SystemMouseCursors.grab : SystemMouseCursors.grabbing,
      child: GestureDetector(
        key: captionDragHandleKey,
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          setState(() {
            _origin = ref.read(captionsProvider).offset;
            _dragging = _origin;
          });
        },
        onPanUpdate: (details) {
          // The incremental delta, not `localPosition`: the handle moves with
          // the ghost, so a position measured against it would fight itself.
          // Screen pixels become fractions of the *video* rectangle, which is
          // what makes the result survive a resize or a switch to fullscreen.
          final from = _dragging ?? _origin;
          setState(() {
            _dragging = clampedOffset(
              proposed: CaptionOffset(
                from.dx + details.delta.dx / video.width,
                from.dy + details.delta.dy / video.height,
              ),
              captionSize: size,
              layout: layout,
              alignment: layout.defaultAlignment,
            );
          });
        },
        onPanEnd: (_) {
          final committed = _dragging;
          setState(() => _dragging = null);
          if (committed != null) {
            unawaited(ref.read(captionsProvider.notifier).setOffset(committed));
          }
        },
        child: _dragging == null
            ? const SizedBox.expand()
            : _Ghost(
                text: text,
                layout: layout,
                background: captions.style.background ?? captionDefaultBackground,
                textColor: captions.style.textColor ?? captionWhite,
                scale: video.height / layout.playResY,
              ),
      ),
    );
  }
}

/// The thing that actually moves under the cursor.
///
/// A deliberately plain rendering: the box, the words, the size. It is not
/// trying to be a faithful preview of a styled caption, because it is on screen
/// for the length of a gesture and the real one lands on release.
class _Ghost extends StatelessWidget {
  const _Ghost({
    required this.text,
    required this.layout,
    required this.background,
    required this.textColor,
    required this.scale,
  });

  final String text;
  final CaptionLayout layout;
  final Color background;
  final Color textColor;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: captionDragGhostKey,
      alignment: Alignment.center,
      color: background,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: layout.fontFamily,
          fontSize: layout.fontSize * scale,
          height: layout.lineSpacing,
          color: textColor,
        ),
      ),
    );
  }
}
