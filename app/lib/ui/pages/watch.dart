import 'dart:async';
import 'dart:math' as math;

import 'package:async/async.dart' show StreamGroup;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';
import '../../data/rpc/client.dart';
// `Chip` here is Material's. The domain's `Chip` is the feed's filter strip and
// has no business on this page — hidden rather than aliased so a later edit that
// reaches for one gets an error instead of the wrong class.
import '../../domain/feed_item.dart' hide Chip;
import '../../domain/video_detail.dart';
import '../../theme/tokens.dart';
import '../open_video.dart';
import '../page_wrapper.dart';
import '../playback_controller.dart';
import '../player/controls.dart';
import '../player/view_mode.dart';
import '../queue_controller.dart';
import '../video_info.dart';
import '../widgets/media_tile.dart';
import '../widgets/queue_panel.dart';

const Key premiereSlateKey = ValueKey('premiere-slate');
const Key premiereNotifyKey = ValueKey('premiere-notify');

final _aspectRatioProvider = StreamProvider.autoDispose<double>((ref) async* {
  final engine = ref.watch(playbackEngineProvider);
  double currentRatio() {
    if (engine.width != null && engine.height != null && engine.height! > 0) {
      return engine.width! / engine.height!;
    }
    return 16 / 9;
  }

  yield currentRatio();

  final merged = StreamGroup.merge<int?>([engine.widthStream, engine.heightStream]);
  await for (final _ in merged) {
    yield currentRatio();
  }
});

/// The watch page (task §3).
///
/// It renders **whatever the queue is pointing at**, rather than a video handed
/// to it as a constructor argument. That is what makes "tapping a related tile
/// replaces the current video without pushing a second watch route" fall out for
/// free: the tap moves the queue's cursor, the cursor is what this page watches,
/// and the route never changes.
class WatchPage extends ConsumerStatefulWidget {
  const WatchPage({super.key});

