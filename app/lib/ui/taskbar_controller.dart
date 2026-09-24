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
  bool loading,
  bool hasPrevious,
  bool hasNext,
  bool ratingKnown,
  bool liked,
  String? likeBlocker,
  VideoRating serverRating,
});

final _toolbarModelProvider = Provider<_ToolbarModel?>((ref) {
  final item = ref.watch(playbackProvider.select((p) => p.item));
  if (item == null) return null;
  final local = ref.watch(ratingActionsProvider.select((m) => m[item.id]));
  final info = ref.watch(videoInfoProvider(item.id));
  final server = info.value?.myRating ?? VideoRating.none;
  return (
    videoId: item.id,
    loading: ref.watch(playbackProvider.select((p) => p.isLoading)),
    hasPrevious: ref.watch(queueProvider.select((q) => q.hasPrevious)),
    hasNext: ref.watch(queueProvider.select((q) => q.hasNext)),
    // Until the watch page's data arrives, whether this video is already liked
    // is unknown, and a press could only guess which way to toggle. A failed
    // fetch counts as known (not liked) rather than disabling like for good.
    ratingKnown: info.hasValue || info.hasError || local != null,
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
/// **While a video loads, play and like are disabled; previous and next are
/// not.** Skipping through tracks without waiting for each to load is exactly
/// what those two are for, and a load that never finishes must not trap the
/// listener on it. They are disabled only at the ends of the queue. A disabled
/// button keeps its ordinary icon: Windows dims it, and dedicated faded icons
/// on top of that were too faint to read (the `*_disabled` SVGs are kept, and
/// unused).
///
/// Every button goes through the same entry point as its on-screen counterpart
/// — `PlaybackController.previous`/`togglePlayPause`/`next` and [rateVideo] —
/// so the two can never disagree about what a press does.
///
/// **The buttons are added at startup and never removed; with nothing playing
/// they are all disabled.** A thumbnail flyout that was opened before the
/// buttons were first added keeps showing none, however many adds and updates
/// follow — measured 2026-09-24: hover the taskbar, then play, and the flyout
/// stayed empty until something re-laid out the taskbar. Adding them only once
/// something played made that the ordinary first experience.
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

  Timer? retry;
  var failures = 0;

  Future<void> sync() async {
    final model = ref.read(_toolbarModelProvider);
    final playing = model != null && engine.playing;
    final signature = '$model|$playing';
    if (signature == shown) return;
    shown = signature;

    // Nothing playing is four disabled buttons, never none — see the note on
    // [taskbarControllerProvider].
    final canPrevious = model != null && model.hasPrevious;
    final canNext = model != null && model.hasNext;
    final controller = ref.read(playbackProvider.notifier);
    try {
      await WindowsTaskbar.setThumbnailToolbar([
        ThumbnailToolbarButton(
          icon('previous'),
          'Previous',
          controller.previous,
          mode: canPrevious ? 0 : ThumbnailToolbarButtonMode.disabled,
        ),
        if (model == null || model.loading)
          ThumbnailToolbarButton(
            icon('play'),
            model == null ? 'Play' : 'Loading',
            () {},
            mode: ThumbnailToolbarButtonMode.disabled,
          )
        else
          ThumbnailToolbarButton(
            icon(playing ? 'pause' : 'play'),
            playing ? 'Pause' : 'Play',
            () => unawaited(controller.togglePlayPause()),
          ),
        ThumbnailToolbarButton(
          icon('next'),
          'Next',
          controller.next,
          mode: canNext ? 0 : ThumbnailToolbarButtonMode.disabled,
        ),
        if (model == null || model.likeBlocker != null || !model.ratingKnown)
          ThumbnailToolbarButton(
            icon('like'),
            // Signed out, it says why — the same treatment the watch page's own
            // like button gets.
            model == null ? 'Like' : model.likeBlocker ?? 'Loading',
            () {},
            mode: ThumbnailToolbarButtonMode.disabled,
          )
        else
          ThumbnailToolbarButton(
            icon(model.liked ? 'liked' : 'like'),
            model.liked ? 'Remove like' : 'Like',
            () => unawaited(like(model)),
          ),
      ]);
      failures = 0;
      // Once, so a release log shows the toolbar exists at all — it lives in
      // Explorer's process and nothing inside this one can see it.
      if (!announced) {
        announced = true;
        stderr.writeln('rill: taskbar toolbar ready');
      }
    } on Object catch (e) {
      // Forgotten, so the retry sends it again instead of believing it drew.
      // Expected once at startup: the first call can land before the window is
      // shown or its taskbar button exists. Retried on a timer rather than on
      // the next change, because with nothing playing there may be no next
      // change, and the buttons have to exist before the first hover.
      shown = null;
      failures++;
      // Not the first: that one is the startup race, on every launch, and a
      // line printed every time teaches the reader to skip it.
      if (failures == 3 || failures == 15)
        stderr.writeln('rill: taskbar toolbar update failed (attempt $failures): $e');
      if (failures < 15)
        retry ??= Timer(const Duration(seconds: 2), () {
          retry = null;
          unawaited(sync());
        });
    }
  }

  ref.listen(_toolbarModelProvider, (_, _) => unawaited(sync()));
  final playingSub = engine.playingStream.listen((_) => unawaited(sync()));
  unawaited(sync());
  ref.onDispose(() {
    retry?.cancel();
    unawaited(playingSub.cancel());
    unawaited(WindowsTaskbar.resetThumbnailToolbar());
  });
});
