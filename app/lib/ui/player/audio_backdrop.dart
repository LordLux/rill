import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'audio_art_surface.dart';

/// The audio-only background: the artwork, heavily blurred, drifting slowly.
///
/// **The blur is the fix, not the image URL.** Measured 2026-09-22: YouTube
/// caps thumbnails at 1280x720, the watch page's related rail ships 480x360,
/// and for a square or vertical video that 4:3 frame is mostly baked-in black
/// bars — only a 360x360 crop is real picture, blown up ~3.3x at fullscreen.
/// No available URL fixes that. At these sigmas the source resolution stops
/// being legible at all, which is why a better poster is an improvement here
/// rather than the cure.
///
/// Drawn behind the now-playing content, so it is deliberately low-contrast:
/// anything that competes with the foreground is a bug, not a feature.
/// How long the artwork takes to give way to the video, and back.
///
/// Long enough to read as a transition rather than a flicker, short enough
/// that it is not a thing you wait through on a toggle you meant.
const Duration kAudioArtFade = Duration(milliseconds: 320);

/// The artwork, crossfaded over the video surface.
///
/// **It stays up for the whole restore, not just for audio-only.** The video
/// texture keeps the last frame decoded before `vid=no` and nothing clears it —
/// observed 2026-09-23 showing a frame roughly two minutes stale — so handing
/// the surface back the instant the toggle flips displays the wrong picture
/// until mpv catches up, which takes 2.9–8.0 s (`architecture.md` §2.4).
/// Holding the artwork until `isRestoringVideo` clears means the fade always
/// lands on a live frame.
///
/// The video surface underneath stays mounted throughout, so the texture keeps
/// decoding while this covers it — the fade is opacity only, never a remount.
class AudioArtOverlay extends StatelessWidget {
  const AudioArtOverlay({super.key, required this.show, required this.imageUrl});

  final bool show;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: kAudioArtFade,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        // The default sizes itself to the largest child, which collapses to
        // nothing while the outgoing artwork is fading against a shrunk
        // placeholder. Expanding both keeps it full-bleed for the whole fade.
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, ?current],
        ),
        child: show
            ? AudioBackdrop(key: const ValueKey('audio-art'), imageUrl: imageUrl)
            : const SizedBox.shrink(key: ValueKey('no-audio-art')),
      ),
    );
  }
}

class AudioBackdrop extends StatefulWidget {
  const AudioBackdrop({super.key, required this.imageUrl, this.child});

  final String? imageUrl;

  /// The now-playing content drawn over the backdrop.
  final Widget? child;

  @override
  State<AudioBackdrop> createState() => _AudioBackdropState();
}

class _AudioBackdropState extends State<AudioBackdrop>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Slow enough to read as drift rather than motion. A full there-and-back
  /// cycle is twice this.
  static const Duration _kDrift = Duration(seconds: 50);

  /// The image is oversized by this much so the drift never exposes an edge.
  static const double _kOverscan = 1.18;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _kDrift,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  /// **Stopped whenever nothing can see it.** `vsync` already parks the ticker
  /// when this subtree leaves the tree or its route is covered, but neither
  /// covers a minimised or backgrounded window — and audio-only is a mode
  /// people leave running for hours with the window somewhere else. An
  /// animation that keeps requesting frames there is a battery complaint with
  /// nothing on screen to show for it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!visible && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    final url = widget.imageUrl;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (url == null || url.isEmpty)
          ColoredBox(color: tokens.scrim)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              // Scaled to the surface so the mini-player-sized box and a
              // fullscreen one read the same, rather than one looking sharp
              // and the other smeared.
              final sigma = (constraints.biggest.shortestSide * 0.035).clamp(8.0, 30.0);
              return ClipRect(
                child: AnimatedBuilder(
                  animation: _controller,
                  // **Built once, not per frame.** The blurred image is the
                  // expensive part and it never changes; only the transform
                  // does, so it is passed as `child` and the `RepaintBoundary`
                  // lets the raster cache keep it across frames. Rebuilding it
                  // inside the builder would re-blur on every tick.
                  child: RepaintBoundary(
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: sigma,
                        sigmaY: sigma,
                        // Without this the blur samples transparent black past
                        // the edges and draws a dark vignette the drift then
                        // slides around.
                        tileMode: TileMode.clamp,
                      ),
                      child: AudioArtSurface(
                        thumbnailUrl: url,
                        scrim: false,
                        // The downscale is most of the blur, and caps the
                        // cost of a surface that stays up for a whole album.
                        // Kept well above the sigma's own reach: at 128 the
                        // upscale alone is ~12x at fullscreen, and blurring
                        // *that* flattened the art to one colour.
                        decodeWidth: 220,
                      ),
                    ),
                  ),
                  builder: (context, child) {
                    final t = Curves.easeInOut.transform(_controller.value);
                    return Transform.scale(
                      scale: _kOverscan,
                      child: Transform.translate(
                        offset: Offset(
                          (t - 0.5) * constraints.maxWidth * 0.06,
                          (0.5 - t) * constraints.maxHeight * 0.05,
                        ),
                        child: child,
                      ),
                    );
                  },
                ),
              );
            },
          ),
        // Darkest top and bottom, where the fullscreen header and the control
        // bar sit. Flat dimming would cost the art more than it buys them.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tokens.scrim.withValues(alpha: 0.50),
                tokens.scrim.withValues(alpha: 0.26),
                tokens.scrim.withValues(alpha: 0.66),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}