  @override
  ConsumerState<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends ConsumerState<WatchPage> {
  bool _descriptionExpanded = false;

  /// Related pages fetched beyond the one `video.info` already returned.
  final List<FeedItem> _extraRelated = [];
  String? _relatedContinuation;
  bool _loadingRelated = false;
  String? _loadedRelatedFor;

  @override
  Widget build(BuildContext context) {
    // A related tap swaps the video under this page without a route change, so
    // the rail's own paging state has to be reset by the video changing rather
    // than by the page being built.
    ref.listen(queueProvider.select((q) => q.current?.id), (previous, next) {
      if (previous == next || next == null) return;
      setState(() {
        _loadedRelatedFor = next;
        _extraRelated.clear();
        _relatedContinuation = null;
        _descriptionExpanded = false;
        _loadingRelated = false;
      });
    });

    final playback = ref.watch(playbackProvider);
    final item = ref.watch(queueProvider.select((q) => q.current)) ?? playback.item;

    if (item == null)
      return const PageWrapper(
        title: Text('Watch'),
        body: Center(child: Text('Nothing playing.')),
      );

    _loadedRelatedFor ??= item.id;
    final info = ref.watch(videoInfoProvider(item.id));

    return PageWrapper(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BackButton(onPressed: () => Navigator.of(context).maybePop()),
          Text(
            'Watch',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Queue',
          mouseCursor: SystemMouseCursors.click,
          icon: const Icon(Icons.queue_music),
          onPressed: () => showQueuePanel(context),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final theatre = ref.watch(playerViewProvider.select((view) => view.theatre));
          final detail = info.value;
          final actualAspectRatio = ref.watch(_aspectRatioProvider).value ?? (16 / 9);
          final targetAspectRatio = math.max(16 / 9, actualAspectRatio);

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: targetAspectRatio),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, aspectRatio, _) {
              double railWidth = 0;
              double mainContainerWidth = constraints.maxWidth;
              final isDesktop = constraints.maxWidth >= 889;

              if (isDesktop) {
                final effectiveWidth = math.min(constraints.maxWidth, 2105.0);
                if (effectiveWidth >= 1042.0) {
                  railWidth = 453.0;
                } else {
                  railWidth = math.max(300.0, effectiveWidth - 589.0);
                }
                mainContainerWidth = effectiveWidth - railWidth;
              }

              final viewportHeight = MediaQuery.of(context).size.height;
              final maxPlayerHeight = math.max(480.0, viewportHeight - 169.0);
              final minPlayerHeight = isDesktop ? 480.0 : 0.0;

              final maxPlayerWidth = maxPlayerHeight * aspectRatio;
              if (mainContainerWidth > maxPlayerWidth + 16.0) {
                mainContainerWidth = maxPlayerWidth + 16.0;
              }

              // Theatre takes the whole content width, so there is nothing left to
              // put a rail beside. It drops to the one-column layout regardless of
              // how wide the window is, and the rail moves below the player.
              final wide = isDesktop && !theatre;

              // **Theatre grows sideways only.** The box keeps the height it has in
              // the ordinary layout and spans the full content width, so a 16:9
              // video gains side bars rather than a taller picture. Computed from
              // the width the player *would* have without theatre — which is why the
              // rail's width is subtracted here whether or not the rail is currently
              // drawn: in theatre it is not, and taking the current width would make
              // the box grow every time it was entered.
              final normalPlayerWidth = mainContainerWidth - 16;
              final theatreHeight = math.max(minPlayerHeight, math.min(normalPlayerWidth / aspectRatio, maxPlayerHeight));

              final main = SilkyListView(
                padding: EdgeInsets.zero,
                children: [
                  // **Theatre**: the player spans the app's content area edge to
                  // edge at the height it already had, the chrome stays, and the OS
                  // window is untouched. A layout change and nothing more — which is
                  // the whole difference from fullscreen.
                  if (theatre)
                    SizedBox(
                      height: theatreHeight,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: actualAspectRatio,
                          child: _PlayerSurface(playback: playback, rounded: false),
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: minPlayerHeight,
                          maxHeight: maxPlayerHeight,
                        ),
                        child: AspectRatio(
                          aspectRatio: aspectRatio, // targetAspectRatio (animated)
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: actualAspectRatio,
                              child: _PlayerSurface(playback: playback),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Meta(item: item, info: info),
                        const SizedBox(height: 12),
                        _Actions(item: item),
                        const SizedBox(height: 16),
                        if (detail != null)
                          _Description(
                            detail: detail,
                            expanded: _descriptionExpanded,
                            onToggle: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
                          ),
                        if (!wide) ...[
                          const SizedBox(height: 24),
                          ..._relatedSection(detail, item.id, asGrid: true),
                        ],
                      ],
                    ),
                  ),
                ],
              );

              if (!wide) return main;

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: mainContainerWidth,
                    child: main,
                  ),
                  SizedBox(
                    key: const ValueKey('related-rail'),
                    width: railWidth,
                    child: SilkyListView(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 32),
                      children: _relatedSection(detail, item.id),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  List<Widget> _relatedSection(VideoDetail? detail, String videoId, {bool asGrid = false}) {
    final scheme = Theme.of(context).colorScheme;
    if (detail == null) return const [];

    final items = [...detail.related, ..._extraRelated];
    final continuation = _relatedContinuation ?? detail.relatedContinuation;

    final header = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        'Related',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: scheme.onSurface),
      ),
    );

    final showMore = continuation != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 24),
              child: TextButton(
                onPressed: _loadingRelated ? null : () => _loadMoreRelated(videoId, continuation),
                child: Text(_loadingRelated ? 'Loading…' : 'Show more'),
              ),
            ),
          )
        : const SizedBox.shrink();

    if (asGrid) {
      return [
        header,
        LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = constraints.maxWidth >= 600 ? 2 : 1;
            if (crossAxisCount == 1) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final related in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _relatedTile(related),
                    ),
                ],
              );
            }

            return Wrap(
              spacing: 16,
              runSpacing: 24,
              children: [
                for (final related in items)
                  SizedBox(
                    width: ((constraints.maxWidth - 16) / 2).floorToDouble(),
                    child: _relatedTile(related),
                  ),
              ],
            );
          },
        ),
        showMore,
      ];
    }

    return [
      header,
      for (final related in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _relatedTile(related),
        ),
      showMore,
    ];
  }

  Widget _relatedTile(FeedItem related) {
    final spec = specFor(related);
    if (spec == null) return const SizedBox.shrink();
    return MediaTile(
      spec: spec,
      // No route push: this replaces the video on the page it is already on.
      onTap: () => openFromTile(ref, related),
      onAddToQueue: () => queueFromTile(ref, related),
      onWatchLater: () => _addToWatchLater(watchTargetFor(related)?.id),
    );
  }

  Future<void> _loadMoreRelated(String videoId, String continuation) async {
    setState(() => _loadingRelated = true);
    try {
      final page = await fetchRelated(videoId, continuation: continuation);
      if (!mounted) return;
      setState(() {
        _extraRelated.addAll(page.items);
        _relatedContinuation = page.continuation;
      });
    } on Object catch (e) {
      if (!mounted) return;
      _toast('Could not load more: $e');
    } finally {
      if (mounted) setState(() => _loadingRelated = false);
    }
  }

  Future<void> _addToWatchLater(String? videoId) async {
    if (videoId == null) return;
    try {
      await RpcClient.instance.call('action.addToWatchLater', {'videoId': videoId});
      _toast('Saved to Watch Later');
    } on RpcException catch (e) {
      _toast(e.code == 'AUTH_REQUIRED' ? 'Sign in to save to Watch Later' : e.message);
    } on Object catch (e) {
      _toast('$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The video, or whatever is standing in for it.
///
/// The surface belongs to the shell's engine — the player is not created here,
/// it is rendered here, and the same texture renders in the mini-player once
/// this route is popped. On a fake engine (tests) the surface is a placeholder,
/// which is the point of the engine being an interface.
class _PlayerSurface extends ConsumerWidget {
  const _PlayerSurface({required this.playback, this.rounded = true, this.actualAspectRatio});

  final PlaybackState playback;

  /// Theatre runs the player to the edges of the content area, where a rounded
  /// corner reads as a mistake rather than as a card.
  final bool rounded;

  /// The decoded aspect ratio of the stream. When non-null, centers and constrains
  /// the video texture to this ratio inside the outer player box while keeping
  /// controls and scrim full-width.
  final double? actualAspectRatio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final engine = ref.read(playbackEngineProvider);
    final fullscreen = ref.watch(playerViewProvider.select((view) => view.fullscreen));
    final ratio = actualAspectRatio ?? ref.watch(_aspectRatioProvider).value ?? (16 / 9);

    final content = ColoredBox(
      color: theme.tokens.scrim,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The shell's surface, mounted here. Popping back to the feed moves
          // this same texture into the mini-player — nothing is created or freed
          // by the move.
          //
          // **One mount point at a time.** While fullscreen the shell draws it
          // instead, so this box goes empty rather than asking for a second
          // `Video` on the same texture id. The box itself stays, which is what
          // keeps the page from reflowing behind the fullscreen layer.
          if (!fullscreen)
            Center(
              child: AspectRatio(
                aspectRatio: ratio,
                child: engine.videoSurface(),
              ),
            ),
          if (playback.isLoading) Center(child: CircularProgressIndicator(color: scheme.onPrimary)),
          // A premiere is not a failure, so it does not get the failure screen.
          if (playback.isUpcoming) _PremiereSlate(playback: playback) else if (playback.error != null) _Unavailable(playback: playback),

          if (playback.error == null && !playback.isLoading && !fullscreen) PlayerControls(engine: engine),
        ],
      ),
    );

    if (!rounded) return content;
    return ClipRRect(borderRadius: BorderRadius.circular(11), clipBehavior: Clip.antiAliasWithSaveLayer, child: content);
  }
}

