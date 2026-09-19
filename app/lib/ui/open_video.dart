import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rpc/client.dart';
import '../domain/feed_item.dart';
import 'playback_controller.dart';
import 'player_shell.dart';
import 'queue_controller.dart';
import 'widgets/save_dialog.dart';

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
  String? params,
  String? title,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  // The container, not `ref`: the tile that was tapped can be gone by the time
  // the undo is pressed or the listener below fires, and a disposed `ref`
  // throws. The container is the app's and outlives every tile.
  final container = ProviderScope.containerOf(context, listen: false);
  final queue = container.read(queueProvider.notifier);
  // Read before the call, because starting the mix is what destroys it.
  final resumeAt = container.read(playbackProvider).item == null
      ? null
      : container.read(playbackProvider.notifier).currentPosition;

  // **Before the await, not after it.** `mix.start` is a ~0.5-1 s round trip,
  // and pushing the route only once it returned meant a click on a mix tile did
  // nothing visible for about a second — which reads as a dead click and gets
  // repeated. `startMix` empties the queue straight away, which stops the old
  // video, and the page draws a skeleton while `startingMixId` is set.
  showWatchPage(ref);

  try {
    await queue.startMix(playlistId, videoId: videoId, params: params);
  } on Object catch (e) {
    // `startMix` has already put the old queue back; this re-seeks it, so a
    // failed mix costs the user nothing but the message.
    if (resumeAt != null) container.read(playbackProvider.notifier).resumeAt(resumeAt);
    // Nothing was playing before, so nothing came back — and the watch page was
    // pushed on the tap. Leaving it up would strand the user on "Nothing
    // playing." with an error snackbar over it; take them back where they were.
    if (container.read(queueProvider).isEmpty) toMiniPlayerIn(container);
    final message = switch (e) {
      RpcException(code: 'AUTH_REQUIRED') => 'Sign in to play mixes',
      RpcException(:final message) => message,
      _ => 'Could not start this mix — $e',
    };
    messenger.showSnackBar(SnackBar(content: Text(message)));
    return;
  }

  if (!queue.canUndoStartMix) return;
  final snackBar = messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 5),
      // **Required, not redundant.** A snack bar with an action defaults to
      // `persist: true` (`persist ?? action != null` in the SDK), which ignores
      // `duration` entirely — so this one sat on screen until dismissed by hand.
      persist: false,
      content: Text(title == null ? 'Queue replaced by the mix' : 'Queue replaced by $title'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          queue.undoStartMix();
          if (resumeAt != null) container.read(playbackProvider.notifier).resumeAt(resumeAt);
        },
      ),
    ),
  );

  // Editing the mix commits to it, so the offer to undo it goes the moment the
  // user does — `QueueController._edit` drops the snapshot, and this notices.
  // Autoplay and the mix extending itself leave the snapshot alone, so they do
  // not dismiss it.
  final watch = container.listen(queueProvider, (_, _) {
    if (!queue.canUndoStartMix) snackBar.close();
  });
  unawaited(snackBar.closed.then((reason) {
    watch.close();
    // Gone without being pressed — timed out, or pushed off by another
    // message. The undo went with it; do not leave a snapshot nothing can use.
    if (reason != SnackBarClosedReason.action) queue.discardStartMixUndo();
  }));
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
    // The tile's own seed and params, so the mix opens on the song the tile
    // advertises rather than wherever YouTube chooses (protocol.md §3.3).
    return () => unawaited(startMixFromTile(
          context,
          ref,
          item.id,
          videoId: item.seedVideoId,
          params: item.startParams,
          title: item.title,
        ));
  }
  return watchTargetFor(item) == null ? null : () => openFromTile(ref, item);
}

/// Add to the queue from a tile, for the kinds that can be queued.
void queueFromTile(WidgetRef ref, FeedItem item) {
  final video = watchTargetFor(item);
  if (video == null) return;
  ref.read(queueProvider.notifier).addToQueue(video);
}

/// One entry of a tile's 3-dot menu.
class TileMenuItem {
  const TileMenuItem({required this.icon, required this.label, this.onPressed});

  final IconData icon;
  final String label;

  /// Null draws the entry disabled — present but not pressable — for an action
  /// this tile does not offer, so the menu keeps the same shape from tile to tile.
  final VoidCallback? onPressed;
}

/// The URL a tile shares, or null for a kind with none.
///
/// A mix is `watch?v=<seed>&list=<RD…>` when it has a seed and the bare playlist
/// otherwise — the same two shapes youtube.com hands out for one.
String? tileLinkFor(FeedItem item) {
  return item.map(
    video: (v) => 'https://www.youtube.com/watch?v=${v.id}',
    mix: (m) => m.seedVideoId == null
        ? 'https://www.youtube.com/playlist?list=${m.id}'
        : 'https://www.youtube.com/watch?v=${m.seedVideoId}&list=${m.id}',
    playlist: (p) => 'https://www.youtube.com/playlist?list=${p.id}',
    channel: (_) => null,
    unknown: (_) => null,
  );
}

/// The entries of a tile's 3-dot menu (`MediaTile.menu`).
///
/// `MediaTile.onMore` was wired to nothing from the day it was added (the
/// b2549cb review), so every 3-dot button in the app was drawn disabled. Each
/// entry here is a thing the app already does — the two hover buttons, the save
/// dialog Task 25 §5 said this menu opens, and a link — so nothing in it is a
/// stub. The two hover buttons hide when a tile cannot offer them; here they are
/// disabled instead, which is the same fact without a menu that reshuffles.
///
/// Only a video has anything to save or queue: a mix and a playlist are not
/// videos (`watchTargetFor`), so they get the link alone. A kind with no link
/// either gets an empty list and the button stays disabled.
List<TileMenuItem> tileMenuFor(
  BuildContext context,
  WidgetRef ref,
  FeedItem item, {
  required bool canWatchLater,
  required bool canAddToQueue,
}) {
  final link = tileLinkFor(item);
  if (link == null) return const [];

  final copyLink = TileMenuItem(
    icon: Icons.link,
    label: 'Copy link',
    onPressed: () => unawaited(copyToClipboard(context, link, 'Link copied')),
  );

  final video = watchTargetFor(item);
  if (video == null) return [copyLink];

  return [
    TileMenuItem(
      icon: Icons.schedule,
      label: 'Save to Watch Later',
      onPressed: canWatchLater ? () => unawaited(addToWatchLater(context, item)) : null,
    ),
    TileMenuItem(
      icon: Icons.playlist_add,
      label: 'Save to playlist…',
      onPressed: () => unawaited(showSaveDialog(context, video.id)),
    ),
    TileMenuItem(
      icon: Icons.playlist_play,
      label: 'Add to queue',
      onPressed: canAddToQueue ? () => queueFromTile(ref, item) : null,
    ),
    copyLink,
  ];
}

/// Puts [text] on the clipboard and says so.
Future<void> copyToClipboard(BuildContext context, String text, String said) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(SnackBar(content: Text(said)));
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
