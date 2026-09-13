import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rpc/client.dart';
import '../domain/feed_item.dart';
import 'playback_controller.dart';
import 'player_shell.dart';
import 'queue_controller.dart';

/// What a tile tap means, per kind (task §6).
///
/// One function rather than a handler per surface, because the feed, the related
/// rail and the queue panel all draw the same tiles and must all behave the
/// same. Anything that cannot be watched is inert: no navigation, no error, no
/// dead route.
void openFromTile(WidgetRef ref, FeedItem item) {
  // A mix is not a video and does not go through `watchTargetFor` — it needs a
  // round trip before anything can play. `startMixFromTile` owns that, and the
  // surfaces that can show a snackbar call it directly so a failure and the
  // replaced-queue undo have somewhere to appear.
  if (item is MixItem) return;
  final video = watchTargetFor(item);
  if (video == null) return;
  openWatch(ref, video);
}

/// Start a mix from a tile — the feed and search entry point (§5).
///
/// **Both entry points land here**, this one and the watch page's own mix
/// offer, so "playing, with the queue filled and extensible" is one code path
/// rather than two that have to be kept agreeing.
///
/// Replaces the queue, with an undo (§3) — [QueueController.startMix] holds the
/// snapshot and this shows the snackbar for it. The undo restores the queue
/// *and* the playhead: a queue put back with its video restarted from zero is
/// not the queue the user had.
Future<void> startMixFromTile(
  BuildContext context,
  WidgetRef ref,
  String playlistId, {
  String? videoId,
  String? title,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final queue = ref.read(queueProvider.notifier);
  // Read before the call, because starting the mix is what destroys it.
  final resumeAt = ref.read(playbackProvider).item == null
      ? null
      : ref.read(playbackProvider.notifier).currentPosition;

  try {
    await queue.startMix(playlistId, videoId: videoId);
  } on RpcException catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to play mixes' : e.message)),
    );
    return;
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Could not start this mix — $e")));
    return;
  }

  showWatchPage(ref);

  if (!queue.canUndoStartMix) return;
  messenger.showSnackBar(
    SnackBar(
      // Explicit: the undo is a convenience, not a decision the user has to
      // make, so it should not sit on screen waiting for one.
      duration: const Duration(seconds: 5),
      content: Text(title == null ? 'Queue replaced by the mix' : 'Queue replaced by $title'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          queue.undoStartMix();
          if (resumeAt != null) ref.read(playbackProvider.notifier).resumeAt(resumeAt);
        },
      ),
    ),
  );
}

/// What tapping a tile should do, or null when nothing can happen.
///
/// **One handler for every surface**, for the reason `openFromTile` already
/// gives: the feed, search, the related rail and the artist panel all draw the
/// same tiles and must behave the same. A mix needs a `BuildContext` the other
/// kinds do not — its round trip can fail, and its queue replacement offers an
/// undo — which is the whole reason this exists alongside `openFromTile`
/// rather than inside it.
VoidCallback? tapHandlerFor(BuildContext context, WidgetRef ref, FeedItem item) {
  if (item is MixItem) {
    return () => unawaited(startMixFromTile(context, ref, item.id, title: item.title));
  }
  return watchTargetFor(item) == null ? null : () => openFromTile(ref, item);
}

/// Add to the queue from a tile, for the kinds that can be queued.
void queueFromTile(WidgetRef ref, FeedItem item) {
  final video = watchTargetFor(item);
  if (video == null) return;
  ref.read(queueProvider.notifier).addToQueue(video);
}

/// The tile's Watch Later button. Shared rather than duplicated per surface —
/// `FeedView` and the search results page's Shorts shelf both draw tiles with
/// this action. `AUTH_REQUIRED` gets its own line because "sign in" is
/// actionable and the raw envelope message is not.
Future<void> addToWatchLater(BuildContext context, FeedItem item) async {
  final target = watchTargetFor(item);
  if (target == null) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await RpcClient.instance.call('action.addToWatchLater', {'videoId': target.id});
    messenger.showSnackBar(const SnackBar(content: Text('Saved to Watch Later')));
  } on RpcException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to save to Watch Later' : e.message),
      ),
    );
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// The video a tile opens, or null if the tile is not watchable.
///
/// - `video` is itself.
/// - `mix` is **null here, deliberately** — a mix is a playlist, not a video,
///   and opening one needs a `mix.start` round trip. `startMixFromTile` is its
///   path. Until Task 26 this synthesised a `VideoItem` from a *derived* seed
///   id and played that one video, which is the half-built behaviour the task
///   existed to replace.
/// - `playlist` is explicitly out of scope and stays inert.
/// - `channel` and anything unknown have nothing to play.
VideoItem? watchTargetFor(FeedItem item) {
  return item.map(
    video: (v) => v,
    mix: (_) => null,
    playlist: (_) => null,
    channel: (_) => null,
    unknown: (_) => null,
  );
}

/// `mixSeedVideoId` lived here, and is gone (Task 26).
///
/// It derived a video id for a mix tile — from the `…/vi/<videoId>/…` in the
/// thumbnail URL, falling back to the 11 characters after `RD` — because
/// `MixItem` carries the `RD…` playlist id and no video id, and Task 21 needed
/// *something* to open. `mix.start` takes the playlist id directly, so nothing
/// needs the derivation any more and the DTO gap it worked around is no longer
/// a gap.
///
/// The one thing that went with it: a mix tile's hover preview, which used the
/// derived id as the video to play. A mix tile now shows its static thumbnail
/// on hover. That is the honest state of the contract — `MixItem` names no
/// video — and inventing one for a preview is the same workaround under a
/// different name.
