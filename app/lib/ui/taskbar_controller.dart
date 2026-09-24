import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

import '../domain/video_detail.dart';
import 'account_actions.dart';
import 'auth_controller.dart';
import 'playback_controller.dart';
import 'queue_controller.dart';
import 'video_info.dart';

/// Everything the thumbnail toolbar shows except play/pause, which comes off the
/// engine's stream rather than a provider.
///
/// A record, so equality is by value and [taskbarControllerProvider]'s listener
/// fires only when something drawn on the toolbar actually changed — each
/// update is a round trip through the taskbar, so it is not done on every
/// rebuild of the providers underneath.
typedef _ToolbarModel = ({
  String videoId,
  bool hasPrevious,
  bool hasNext,
  bool liked,
  String? likeBlocker,
  VideoRating serverRating,
});

final _toolbarModelProvider = Provider<_ToolbarModel?>((ref) {
  final item = ref.watch(playbackProvider.select((p) => p.item));
  if (item == null) return null;
  final local = ref.watch(ratingActionsProvider.select((m) => m[item.id]));
  final server =
      ref.watch(videoInfoProvider(item.id)).value?.myRating ?? VideoRating.none;
  return (
    videoId: item.id,
    hasPrevious: ref.watch(queueProvider.select((q) => q.hasPrevious)),
    hasNext: ref.watch(queueProvider.select((q) => q.hasNext)),
    liked: (local ?? server) == VideoRating.like,
    likeBlocker: signedInActionBlocker(
      ref.watch(authProvider.select((a) => a.status)),
      'like videos',
    ),
    serverRating: server,
  );
});

/// Media buttons on the taskbar thumbnail's hover preview — previous,
/// play/pause, next and like — through `ITaskbarList3::ThumbBarAddButtons`.
///
/// Complements the system media flyout (`smtc_controller.dart`) rather than
/// replacing it: that one answers the keyboard's media keys, this one answers a
/// pointer on the taskbar, which is where a listener's hand is when the app is
/// behind other windows.
///
/// **No dislike.** It is used far less than like, and the toolbar is a strip of
/// small buttons where every one has to earn its place.
///
/// Every button goes through the same entry point as its on-screen counterpart
/// — `PlaybackController.previous`/`togglePlayPause`/`next` and [rateVideo] —
/// so the two can never disagree about what a press does.
///
/// Uses the vendored `third_party/windows_taskbar`; its two `rill patch` fixes
/// are what make updating this on every play/pause safe.
final taskbarControllerProvider = Provider<void>((ref) {
  if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST'))
    return;

  final engine = ref.read(playbackEngineProvider);

  /// What was last sent, so a sync that would draw the same toolbar is skipped.
  String? shown;
  var liking = false;
  var announced = false;

  // Loaded by path, so they must exist beside the executable — which is why
  // `assets/taskbar/` is declared in `pubspec.yaml` even though nothing loads
  // them through the asset bundle.
  ThumbnailToolbarAssetIcon icon(String name) =>
      ThumbnailToolbarAssetIcon('assets/taskbar/$name.ico');

  Future<void> like(_ToolbarModel model) async {
    if (liking) return;
    liking = true;
    try {
      final failure = await rateVideo(
        ref.read,
        model.videoId,
        VideoRating.like,
        serverRating: model.serverRating,
      );
      // Nowhere to show a snackbar from the taskbar. The store has already
      // been rolled back, so the button redraws un-liked; this says why.
      if (failure != null)
        stderr.writeln('rill: taskbar like failed: $failure');
    } finally {
      liking = false;
    }
  }

  Future<void> sync() async {
    final model = ref.read(_toolbarModelProvider);
    if (model == null) {
      if (shown != null) {
        shown = null;
        await WindowsTaskbar.resetThumbnailToolbar();
      }
      return;
    }
    final playing = engine.playing;
    final signature = '$model|$playing';
    if (signature == shown) return;
    shown = signature;

    final controller = ref.read(playbackProvider.notifier);
    try {
      await WindowsTaskbar.setThumbnailToolbar([
        ThumbnailToolbarButton(
          icon('previous'),
          'Previous',
          controller.previous,
          mode: model.hasPrevious ? 0 : ThumbnailToolbarButtonMode.disabled,
        ),
        ThumbnailToolbarButton(
          icon(playing ? 'pause' : 'play'),
          playing ? 'Pause' : 'Play',
          () => unawaited(controller.togglePlayPause()),
        ),
        ThumbnailToolbarButton(
          icon('next'),
          'Next',
          controller.next,
          mode: model.hasNext ? 0 : ThumbnailToolbarButtonMode.disabled,
        ),
        ThumbnailToolbarButton(
          icon(model.liked ? 'liked' : 'like'),
          // Disabled rather than hidden when signed out, with the reason as its
          // tooltip — the same treatment the watch page's own like button gets.
          model.likeBlocker ?? (model.liked ? 'Remove like' : 'Like'),
          () => unawaited(like(model)),
          mode: model.likeBlocker == null
              ? 0
              : ThumbnailToolbarButtonMode.disabled,
        ),
      ]);
      // Once, so a release log shows the toolbar exists at all — it lives in
      // Explorer's process and nothing inside this one can see it.
      if (!announced) {
        announced = true;
        stderr.writeln('rill: taskbar toolbar ready');
      }
    } on Object catch (e) {
      // Forgotten, so the next change retries instead of believing it drew.
      // The likeliest cause is a call before the taskbar button exists.
      shown = null;
      stderr.writeln('rill: taskbar toolbar update failed: $e');
    }
  }

  ref.listen(_toolbarModelProvider, (_, _) => unawaited(sync()));
  final playingSub = engine.playingStream.listen((_) => unawaited(sync()));
  ref.onDispose(() {
    unawaited(playingSub.cancel());
    unawaited(WindowsTaskbar.resetThumbnailToolbar());
  });
});
