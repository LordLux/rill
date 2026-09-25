import 'dart:async';

import 'package:flutter/gestures.dart';

import 'package:async/async.dart' show StreamGroup;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/rpc/client.dart';
// `Chip` here is Material's. The domain's `Chip` is the feed's filter strip and
// has no business on this page — hidden rather than aliased so a later edit that
// reaches for one gets an error instead of the wrong class.
import '../../domain/feed_item.dart' hide Chip;
import '../../domain/video_detail.dart';
import '../../theme/tokens.dart';
import '../open_video.dart';
import '../page_wrapper.dart';
import '../player_shell.dart' show currentRouteProvider, watchRouteName;
import '../audio_mode_controller.dart';
import '../auth_controller.dart';
import '../playback_controller.dart';
import '../now_playing_art.dart';
import '../player/audio_backdrop.dart';
import '../player/player_slates.dart';
import '../player/controls.dart';
import '../player/view_mode.dart';
import '../queue_controller.dart';
import '../video_info.dart';
import '../../data/playback/engine.dart';
import '../widgets/adaptive_meta_row.dart';
import '../widgets/channel_badge.dart';
import '../widgets/media_tile.dart';
import '../widgets/queue_panel.dart';
import '../account_actions.dart';
import '../format.dart';
import '../widgets/save_dialog.dart';
import '../widgets/share_dialog.dart';
import '../widgets/watch_skeleton.dart';
import '../widgets/comments_section.dart';
import '../widgets/shortcut_tooltip.dart';
import '../widgets/subscribe_button.dart';
import 'watch_layout.dart';
import '../../theme/screen_values.dart';

/// Where the two sizing rules meet — architecture §2.8
const double _referenceAspect = ScreenValues.normalAspectRatio;

/// The aspect ratio of the frames actually being decoded, **held across a switch**.
///
/// An undecoded pair is the absence of a value, not 16:9, so the last real ratio
/// stands until the next one arrives — architecture §2.8. [_referenceAspect] is
/// only the answer before anything has decoded.
/// Public alias, for the one mount point outside this file that needs it.
///
/// Fullscreen lives in `player_shell.dart` and draws the same texture (§2.8), so
/// its caption handle needs the same ratio the watch page letterboxes against.
/// Exported rather than duplicated, because two providers computing one ratio
/// would eventually disagree about it during a switch.
final fullscreenAspectRatioProvider = Provider<double>(
  (ref) => ref.watch(_aspectRatioProvider).value ?? _referenceAspect,
);

final _aspectRatioProvider = StreamProvider.autoDispose<double>((ref) async* {
  final engine = ref.watch(playbackEngineProvider);

  /// Null while the engine has no frame to speak for — never a fallback.
  double? decodedRatio() {
    final width = engine.width;
    final height = engine.height;
    if (width == null || height == null || width <= 0 || height <= 0)
      return null;
    return width / height;
  }

  var held = decodedRatio() ?? _referenceAspect;
  yield held;

  final merged = StreamGroup.merge<int?>([
    engine.widthStream,
    engine.heightStream,
  ]);
  await for (final _ in merged) {
    // Covers the half-updated pair too, and only because `open` clears both:
    // width lands an event ahead of height, whose partner is null rather than
    // the previous video's.
    final ratio = decodedRatio();
    if (ratio == null || ratio == held) continue;
    held = ratio;
    yield held;
  }
});

/// The watch page (task §3).
///
/// It renders whatever the queue is pointing at rather than a video passed in,
/// so a related tile replacing the current video is just the cursor moving.
class WatchPage extends ConsumerStatefulWidget {
  const WatchPage({super.key});