/// A video that has not premiered yet.
///
/// **The thumbnail, the date, and a reminder — not an error.** `playback.open`
/// answers `VIDEO_UPCOMING` for these, and before this they landed on
/// "This video would not open" above a *Try again* button that could only fail
/// for another nine days. Nothing is wrong with the video; it has a start time.
///
/// The exact time comes from `video.info` (`premiereAtMs`), which the page
/// already fetches. When that has not arrived — or a layout hid it — the slate
/// falls back to YouTube's own prose, which rides along on the error message
/// ("Premieres in 9 days"). One of the two is always present, and the fallback
/// is the reason this does not wait on `video.info` before drawing.
class _PremiereSlate extends ConsumerWidget {
  const _PremiereSlate({required this.playback});

  final PlaybackState playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.tokens;
    final item = playback.item;
    final detail = item == null ? null : ref.watch(videoInfoProvider(item.id)).value;
    final premiereAt = detail?.premiereAtMs;
    final thumbnailUrl = item?.thumbnailUrl;

    return Stack(
      key: premiereSlateKey,
      fit: StackFit.expand,
      children: [
        // The thumbnail YouTube shows in place of the video. `contain` rather
        // than `cover`: a 16:9 thumbnail in a 16:9 box is the same either way,
        // and anything else loses its edges rather than its bars.
        if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) Image.network(thumbnailUrl, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
        // Enough scrim at the bottom to read the text off any thumbnail, and
        // none at the top — the same shape as the control bar's.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                tokens.scrim.withValues(alpha: 0.75),
                tokens.scrim.withValues(alpha: 0),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Premiere',
                  style: TextStyle(
                    color: tokens.onScrim.withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  premiereText(premiereAt, playback.error),
                  style: TextStyle(
                    color: tokens.onScrim,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                // Disabled, like the captions button: the affordance is real,
                // the reminder is not wired to YouTube yet, and a button that
                // looks like it worked and did nothing is the worse of the two.
                FilledButton.icon(
                  key: premiereNotifyKey,
                  onPressed: null,
                  icon: const Icon(Icons.notifications_none, size: 18),
                  label: const Text('Notify me'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The line under "Premiere".
///
/// Prefers the timestamp, because a date is what someone deciding whether to
/// come back actually needs. Falls back to YouTube's relative prose, which is
/// what arrives when `video.info` has not answered yet or carried no timestamp.
@visibleForTesting
String premiereText(int? premiereAtMs, String? fallback) {
  if (premiereAtMs == null) return fallback ?? 'Premieres soon';
  final at = DateTime.fromMillisecondsSinceEpoch(premiereAtMs).toLocal();
  final time = TimeOfDay.fromDateTime(at);
  final minute = time.minute.toString().padLeft(2, '0');
  return 'Premieres ${at.day}/${at.month}/${at.year} at ${time.hour}:$minute';
}

/// `STREAM_UNAVAILABLE` and friends (§4).
///
/// A retry affordance rather than a verdict: every rung of the ladder can
/// decline for a video that is perfectly fine (F9, observed 2026-08-02), which
/// is exactly why the protocol makes this `retry: "user"` and not `no`. On a
/// `no` — a login, a cookie, a policy — the button is not drawn, because a
/// button that cannot work is worse than no button.
class _Unavailable extends ConsumerWidget {
  const _Unavailable({required this.playback});

  final PlaybackState playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ColoredBox(
      color: theme.tokens.scrim.withValues(alpha: 0.85),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: scheme.error, size: 40),
              const SizedBox(height: 12),
              Text(
                'This video would not open.',
                style: TextStyle(color: theme.tokens.onScrim, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                playback.error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.tokens.onScrim.withValues(alpha: 0.7), fontSize: 12),
              ),
              if (playback.canRetry) ...[
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.read(playbackProvider.notifier).retry(),
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Title, channel and counts. Falls back to what the tile already knew while
/// `video.info` is in flight, so opening a video never shows an empty header.
class _Meta extends ConsumerWidget {
  const _Meta({required this.item, required this.info});

  final VideoItem item;
  final AsyncValue<VideoDetail> info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final detail = info.value;

    final title = detail?.title ?? item.title;
    final channel = detail?.channelName ?? item.channelName;
    final avatar = detail?.channelAvatarUrl ?? item.channelAvatarUrl;
    final meta = detail?.metaLine ?? item.viewCountText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: scheme.onSurface),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundImage: avatar == null ? null : NetworkImage(avatar),
              onBackgroundImageError: avatar == null ? null : (_, _) {},
              child: avatar == null ? const Icon(Icons.person, size: 20) : null,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  channel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                if (detail?.subscriberText != null)
                  Text(
                    detail!.subscriberText!,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
            const Spacer(),
            if (detail?.likeText != null)
              Row(
                children: [
                  Icon(Icons.thumb_up_outlined, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    detail!.likeText!,
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
          ],
        ),
        if (meta != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(meta, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ),
        if (info.hasError)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _InfoError(videoId: item.id, error: info.error!),
          ),
      ],
    );
  }
}

/// `video.info` failed. The video may still be playing, so this is a strip
/// rather than a page — losing the description is not losing the video.
class _InfoError extends ConsumerWidget {
  const _InfoError({required this.videoId, required this.error});

  final String videoId;
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final retryable = error is! RpcException || (error as RpcException).retry != RpcRetryMode.no;

    return Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: scheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Could not load the video details: $error',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        if (retryable)
          TextButton(
            onPressed: () => ref.invalidate(videoInfoProvider(videoId)),
            child: const Text('Retry'),
          ),
      ],
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.item});

  final VideoItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => _watchLater(context),
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Watch later'),
        ),
        OutlinedButton.icon(
          onPressed: () => ref.read(queueProvider.notifier).addToQueue(item),
          icon: const Icon(Icons.playlist_add, size: 18),
          label: const Text('Add to queue'),
        ),
        OutlinedButton.icon(
          onPressed: () => ref.read(queueProvider.notifier).playNext(item),
          icon: const Icon(Icons.playlist_play, size: 18),
          label: const Text('Play next'),
        ),
        if (playback.source?.qualityDegraded ?? false)
          Chip(
            avatar: const Icon(Icons.hd_outlined, size: 16),
            label: Text('Reduced quality (${playback.source!.best?.height ?? '?'}p)'),
          ),
        // Load-bearing, so its failure is visible rather than inferred from a
        // homepage that slowly stops resembling the real one.
        if (playback.reportError != null)
          Chip(
            avatar: const Icon(Icons.history_toggle_off, size: 16),
            label: const Text('Not recording to history'),
          ),
      ],
    );
  }

  Future<void> _watchLater(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RpcClient.instance.call('action.addToWatchLater', {'videoId': item.id});
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
}

class _Description extends StatelessWidget {
  const _Description({required this.detail, required this.expanded, required this.onToggle});

  final VideoDetail detail;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = detail.description;
    if (description == null || description.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            description,
            maxLines: expanded ? null : 3,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: scheme.onSurface, height: 1.4),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onToggle,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                expanded ? 'Show less' : 'Show more',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
