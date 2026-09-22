import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The stand-in for the video texture while audio-only mode is on.
///
/// Audio-only toggles mpv's `vid` rather than reopening the media
/// (`architecture.md` §2.4), so the texture stays mounted and stays composited
/// — it simply decodes nothing. That makes this widget's *absence* silent and
/// wrong rather than loud: any surface that keeps calling
/// `engine.videoSurface()` in audio-only paints a black rectangle, not a
/// missing one. Fullscreen and the mini player both did exactly that.
class AudioArtSurface extends StatelessWidget {
  const AudioArtSurface({
    super.key,
    required this.thumbnailUrl,
    this.scrim = true,
    this.iconSize = 64,
  });

  final String? thumbnailUrl;

  /// Dims the art so controls drawn over it stay legible. Off for the mini
  /// player, which draws no controls over its 96x54 box and only goes muddy.
  final bool scrim;

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fallback = Center(
      child: Icon(
        Icons.music_note,
        size: iconSize,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );

    final url = thumbnailUrl;
    if (url == null || url.isEmpty) return fallback;

    return Stack(
      fit: StackFit.expand,
      children: [
        // `Image.network`, not the `DecorationImage` this replaced: that has
        // no `errorBuilder`, so a thumbnail that fails to load left an empty
        // box with nothing to fall back to. Every other thumbnail in the app
        // is loaded this way.
        Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
        if (scrim) DecoratedBox(decoration: BoxDecoration(color: theme.tokens.scrim.withValues(alpha: 0.6))),
      ],
    );
  }
}