  @override
  ConsumerState<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends ConsumerState<WatchPage> {
  bool _descriptionExpanded = false;

  /// Which of the single-column layout's two lower sections is showing — 0
  /// for Up Next (related), 1 for Comments. A swap of which sliver group is
  /// present, not a `TabBarView` — architecture §2.8 has why.
  int _narrowTab = 0;

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

    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(playbackProvider);
    final item =
        ref.watch(queueProvider.select((q) => q.current)) ?? playback.item;
    final startingMix = ref.watch(queueProvider.select((q) => q.startingMixId));

    final watchVideoWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BackButton(onPressed: () => Navigator.of(context).maybePop()),
        Text(
          'Watch',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
            fontSize: 20,
          ),
        ),
      ],
    );

    // return PageWrapper(title: watchVideoWidget, body: WatchSkeleton());
    if (item == null) {
      // A mix is on its way. The route was pushed before the round trip
      // finished on purpose (see `startMixFromTile`), so this is the ordinary
      // first second of opening a mix, not an error state.
      //
      // Only when there is nothing playing. When a video *is* already on
      // screen it keeps playing and simply swaps when the mix lands — better
      // than replacing real content with a placeholder, and it avoids
      // unmounting the video texture for a second (architecture §2.8).
      if (startingMix != null)
        return PageWrapper(title: watchVideoWidget, body: WatchSkeleton());

      return PageWrapper(
        title: watchVideoWidget,
        body: Center(child: Text('Nothing playing.')),
      );
    }

    _loadedRelatedFor ??= item.id;
    final info = ref.watch(videoInfoProvider(item.id));

    return PageWrapper(
      title: watchVideoWidget,
      actions: const [],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final theatre = ref.watch(
            playerViewProvider.select((view) => view.theatre),
          );
          final detail = info.value;
          final isAudioOnly = ref.watch(audioModeProvider);
          final aspectValue = ref.watch(_aspectRatioProvider).value;
          final actualAspectRatio = isAudioOnly
              ? ScreenValues.normalAspectRatio
              : (aspectValue ?? ScreenValues.normalAspectRatio);
          final queueHasItems = ref.watch(
            queueProvider.select((q) => q.items.length > 1),
          );
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: actualAspectRatio),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, aspectRatio, _) {
              final viewportHeight = MediaQuery.of(context).size.height;

              final geometry = computeWatchGeometry(
                availableWidth: constraints.maxWidth,
                viewportHeight: viewportHeight,
                aspectRatio: aspectRatio,
                theatre: theatre,
              );

              final embeddedQueue = queueHasItems
                  ? EmbeddedQueuePanel(maxHeight: geometry.playerHeight)
                  : const SizedBox.shrink();

              return WatchLayout(
                geometry: geometry,
                playerSlot: _PlayerSurface(
                  playback: playback,
                  actualAspectRatio: aspectRatio,
                  rounded: !theatre,
                ),
                theatreBackground: theatre ? theme.tokens.scrim : null,
                metadataSlivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 4, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Meta(item: item, info: info),
                          const SizedBox(height: 10),
                          if (detail != null)
                            _Description(
                              detail: detail,
                              expanded: _descriptionExpanded,
                              onToggle: () => setState(
                                () => _descriptionExpanded =
                                    !_descriptionExpanded,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (geometry.isTwoColumn) ...[
                    if (detail != null && detail.commentsContinuation != null)
                      CommentsSection(
                        videoId: item.id,
                        initialContinuation: detail.commentsContinuation!,
                      ),
                    if (detail != null && detail.commentsContinuation == null)
                      _commentsDisabledSliver(item, scheme),
                  ] else ...[
                    // Fixed max height and collapsible on its own (queue_panel.dart),
                    // so it never creates the kind of scroll wall the tab switch
                    // below exists to avoid — safe to leave inline.
                    if (queueHasItems)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 24, 4, 0),
                          child: embeddedQueue,
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 4, 12),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('Up Next'),
                              selected: _narrowTab == 0,
                              onSelected: (_) => setState(() => _narrowTab = 0),
                            ),
                            ChoiceChip(
                              label: const Text('Comments'),
                              selected: _narrowTab == 1,
                              onSelected: (_) => setState(() => _narrowTab = 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_narrowTab == 0)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 4, 32),
                          child: TweenAnimationBuilder<double>(
                            key: const ValueKey('related'),
                            tween: Tween(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 200),
                            builder: (context, opacity, child) =>
                                Opacity(opacity: opacity, child: child),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _relatedSection(
                                detail,
                                item.id,
                                asGrid: true,
                              ),
                            ),
                          ),
                        ),
                      )
                    else ...[
                      if (detail != null && detail.commentsContinuation != null)
                        CommentsSection(
                          key: const ValueKey('comments'),
                          videoId: item.id,
                          initialContinuation: detail.commentsContinuation!,
                        ),
                      if (detail != null && detail.commentsContinuation == null)
                        _commentsDisabledSliver(item, scheme),
                    ],
                  ],
                ],
                railSlivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(8, theatre ? 20 : 2, 16, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          embeddedQueue,
                          ..._relatedSection(detail, item.id),
                        ],
                      ),
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

  /// Shared between the two-column rail and the narrow layout's Comments tab
  /// — the "turned off" state doesn't depend on which one is showing it.
  Widget _commentsDisabledSliver(VideoItem item, ColorScheme scheme) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 24, left: 16),
        child: RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            children: [
              // TODO only show if NOT live
              if (item.isLive)
                TextSpan(
                  text: 'Comments are not available. This is a live stream.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                )
              else
                TextSpan(
                  text: 'Comments are turned off.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              // Clickable link to YouTube's help center for more information about comments being turned off.
              TextSpan(
                text: ' Learn more',
                style: TextStyle(color: scheme.primary),
                recognizer: TapGestureRecognizer()
                  ..onTap = () async {
                    final url = Uri.parse(
                      'https://support.google.com/youtube/answer/9706180',
                    );
                    if (await canLaunchUrl(url)) {
                      await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _relatedSection(
    VideoDetail? detail,
    String videoId, {
    bool asGrid = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    if (detail == null) return const [];

    final items = [...detail.related, ..._extraRelated];
    final continuation = _relatedContinuation ?? detail.relatedContinuation;

    final header = Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        'Related',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 16,
          color: scheme.onSurface,
        ),
      ),
    );

    final showMore = continuation != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 24),
              child: TextButton(
                onPressed: _loadingRelated
                    ? null
                    : () => _loadMoreRelated(videoId, continuation),
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
                      child: _relatedTile(related, asGrid: asGrid),
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
                    child: _relatedTile(related, asGrid: asGrid),
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
          padding: const EdgeInsets.only(bottom: 0),
          child: _relatedTile(related, asGrid: asGrid),
        ),
      showMore,
    ];
  }

  Widget _relatedTile(FeedItem related, {bool asGrid = false}) {
    final spec = specFor(related);
    if (spec == null) return const SizedBox.shrink();
    if (!asGrid) {
      return MediaTile.wide(
        spec: spec,
        onTap: tapHandlerFor(context, ref, related),
        onAddToQueue: () => queueFromTile(ref, related),
        onWatchLater: () => _addToWatchLater(watchTargetFor(related)?.id),
        menu: menuForTile(context, ref, related, spec),
      );
    }
    return MediaTile(
      spec: spec,
      onTap: tapHandlerFor(context, ref, related),
      onAddToQueue: () => queueFromTile(ref, related),
      onWatchLater: () => _addToWatchLater(watchTargetFor(related)?.id),
      menu: menuForTile(context, ref, related, spec),
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
      await RpcClient.instance.call('action.addToWatchLater', {
        'videoId': videoId,
      });
      _toast('Saved to Watch Later');
    } on RpcException catch (e) {
      _toast(
        e.code == 'AUTH_REQUIRED'
            ? 'Sign in to save to Watch Later'
            : e.message,
      );
    } on Object catch (e) {
      _toast('$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The video, or whatever is standing in for it.
///
/// The surface belongs to the shell's engine — the player is not created here,
/// it is rendered here, and the same texture renders in the mini-player once
/// this route is popped. On a fake engine (tests) the surface is a placeholder,
/// which is the point of the engine being an interface.
class _PlayerSurface extends ConsumerWidget {
  const _PlayerSurface({
    required this.playback,
    this.rounded = true,
    this.actualAspectRatio,
  });

  final PlaybackState playback;

  /// Theatre runs the player to the edges of the content area, where a rounded
  /// corner reads as a mistake rather than as a card.
  final bool rounded;

  /// The decoded aspect ratio of the stream. When non-null, centers and constrains
  /// the video texture to this ratio inside the outer player box while keeping
  /// controls and scrim full-width.
  final double? actualAspectRatio;

  Widget _buildSurface(
    bool fullscreen,
    bool isAudioOnly,
    PlaybackState playback,
    bool isTopWatchPage,
    PlaybackEngine engine,
    ColorScheme scheme,
    String? backdropUrl,
  ) {
    if (fullscreen) return const SizedBox.shrink();

    // **The surface stays mounted in audio-only too.** The artwork fades over
    // it rather than replacing it, so the texture keeps decoding underneath and
    // the crossfade never costs a remount.
    final muxedOnly =
        isAudioOnly &&
        playback.variant != null &&
        playback.variant!.audioUrl == null;

    return Stack(
      fit: StackFit.expand,
      children: [
        isTopWatchPage ? engine.videoSurface() : engine.videoWidget(),
        // Held through the restore as well — see [AudioArtOverlay]
        AudioArtOverlay(
          show: isAudioOnly || playback.isRestoringVideo,
          // The chapter's frame on a song mix, else the poster: the tile's own
          // thumbnail is whatever the surface that listed it shipped, which on
          // the related rail is 480x360 (F40). Null is ordinary.
          imageUrl: backdropUrl,
        ),

        if (muxedOnly)
          Positioned(
            top: 24,
            right: 24,
            child: Tooltip(
              message:
                  'Audio-only stream unavailable.\nConsuming video bandwidth.',
              child: Icon(
                Icons.warning_amber_rounded,
                color: scheme.error,
                size: 28,
                semanticLabel: 'Audio-only stream unavailable',
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final engine = ref.read(playbackEngineProvider);
    final fullscreen = ref.watch(
      playerViewProvider.select((view) => view.fullscreen),
    );
    final ratio =
        actualAspectRatio ??
        ref.watch(_aspectRatioProvider).value ??
        (ScreenValues.normalAspectRatio);
    final isTopWatchPage =
        (ModalRoute.of(context)?.isCurrent == true) &&
        (ref.watch(currentRouteProvider) == watchRouteName);
    final isAudioOnly = ref.watch(audioModeProvider);

    final content = ColoredBox(
      color: theme.tokens.scrim,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // `currentRouteProvider`, not *just* `ModalRoute.of(context)?.isCurrent` —
          // see the comment on that provider in `player_shell.dart`. The two
          // used to disagree for exactly one frame on the transition *into*
          // this page. We AND them together so only the top-most WatchPage
          // claims the surface, but it still waits for the provider to catch up.
          _buildSurface(
            fullscreen,
            isAudioOnly,
            playback,
            isTopWatchPage,
            engine,
            scheme,
            // Watched only in audio-only: the chapter changes on a schedule, and
            // nothing else on this surface should rebuild for it.
            isAudioOnly || playback.isRestoringVideo ? ref.watch(nowPlayingBackdropProvider) : null,
          ),

          if (playback.isLoading)
            Center(child: CircularProgressIndicator(color: scheme.onPrimary)),
          Builder(
            builder: (context) {
              if (!playback.isLoading && !fullscreen && isTopWatchPage) {
                return PlayerControls(
                  engine: engine,
                  actualAspectRatio: ratio,
                  child: const PlayerSlates(showQueue: false),
                );
              }
              
              if (playback.isLoading) return const SizedBox.shrink();
              return const PlayerSlates(showQueue: false);
            },
          ),
        ],
      ),
    );

    if (!rounded) return content;
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}

/// The line under "Premiere".
///
/// Prefers the timestamp, because a date is what someone deciding whether to
/// come back actually needs. Falls back to YouTube's relative prose, which is

/// `STREAM_UNAVAILABLE` and friends (§4), including `RATE_LIMITED`, which gets
/// its own wording: the connection is being limited, the video is fine.
///
/// A retry affordance rather than a verdict: every rung of the ladder can
/// decline for a video that is perfectly fine (F9, observed 2026-08-02), which
/// is exactly why the protocol makes this `retry: "user"` and not `no`. On a
/// `no` — a login, a cookie, a policy — the button is not drawn, because a
/// button that cannot work is worse than no button.

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

    final metaWidget = Row(
      mainAxisSize: MainAxisSize.min,
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
            SelectionArea(
              child: Row(
                children: [
                  Text(
                    channel,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  ChannelBadge(
                    channelId: detail?.channelId ?? item.channelId,
                    isArtistChannel:
                        detail?.isArtistChannel ?? item.isArtistChannel,
                    isVerified: detail?.isVerified ?? item.isVerified,
                    size: 14,
                    paddingLeft: 4,
                  ),
                ],
              ),
            ),
            if (detail?.subscriberText != null)
              Text(
                detail!.subscriberText!,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(width: 16),
        SubscribeButton(
          key: ValueKey(detail?.channelId ?? item.channelId),
          channelId: detail?.channelId ?? item.channelId,
          // What the user last did wins over the `/next` snapshot, which is as
          // old as the page — see `account_actions.dart`.
          initiallySubscribed:
              ref.watch(
                subscriptionActionsProvider.select(
                  (actions) => actions[detail?.channelId ?? item.channelId],
                ),
              ) ??
              detail?.isSubscribed ??
              false,
          minHeight: 45,
          onSubscribe: (channelId) =>
              _setSubscribed(context, ref, channelId, subscribe: true),
          onUnsubscribe: (channelId) =>
              _setSubscribed(context, ref, channelId, subscribe: false),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        SelectionArea(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 12),
        AdaptiveMetaRow(
          spacing: 16,
          meta: metaWidget,
          actions: _Actions(item: item, info: info),
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

/// [SubscribeButton.onSubscribe] / `onUnsubscribe` for the watch page's
/// channel row.
///
/// The outcome is written to `subscriptionActionsProvider` rather than left in
/// the button's own `State`, so it survives the rebuilds that used to reset the
/// button to the page-load snapshot. The container is captured before the call:
/// the button may well be rebuilt while the request is out, and the result
/// still belongs in the store.
Future<bool> _setSubscribed(
  BuildContext context,
  WidgetRef ref,
  String channelId, {
  required bool subscribe,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final actions = ref.read(subscriptionActionsProvider.notifier);
  try {
    await RpcClient.instance.call(
      subscribe ? 'action.subscribe' : 'action.unsubscribe',
      {'channelId': channelId},
    );
    actions.set(channelId, subscribe);
    return true;
  } on RpcException catch (e) {
    final signIn = subscribe
        ? 'Sign in to subscribe'
        : 'Sign in to unsubscribe';
    messenger.showSnackBar(
      SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? signIn : e.message)),
    );
    return false;
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return false;
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
    final retryable =
        error is! RpcException ||
        (error as RpcException).retry != RpcRetryMode.no;

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

/// Which of the pills is holding a dialog open.
///
/// One field rather than a bool per pill: two of these can never be up at the
/// same time, and a pair of bools can represent that impossible state.
enum _OpenSheet { share, save }

/// The row under the title: the counts, like/dislike, and the four pills
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.item, required this.info});

  final VideoItem item;
  final AsyncValue<VideoDetail> info;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  _OpenSheet? _sheet;

  /// Bumped whenever the video changes, to invalidate replies still in the
  /// air for *any* of this widget's optimistic actions — ratings and Watch
  /// Later both key off it, rather than each keeping its own counter.
  int _videoGeneration = 0;

  // ---- Watch Later (Task 25 §7) ----
  //
  // What the user last did lives in `watchLaterActionsProvider`, not here — a
  // field on this `State` was discarded by every theatre toggle, resize and
  // mini-player round trip (`account_actions.dart`). An entry overrides
  // `playlistMembershipProvider`; absence defers to it. Not cleared after a
  // successful mutation, so the pill never flickers back to "unsaved" while the
  // invalidated membership fetch is still in flight.

  /// A save or remove in flight, so a second tap cannot land on a pill that
  /// only looks settled while the first is still in the air.
  bool _savingWatchLater = false;

  /// The white has had its moment and stepped back.
  ///
  /// The pill answers the click for two seconds, then is only recording a
  /// status — and that much white sitting in the row for the rest of the video
  /// reads as an alert about something that already went fine. So it settles to
  /// the dark fill, keeping the tick and the white as an edge.
  bool _watchLaterSettled = false;
  Timer? _settleTimer;

  // ---- Like / dislike (Task 25 §3–§4) ----
  //
  // Same arrangement over `VideoDetail.myRating`: `ratingActionsProvider` holds
  // the outcome, keyed by video, so no rebuild can reset it to the page-load
  // snapshot. Only the in-flight flag is local — it describes this widget's
  // pending tap, not the account.
  bool _ratingBusy = false;

  @override
  void didUpdateWidget(_Actions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id == widget.item.id) return;
    _videoGeneration++;
    _sheet = null;
    _savingWatchLater = false;
    _watchLaterSettled = false;
    _settleTimer?.cancel();
    _settleTimer = null;
    _ratingBusy = false;
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final detail = widget.info.value;
    final playback = ref.watch(playbackProvider);
    // Fetched concurrently with `video.info`, the same reason `captions.list`
    // runs alongside rather than inside the watch page's open path (§3.8):
    // this pill needs real state before the first render, and `/next` does
    // not carry it — `playlist/get_add_to_playlist` is a separate call.
    final membership = ref.watch(playlistMembershipProvider(item.id));

    final views = detail?.viewCountText ?? item.viewCountText ?? '';
    // Shortened for the row, exact on hover — but only when the exact number
    // is actually known. A feed tile carries "1.8M views" and nothing more, and
    // re-shortening that would be inventing precision the response never had;
    // there the row shows YouTube's own string with no tooltip.
    final exactViews = detail?.viewCount;
    final shortViews = exactViews == null
        ? null
        : formatCompactViews(exactViews);
    final date = detail?.publishedText ?? '';
    // Null whenever it would just repeat `date` — a layout with no relative
    // date at all falls back to the exact one for both fields (§ sidecar
    // `parser/video.ts`), and a tooltip that says exactly what is already on
    // screen is not a tooltip worth having.
    final exactDate =
        detail?.publishedDateText != null && detail!.publishedDateText != date
        ? detail.publishedDateText
        : null;
    final likes = detail?.likeText ?? 'Like';

    final rating =
        ref.watch(
          ratingActionsProvider.select((actions) => actions[item.id]),
        ) ??
        detail?.myRating ??
        VideoRating.none;
    final inWatchLater =
        ref.watch(
          watchLaterActionsProvider.select((actions) => actions[item.id]),
        ) ??
        (membership.value?.any((p) => p.id == 'WL' && p.containsVideo) ??
            false);

    // Why the account-requiring controls below are disabled, or null when they
    // are live. These used to be pressable signed out: the optimistic rating
    // applied, the call came back `AUTH_REQUIRED`, and it reverted under a
    // toast — a control that looks available, does something, then undoes it.
    // A disabled control with a reason is the better shape, and it is the same
    // sentence the comment vote buttons use.
    final authStatus = ref.watch(authProvider.select((auth) => auth.status));
    final cannotRate = signedInActionBlocker(authStatus, 'rate videos');
    final cannotSave = signedInActionBlocker(authStatus, 'save videos');

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // The read-outs, one `Wrap` child each — see [_MetaStat].
        if (views.isNotEmpty)
          shortViews == null
              ? _MetaStat(icon: Icons.visibility_outlined, text: views)
              : ShortcutTooltip(
                  label: views,
                  child: _MetaStat(
                    icon: Icons.visibility_outlined,
                    text: shortViews,
                  ),
                ),
        if (date.isNotEmpty)
          exactDate == null
              ? _MetaStat(icon: Icons.calendar_today_outlined, text: date)
              : ShortcutTooltip(
                  label: exactDate,
                  child: _MetaStat(
                    icon: Icons.calendar_today_outlined,
                    text: date,
                  ),
                ),

        // Like & Dislike
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShortcutTooltip(
                label:
                    cannotRate ??
                    (rating == VideoRating.like ? 'Remove like' : 'Like'),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    mouseCursor: _ratingBusy || cannotRate != null
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.click,
                    onTap: _ratingBusy || cannotRate != null
                        ? null
                        : () => _setRating(VideoRating.like),
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 12,
                        top: 8,
                        bottom: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            rating == VideoRating.like
                                ? Icons.thumb_up
                                : Icons.thumb_up_outlined,
                            size: 18,
                            color: scheme.onSurface,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            likes,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 18,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
              ShortcutTooltip(
                label:
                    cannotRate ??
                    (rating == VideoRating.dislike
                        ? 'Remove dislike'
                        : 'Dislike'),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    mouseCursor: _ratingBusy || cannotRate != null
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.click,
                    onTap: _ratingBusy || cannotRate != null
                        ? null
                        : () => _setRating(VideoRating.dislike),
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 12,
                        right: 16,
                        top: 8,
                        bottom: 8,
                      ),
                      child: Icon(
                        rating == VideoRating.dislike
                            ? Icons.thumb_down
                            : Icons.thumb_down_outlined,
                        size: 18,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Share
        ShortcutTooltip(
          label: 'Share',
          child: _ActionChip(
            icon: Icons.reply,
            activeLabel: 'Share',
            active: _sheet == _OpenSheet.share,
            onTap: openShare,
          ),
        ),

        // Playlist
        ShortcutTooltip(
          label: cannotSave ?? 'Save to playlist',
          child: _ActionChip(
            icon: Icons.playlist_add,
            activeIcon: Icons.playlist_add_check,
            activeLabel: 'Save',
            active: _sheet == _OpenSheet.save,
            onTap: cannotSave != null ? null : _openSave,
          ),
        ),

        // Watch Later
        ShortcutTooltip(
          label:
              cannotSave ??
              (inWatchLater ? 'Remove from Watch Later' : 'Watch Later'),
          child: _ActionChip(
            icon: Icons.schedule,
            activeIcon: Icons.check,
            activeLabel: 'Watch Later',
            active: inWatchLater && !_watchLaterSettled,
            marked: inWatchLater && _watchLaterSettled,
            onTap: cannotSave != null
                ? null
                : () => _tapWatchLater(inWatchLater),
          ),
        ),

        // More
        ShortcutTooltip(
          label: 'More',
          child: _ActionChip(
            icon: Icons.more_horiz,
            semanticLabel: 'More',
            onTap: () {},
          ),
        ),

        if (playback.source?.qualityDegraded ?? false) ...[
          _ActionChip(
            icon: Icons.hd_outlined,
            label: 'Reduced quality (${playback.source!.best?.height ?? '?'}p)',
          ),
        ],
        if (playback.reportError != null) ...[
          _ActionChip(
            icon: Icons.history_toggle_off,
            label: 'Not recording',
          ),
        ],
      ],
    );
  }

  Future<void> openShare() async {
    setState(() => _sheet = _OpenSheet.share);
    await showShareDialog(context, widget.item, position: _positionNow());
    if (mounted) setState(() => _sheet = null);
  }

  Future<void> _openSave() async {
    // Captured before the await. This widget can be rebuilt — or gone — by the
    // time the dialog closes, and `ref` on a disposed state throws; the
    // container outlives it. The id is captured for the same reason: re-reading
    // `widget.item` afterwards would refresh whichever video is current *now*.
    final videoId = widget.item.id;
    final container = ProviderScope.containerOf(context, listen: false);

    setState(() => _sheet = _OpenSheet.save);
    await showSaveDialog(context, videoId);

    // The dialog is the more thorough source of truth once it has been
    // opened — whatever it left checked or unchecked, this pill should agree
    // rather than keep showing whatever it thought before the dialog ran.
    container.invalidate(playlistMembershipProvider(videoId));
    container.read(watchLaterActionsProvider.notifier).clear(videoId);
    if (mounted) setState(() => _sheet = null);
  }

  /// Where the video is right now, for the share dialog's "Start at".
  ///
  /// Read once when the dialog opens, not watched.
  Duration _positionNow() {
    final playback = ref.read(playbackProvider);
    if (playback.item?.id != widget.item.id) return Duration.zero;
    return playback.hold?.position ?? ref.read(playbackEngineProvider).position;
  }

  /// Toggles both ways now that `action.removeFromPlaylist` exists — Watch
  /// Later is a playlist with a fixed id (§7), so removing from it is exactly
  /// the mechanism §5 built for the save dialog.
  Future<void> _tapWatchLater(bool currentlyInWatchLater) {
    if (_savingWatchLater) return Future.value();
    return currentlyInWatchLater
        ? _removeFromWatchLater()
        : _saveToWatchLater();
  }

  /// Latches first, asks after, and puts it back if the answer is no.
  ///
  /// **Guarded by a generation, not by the video id.** A related tap swaps the
  /// video under this page without a route change, so by the time the call
  /// answers `widget.item` may be something else and the reply must be dropped —
  /// but *away and back to the same video* passes an id check while the state it
  /// would write has already been cleared. The counter cannot be fooled that
  /// way: any swap invalidates every reply that was already in the air.
  Future<bool> _saveToWatchLater() async {
    final videoId = widget.item.id;
    final generation = _videoGeneration;
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(watchLaterActionsProvider.notifier);
    final had = ref.read(watchLaterActionsProvider).containsKey(videoId);
    final previous = ref.read(watchLaterActionsProvider)[videoId];
    final container = ProviderScope.containerOf(context, listen: false);

    actions.set(videoId, true);
    setState(() => _savingWatchLater = true);

    String? failure;
    try {
      await RpcClient.instance.call('action.addToWatchLater', {
        'videoId': videoId,
      });
    } on RpcException catch (e) {
      failure = e.code == 'AUTH_REQUIRED'
          ? 'Sign in to save to Watch Later'
          : e.message;
    } catch (e) {
      failure = '$e';
    }

    // The account outcome is recorded whatever happened to this widget in the
    // meantime — it is keyed by video, so it cannot land on the wrong one.
    if (failure != null) {
      actions.restore(videoId, had: had, previous: previous);
    } else {
      container.invalidate(playlistMembershipProvider(videoId));
    }

    // A failure is reported even if the user has moved on — it is about their
    // account, and swallowing it leaves them believing the save worked. Success
    // confirmations are only for the video still on screen.
    if (failure != null)
      messenger.showSnackBar(SnackBar(content: Text(failure)));

    if (!mounted ||
        generation != _videoGeneration ||
        widget.item.id != videoId) {
      return failure == null;
    }

    setState(() => _savingWatchLater = false);
    if (failure == null) _say('Saved to Watch Later');

    // Timed from the answer, not from the tap. On a slow call the tap-to-answer
    // gap is already most of the two seconds, and a pill that settles the
    // instant the save lands never reads as a confirmation of it.
    if (failure == null) {
      _settleTimer?.cancel();
      _settleTimer = Timer(_watchLaterSettleDelay, () {
        if (mounted) setState(() => _watchLaterSettled = true);
      });
    }
    return failure == null;
  }

  /// The inverse. Removing needs a `setVideoId`, not just a video id
  /// (§5's `action.removeFromPlaylist` note), so this looks up Watch Later's
  /// own `removeToken` via `playlist.forVideo` — the same call the Save
  /// dialog already makes — and replays it. Two round trips rather than one,
  /// spent on a rare, deliberate tap rather than the hot path.
  Future<void> _removeFromWatchLater() async {
    final videoId = widget.item.id;
    final generation = _videoGeneration;
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(watchLaterActionsProvider.notifier);
    final had = ref.read(watchLaterActionsProvider).containsKey(videoId);
    final previous = ref.read(watchLaterActionsProvider)[videoId];
    final container = ProviderScope.containerOf(context, listen: false);

    actions.set(videoId, false);
    setState(() {
      _savingWatchLater = true;
      _watchLaterSettled = false;
    });
    _settleTimer?.cancel();

    String? failure;
    try {
      final response =
          await RpcClient.instance.call('playlist.forVideo', {
                'videoId': videoId,
              })
              as Map<String, dynamic>;
      String? token;
      for (final raw in (response['playlists'] as List<dynamic>? ?? [])) {
        final row = raw as Map<String, dynamic>;
        if (row['id'] == 'WL') {
          token = row['removeToken'] as String?;
          break;
        }
      }
      // No token means the server never thought it was there — nothing to
      // remove, and not a failure to report.
      if (token != null) {
        await RpcClient.instance.call('action.removeFromPlaylist', {
          'playlistId': 'WL',
          'removeToken': token,
        });
      }
    } on RpcException catch (e) {
      failure = e.code == 'AUTH_REQUIRED'
          ? 'Sign in to edit Watch Later'
          : e.message;
    } catch (e) {
      failure = '$e';
    }

    if (failure != null) {
      actions.restore(videoId, had: had, previous: previous);
    } else {
      container.invalidate(playlistMembershipProvider(videoId));
    }

    if (failure != null)
      messenger.showSnackBar(SnackBar(content: Text(failure)));

    if (!mounted || generation != _videoGeneration || widget.item.id != videoId)
      return;

    setState(() => _savingWatchLater = false);
    if (failure == null) _say('Removed from Watch Later');
  }

  /// Like, dislike and un-rate — see [rateVideo], which the taskbar's thumbnail
  /// toolbar shares. This adds only what belongs to the widget: the busy flag,
  /// and the snackbar.
  Future<void> _setRating(VideoRating target) async {
    if (_ratingBusy) return;
    final videoId = widget.item.id;
    final generation = _videoGeneration;
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _ratingBusy = true);
    final failure = await rateVideo(
      ref.read,
      videoId,
      target,
      serverRating: widget.info.value?.myRating ?? VideoRating.none,
    );
    if (failure != null) messenger.showSnackBar(SnackBar(content: Text(failure)));

    if (!mounted || generation != _videoGeneration || widget.item.id != videoId)
      return;

    setState(() => _ratingBusy = false);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// How long a pill takes to grow, and to go white.
///
/// The same 140 ms `easeOut` the player's volume slider opens on, so the two
/// pieces of chrome that change width in place feel like one app.
const Duration _chipMorph = Duration(milliseconds: 140);

/// How long the Watch Later pill stays loud before settling.
const Duration _watchLaterSettleDelay = Duration(seconds: 2);

/// One read-out under the video: a glyph and the number it labels.
///
/// **One `Wrap` child, not four.** Spread as icon, gap, text, gap — which is
/// what `...[ ]` into the parent's `children` produces — the row's glyph and its
/// number are separate children, and `Wrap` starts a new run wherever the next
/// child will not fit. It has no notion of two children that belong together, so
/// there is a band of widths at which the eye lands at the end of one line and
/// "1.2M views" opens the next, labelling nothing. The like/dislike group never
/// had the problem because it was always a single child.
///
/// **The trailing gap is `Padding` inside this widget rather than a `SizedBox`
/// beside it**, for the same reason. A spacer child is a child: `Wrap.spacing`
/// is inserted on *both* sides of it, so a `SizedBox(width: 16)` rendered as 32,
/// and at a run boundary it strands as an empty offset at the end of a line.
/// Padding carried inside the pair cannot be separated from it, and the gap is
/// stated once.
class _MetaStat extends StatelessWidget {
  const _MetaStat({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      // Plus the `Wrap`'s own 8, so the read-outs sit further from the pills
      // than the pills sit from each other — which is the grouping the row is
      // trying to show.
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: scheme.onSurface),
          const SizedBox(width: 6),
          SelectionArea(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One pill under the video: an icon, and its label.
///
/// The label is mounted at width zero behind an `Align(widthFactor:)` rather
/// than swapped in with an `if`, so closing is opening played backwards.
///
/// `inverseSurface` is the "white" the mock shows, and the one role that stays
/// legible against `onInverseSurface` at any accent. Fill and glyph are lerped
/// by hand off one tween so they arrive together.
class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    this.label,
    this.activeIcon,
    this.activeLabel,
    this.semanticLabel,
    this.active = false,
    this.marked = false,
    this.onTap,
  });

  final IconData icon;

  /// What a screen reader hears
  final String? semanticLabel;

  /// Shown at all times. The read-outs — *Reduced quality*, *Not recording* —
  /// use this and nothing else: they report a condition rather than answer a
  /// tap, so they are born full length and never go white.
  final String? label;

  /// Swapped in for [icon] while [active] — the tick on a saved Watch Later.
  final IconData? activeIcon;

  /// Shown only while [active]. This is what makes the pill grow.
  final String? activeLabel;

  /// On, but done shouting: dark fill, collapsed, still showing [activeIcon],
  /// outlined in the white the fill gave up.
  ///
  /// Mutually exclusive with [active] at every call site. Two booleans rather than one enum so
  /// *filled?* and *edged?* stay independently answerable, which is what makes the transition one interpolation.
  final bool marked;

  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Deliberately not conditioned on [active]: the text has to survive the
    // collapse, or there is nothing left for the width to animate down from.
    // No caller sets both, so in practice this never changes mid-animation.
    final text = label ?? activeLabel;
    final expanded = label != null || (active && activeLabel != null);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: active ? 1 : 0),
      duration: _chipMorph,
      curve: Curves.easeOut,
      builder: (context, tint, _) {
        final background = Color.lerp(
          scheme.surfaceContainerHigh,
          scheme.inverseSurface,
          tint,
        )!;
        final foreground = Color.lerp(
          scheme.onSurface,
          scheme.onInverseSurface,
          tint,
        )!;

        // **Driven off the same tween as the fill, inverted.** The settle is one
        // motion — white leaving the middle and arriving at the edge — so the
        // edge cannot have a clock of its own without the two disagreeing for a
        // few frames in the middle. `1 - tint` is exactly "however much fill has
        // drained", and there is nothing left to keep in sync.
        final edge = marked ? (1 - tint) * 0.7 : 0.0;

        return Material(
          color: background,
          animationDuration: Duration.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: edge == 0
                ? BorderSide.none
                : BorderSide(
                    color: scheme.inverseSurface.withValues(alpha: edge),
                  ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: SystemMouseCursors.click,
            onTap: onTap,
            child: SizedBox(
              height: 36,
              child: Padding(
                // 9 + 18 + 9 = the 36 the collapsed pill was already square at.
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (active || marked) ? (activeIcon ?? icon) : icon,
                      size: 18,
                      color: foreground,
                      semanticLabel: semanticLabel ?? text,
                    ),
                    if (text != null)
                      ClipRect(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: expanded ? 1 : 0),
                          duration: _chipMorph,
                          curve: Curves.easeOut,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8, right: 5),
                            child: Text(
                              text,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: foreground,
                              ),
                            ),
                          ),
                          builder: (context, reveal, child) => Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: reveal,
                            child: child,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The last description measured, kept because these two `TextPainter.layout()`
/// calls are the most expensive thing on the page and they are not asked for
/// once per description — the aspect-ratio morph rebuilds this subtree on every
/// one of its ~18 frames, and text layout over a long description is not a
/// per-frame cost. One entry is enough: only one description is ever on screen.
({
  String text,
  TextStyle style,
  double width,
  double collapsed,
  double full,
  bool overflowing,
})?
_descriptionMeasurement;

({double collapsed, double full, bool overflowing}) _measureDescription(
  String text,
  TextStyle style,
  double width,
) {
  final cached = _descriptionMeasurement;
  if (cached != null &&
      cached.text == text &&
      cached.style == style &&
      cached.width == width) {
    return (
      collapsed: cached.collapsed,
      full: cached.full,
      overflowing: cached.overflowing,
    );
  }

  final span = TextSpan(text: text, style: style);
  final collapsed = TextPainter(
    text: span,
    maxLines: 3,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);
  final full = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);

  _descriptionMeasurement = (
    text: text,
    style: style,
    width: width,
    collapsed: collapsed.size.height,
    full: full.size.height,
    overflowing: collapsed.didExceedMaxLines,
  );
  return (
    collapsed: collapsed.size.height,
    full: full.size.height,
    overflowing: collapsed.didExceedMaxLines,
  );
}

class _Description extends StatelessWidget {
  const _Description({
    required this.detail,
    required this.expanded,
    required this.onToggle,
  });

  final VideoDetail detail;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = detail.description;
    if (description == null || description.isEmpty)
      return const SizedBox.shrink();

    final style = TextStyle(fontSize: 13, color: scheme.onSurface, height: 1.4);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final measured = _measureDescription(
            description,
            style,
            constraints.maxWidth,
          );
          final collapsedHeight = measured.collapsed;
          final isOverflowing = measured.overflowing;
          final fullHeight = measured.full + 8; // padding

          final fullTextWidget = SelectionArea(
            child: _LinkifiedText(
              text: description,
              baseStyle: style,
              linkStyle: style.copyWith(color: scheme.primary),
            ),
          );

          final collapsedTextWidget = SelectionArea(
            child: _LinkifiedText(
              text: description,
              baseStyle: style,
              linkStyle: style.copyWith(
                color: scheme.primary,
                decoration: TextDecoration.underline,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOutCubic,
                tween: Tween<double>(
                  begin: expanded ? fullHeight : collapsedHeight,
                  end: expanded ? fullHeight : collapsedHeight,
                ),
                builder: (context, height, child) {
                  final isFullyCollapsed =
                      height == collapsedHeight && !expanded;
                  return SizedBox(
                    height: height,
                    child: ClipRect(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: isFullyCollapsed
                            ? collapsedTextWidget
                            : fullTextWidget,
                      ),
                    ),
                  );
                },
              ),
              if (isOverflowing || expanded) ...[
                const SizedBox(height: 1),
                GestureDetector(
                  onTap: onToggle,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      expanded ? 'Show less' : 'Show more',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Hands a URL to whatever the OS registered for it
const Set<String> _launchableSchemes = {'http', 'https', 'mailto'};

void _openInBrowser(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !_launchableSchemes.contains(uri.scheme)) return;
  unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
}

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({
    required this.text,
    required this.baseStyle,
    required this.linkStyle,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle baseStyle;
  final TextStyle linkStyle;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];
  late TextSpan _span;
  static final RegExp _urlRegex = RegExp(r'(https?:\/\/[^\s)]+)');

  @override
  void initState() {
    super.initState();
    _buildSpan();
  }

  @override
  void didUpdateWidget(_LinkifiedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.baseStyle != widget.baseStyle ||
        oldWidget.linkStyle != widget.linkStyle) {
      _disposeRecognizers();
      _buildSpan();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _buildSpan() {
    final List<TextSpan> spans = [];
    int start = 0;
    for (final match in _urlRegex.allMatches(widget.text)) {
      if (match.start > start) {
        spans.add(
          TextSpan(
            text: widget.text.substring(start, match.start),
            style: widget.baseStyle,
          ),
        );
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _openInBrowser(url);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: widget.linkStyle,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      start = match.end;
    }
    if (start < widget.text.length) {
      spans.add(
        TextSpan(text: widget.text.substring(start), style: widget.baseStyle),
      );
    }
    _span = TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      _span,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
