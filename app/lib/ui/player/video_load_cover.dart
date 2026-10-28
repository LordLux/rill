import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/tokens.dart';
import '../audio_mode_controller.dart';
import '../playback_controller.dart';

const Key videoLoadCoverKey = ValueKey('video-load-cover');

/// The new video's thumbnail over the surface, from the moment another video is asked for until
/// the engine has a picture of it (`docs/todo.md` 105).
///
/// The shared texture keeps the last frame it was given and nothing clears it, so between a click
/// and the new video's first frame the surface shows the previous video: the engine is stopped at
/// the click now, and that blanks it on most clicks, but a frame or two of the old picture still
/// got through. The cover is the rest of the fix. It is the thumbnail rather than black because
/// that is what the tile the viewer clicked looked like.
///
/// **It comes off on the engine's own first-frame signal** (`videoOutputReady`, the property behind
/// `vo-configured`), not on a timer. There is one timer, a safety net: a picture that never
/// arrives must not leave a poster over a video that is in fact playing, so the cover comes off
/// 10 s after the open has ended whatever the signal says.
///
/// Not shown for audio-only (the artwork is already there), for a restore from it (the artwork
/// holds until the picture is back), or when there is an error slate. It has no semantics: the
/// image is excluded, and nothing here is an overlay under anything that mounts.
class VideoLoadCover extends ConsumerStatefulWidget {
  const VideoLoadCover({super.key});

  @override
  ConsumerState<VideoLoadCover> createState() => _VideoLoadCoverState();
}

class _VideoLoadCoverState extends ConsumerState<VideoLoadCover> {
  /// Set when a video starts loading, cleared by its first frame or the safety timer.
  bool _awaitingFrame = false;
  Timer? _safety;

  @override
  void initState() {
    super.initState();
    _awaitingFrame = ref.read(playbackProvider).isLoading;
  }

  @override
  void dispose() {
    _safety?.cancel();
    super.dispose();
  }

  void _loadingChanged(bool loading) {
    if (loading) {
      _safety?.cancel();
      setState(() => _awaitingFrame = true);
      return;
    }
    // The open has ended: if the picture is already there, done; else the signal or the net.
    if (ref.read(playbackEngineProvider).videoOutputReady) {
      setState(() => _awaitingFrame = false);
      return;
    }
    _safety?.cancel();
    _safety = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _awaitingFrame = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playbackProvider.select((p) => p.isLoading), (_, loading) => _loadingChanged(loading));
    final engine = ref.read(playbackEngineProvider);
    final item = ref.watch(playbackProvider.select((p) => p.item));
    final hasError = ref.watch(playbackProvider.select((p) => p.error != null));
    final restoring = ref.watch(playbackProvider.select((p) => p.isRestoringVideo));
    final audioOnly = ref.watch(audioModeProvider);
    if (item == null || hasError || restoring || audioOnly || !_awaitingFrame) return const SizedBox.shrink();

    return StreamBuilder<bool>(
      stream: engine.videoOutputStream,
      initialData: engine.videoOutputReady,
      builder: (context, snapshot) {
        final loading = ref.read(playbackProvider).isLoading;
        // Ready while still loading is the previous video's picture, not this one's.
        if (!loading && snapshot.data == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _awaitingFrame) setState(() => _awaitingFrame = false);
          });
          return const SizedBox.shrink();
        }
        final url = item.thumbnailUrl;
        return IgnorePointer(
          child: ColoredBox(
            key: videoLoadCoverKey,
            color: Theme.of(context).tokens.scrim,
            child: url.isEmpty
                ? const SizedBox.expand()
                : Image.network(
                    url,
                    fit: BoxFit.contain,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => const SizedBox.expand(),
                  ),
          ),
        );
      },
    );
  }
}
