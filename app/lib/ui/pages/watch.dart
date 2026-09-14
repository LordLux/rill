import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';

import 'package:async/async.dart' show StreamGroup;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:silky_scroll/silky_scroll.dart';
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
import '../playback_controller.dart';
import '../player/controls.dart';
import '../player/view_mode.dart';
import '../queue_controller.dart';
import '../video_info.dart';
import '../widgets/adaptive_meta_row.dart';
import '../widgets/tile_badges.dart';
import '../widgets/channel_badge.dart';
import '../widgets/media_tile.dart';
import '../widgets/queue_panel.dart';
import '../account_actions.dart';
import '../format.dart';
import '../widgets/save_dialog.dart';
import '../widgets/watch_skeleton.dart';
import '../widgets/shortcut_tooltip.dart';
import '../widgets/subscribe_button.dart';
import 'watch_layout.dart';
import '../../theme/screen_values.dart';

/// Where the two sizing rules meet — architecture §2.8
const double _referenceAspect = ScreenValues.normalAspectRatio;

const Key premiereSlateKey = ValueKey('premiere-slate');
const Key premiereNotifyKey = ValueKey('premiere-notify');
const Key membersOnlySlateKey = ValueKey('members-only-slate');
const Key membersOnlyJoinKey = ValueKey('members-only-join');

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
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    return width / height;
  }

  var held = decodedRatio() ?? _referenceAspect;
  yield held;

  final merged = StreamGroup.merge<int?>([engine.widthStream, engine.heightStream]);
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
    final startingMix = ref.watch(queueProvider.select((q) => q.startingMixId));

    final watchVideoWidget = Row(
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
      if (startingMix != null) return PageWrapper(title: watchVideoWidget, body: WatchSkeleton());

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
          final theatre = ref.watch(playerViewProvider.select((view) => view.theatre));
          final detail = info.value;
          final actualAspectRatio = ref.watch(_aspectRatioProvider).value ?? (ScreenValues.normalAspectRatio);
          final queueHasItems = ref.watch(queueProvider.select((q) => q.items.length > 1));

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

              final embeddedQueue = queueHasItems ? EmbeddedQueuePanel(maxHeight: geometry.playerHeight) : const SizedBox.shrink();

              return WatchLayout(
                geometry: geometry,
                playerSlot: _PlayerSurface(
                  playback: playback,
                  actualAspectRatio: aspectRatio,
                  rounded: !theatre,
                ),
                theatreBackground: theatre ? Theme.of(context).tokens.scrim : null,
                metadataSlot: Padding(
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
                          onToggle: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
                        ),
                      if (!geometry.isTwoColumn) ...[
                        const SizedBox(height: 24),
                        embeddedQueue,
                        ..._relatedSection(detail, item.id, asGrid: true),
                      ],
                    ],
                  ),
                ),
                railSlot: Padding(
                  padding: EdgeInsets.fromLTRB(8, theatre ? 20 : 2, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      embeddedQueue,
                      ..._relatedSection(detail, item.id),
                    ],
                  ),
                ),
                scrollView: (children) => SilkyListView(
                  padding: EdgeInsets.zero,
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: children,
                ),
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
      padding: const EdgeInsets.only(bottom: 2),
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
          padding: const EdgeInsets.only(bottom: 12),
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
      );
    }
    return MediaTile(
      spec: spec,
      onTap: tapHandlerFor(context, ref, related),
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
    final ratio = actualAspectRatio ?? ref.watch(_aspectRatioProvider).value ?? (ScreenValues.normalAspectRatio);
    final isTopWatchPage = (ModalRoute.of(context)?.isCurrent == true) && (ref.watch(currentRouteProvider) == watchRouteName);
    // Watched here rather than inside the helper below, so this widget's
    // subscriptions are all readable from one place. Carries the *structural*
    // members-only flag — see [isMembersOnlyFailure].
    final item = playback.item;
    final detail = item == null ? null : ref.watch(videoInfoProvider(item.id)).value;

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
          if (!fullscreen) isTopWatchPage ? engine.videoSurface() : engine.videoWidget(),

          if (playback.isLoading) Center(child: CircularProgressIndicator(color: scheme.onPrimary)),
          // Neither of the first two is a failure, so neither gets the failure
          // screen — a members-only video is working exactly as its channel
          // intends, the same way a premiere is.
          if (playback.isUpcoming) _PremiereSlate(playback: playback)
          
          else if (isMembersOnlyFailure(playback, detail)) _MembersOnlySlate(playback: playback)
          
          else if (playback.error != null) _Unavailable(playback: playback),

          if (playback.error == null && !playback.isLoading && !fullscreen && isTopWatchPage) PlayerControls(engine: engine, actualAspectRatio: ratio),
        ],
      ),
    );

    if (!rounded) return content;
    return ClipRRect(borderRadius: BorderRadius.circular(11), clipBehavior: Clip.antiAlias, child: content);
  }
}

/// A video that has not premiered yet: thumbnail, date and a reminder, never a
/// *Try again* — nothing is wrong with it, it has a start time.
///
/// The time comes from `video.info` (`premiereAtMs`), falling back to YouTube's
/// own prose on the error message ("Premieres in 9 days"). One of the two is
/// always present, which is why this need not wait on `video.info` to draw.
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

/// Whether a failed open is a members-only one — from either signal.
///
/// **Two signals, and only one of them is structural.** `VIDEO_MEMBERS_ONLY` is
/// classified in the sidecar from YouTube's refusal *prose*, because the resolve
/// clients carry nothing else (`protocol.md` §4). That prose is localised, so on
/// a locale the pattern misses the sidecar answers `STREAM_UNAVAILABLE` and the
/// user would get "This video would not open" with a *Try again* that cannot
/// work — on a video the feed had already drawn a green members pill on.
///
/// `VideoDetail.isMembersOnly` is the structural half: it comes from
/// `BADGE_STYLE_TYPE_MEMBERS_ONLY` on the watch page, which YouTube does not
/// translate, and it rides on a `video.info` call this page already makes. So
/// either signal is enough.
///
/// **Gated on there being a failure at all.** The flag says what the video *is*,
/// not that it could not be played; without this, a members video that one day
/// resolves for an actual member would draw the slate over a playing stream.
/// Pure, and takes [detail] rather than a `WidgetRef`, so that the `ref.watch`
/// it needs happens in `build` where the widget's other subscriptions are
/// visible — a `ref.watch` buried in a free function is sound but leaves the
/// caller's subscription list unreadable from the caller.
@visibleForTesting
bool isMembersOnlyFailure(PlaybackState playback, VideoDetail? detail) {
  if (playback.error == null) return false;
  return playback.isMembersOnly || (detail?.isMembersOnly ?? false);
}

/// A members-only video: thumbnail, what it is, and where to join — never a
/// *Try again*, because retrying cannot buy a membership.
///
/// The same shape as [_PremiereSlate] deliberately. Both are videos that are
/// working exactly as intended and simply cannot be played *here, now*, and the
/// failure screen is the wrong answer to both.
///
/// **The wording avoids claiming the user is not a member**, because the app
/// cannot tell. Stream resolution is anonymous by design (`architecture.md`
/// §2.3), so a members-only video refuses even for someone who *is* a member —
/// what YouTube's own message says ("Join this channel…") is about the
/// anonymous session that asked, not about the person reading it. Saying "you
/// need to join" would be a guess, and wrong for exactly the paying members it
/// would insult.
class _MembersOnlySlate extends ConsumerWidget {
  const _MembersOnlySlate({required this.playback});

  final PlaybackState playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).tokens;
    final item = playback.item;
    final thumbnailUrl = item?.thumbnailUrl;
    // **Blank is absent, and the detail wins over the tile.**
    //
    // Rendered "This video is for members of ." on first run — a stray full
    // stop after nothing. `VideoItem.channelName` is a non-nullable `String`,
    // so a tile that never carried one holds `''`, and a `== null` check sails
    // straight past it. The launch-probe placeholder is one such tile; so is
    // any surface that builds an item before the name is known.
    //
    // `video.info` is preferred rather than used only as a fallback: this page
    // has already fetched it — the byline under the player is drawn from it —
    // and it is the authoritative name where the tile's is whatever the feed
    // happened to carry.
    final detail = item == null ? null : ref.watch(videoInfoProvider(item.id)).value;
    final channel = [
      detail?.channelName,
      item?.maybeMap(video: (v) => v.channelName, orElse: () => null),
    ].map((name) => name?.trim() ?? '').firstWhere((name) => name.isNotEmpty, orElse: () => '');

    return Stack(
      key: membersOnlySlateKey,
      fit: StackFit.expand,
      children: [
        if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) Image.network(thumbnailUrl, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, size: 14, color: membersGreenOnScrim),
                    const SizedBox(width: 5),
                    Text(
                      'MEMBERS ONLY',
                      style: TextStyle(
                        color: membersGreenOnScrim,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  channel.isEmpty ? 'This video is for channel members.' : 'This video is for members of $channel.',
                  style: TextStyle(
                    color: tokens.onScrim,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                // Disabled, exactly like the premiere reminder: joining a
                // channel is a purchase flow this app does not implement, and a
                // button that looks like it worked and did nothing is worse
                // than one that plainly cannot be pressed.
                FilledButton.icon(
                  key: membersOnlyJoinKey,
                  onPressed: null,
                  icon: const Icon(Icons.star_outline_rounded, size: 18),
                  label: const Text('Join this channel'),
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
                    isArtistChannel: detail?.isArtistChannel ?? item.isArtistChannel,
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
          initiallySubscribed: ref.watch(
                subscriptionActionsProvider.select((actions) => actions[detail?.channelId ?? item.channelId]),
              ) ??
              detail?.isSubscribed ??
              false,
          minHeight: 45,
          onSubscribe: (channelId) => _setSubscribed(context, ref, channelId, subscribe: true),
          onUnsubscribe: (channelId) => _setSubscribed(context, ref, channelId, subscribe: false),
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
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: scheme.onSurface),
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
    final signIn = subscribe ? 'Sign in to subscribe' : 'Sign in to unsubscribe';
    messenger.showSnackBar(SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? signIn : e.message)));
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
    final shortViews = exactViews == null ? null : formatCompactViews(exactViews);
    final date = detail?.publishedText ?? '';
    // Null whenever it would just repeat `date` — a layout with no relative
    // date at all falls back to the exact one for both fields (§ sidecar
    // `parser/video.ts`), and a tooltip that says exactly what is already on
    // screen is not a tooltip worth having.
    final exactDate = detail?.publishedDateText != null && detail!.publishedDateText != date ? detail.publishedDateText : null;
    final likes = detail?.likeText ?? 'Like';

    final rating =
        ref.watch(ratingActionsProvider.select((actions) => actions[item.id])) ?? detail?.myRating ?? VideoRating.none;
    final inWatchLater = ref.watch(watchLaterActionsProvider.select((actions) => actions[item.id])) ??
        (membership.value?.any((p) => p.id == 'WL' && p.containsVideo) ?? false);

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
                  child: _MetaStat(icon: Icons.visibility_outlined, text: shortViews),
                ),
        if (date.isNotEmpty)
          exactDate == null
              ? _MetaStat(icon: Icons.calendar_today_outlined, text: date)
              : ShortcutTooltip(
                  label: exactDate,
                  child: _MetaStat(icon: Icons.calendar_today_outlined, text: date),
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
                label: rating == VideoRating.like ? 'Remove like' : 'Like',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _ratingBusy ? null : () => _setRating(VideoRating.like),
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16, right: 12, top: 8, bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            rating == VideoRating.like ? Icons.thumb_up : Icons.thumb_up_outlined,
                            size: 18,
                            color: scheme.onSurface,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            likes,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 18, color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ShortcutTooltip(
                label: rating == VideoRating.dislike ? 'Remove dislike' : 'Dislike',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _ratingBusy ? null : () => _setRating(VideoRating.dislike),
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(18)),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 16, top: 8, bottom: 8),
                      child: Icon(
                        rating == VideoRating.dislike ? Icons.thumb_down : Icons.thumb_down_outlined,
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
            onTap: _openShare,
          ),
        ),

        // Playlist
        ShortcutTooltip(
          label: 'Save to playlist',
          child: _ActionChip(
            icon: Icons.playlist_add,
            activeIcon: Icons.playlist_add_check,
            activeLabel: 'Save',
            active: _sheet == _OpenSheet.save,
            onTap: _openSave,
          ),
        ),

        // Watch Later
        ShortcutTooltip(
          label: inWatchLater ? 'Remove from Watch Later' : 'Watch Later',
          child: _ActionChip(
            icon: Icons.schedule,
            activeIcon: Icons.check,
            activeLabel: 'Watch Later',
            active: inWatchLater && !_watchLaterSettled,
            marked: inWatchLater && _watchLaterSettled,
            onTap: () => _tapWatchLater(inWatchLater),
          ),
        ),

        // More
        ShortcutTooltip(
          label: 'More',
          child: _ActionChip(icon: Icons.more_horiz, semanticLabel: 'More', onTap: () {}),
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

  Future<void> _openShare() async {
    setState(() => _sheet = _OpenSheet.share);
    await showDialog<void>(
      context: context,
      builder: (_) => _ShareDialog(item: widget.item, position: _positionNow()),
    );
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
    return currentlyInWatchLater ? _removeFromWatchLater() : _saveToWatchLater();
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
    final actions = ref.read(watchLaterActionsProvider.notifier);
    final had = ref.read(watchLaterActionsProvider).containsKey(videoId);
    final previous = ref.read(watchLaterActionsProvider)[videoId];
    final container = ProviderScope.containerOf(context, listen: false);

    actions.set(videoId, true);
    setState(() => _savingWatchLater = true);

    String? failure;
    try {
      await RpcClient.instance.call('action.addToWatchLater', {'videoId': videoId});
    } on RpcException catch (e) {
      failure = e.code == 'AUTH_REQUIRED' ? 'Sign in to save to Watch Later' : e.message;
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

    if (!mounted || generation != _videoGeneration || widget.item.id != videoId) {
      return failure == null;
    }

    setState(() => _savingWatchLater = false);
    _say(failure ?? 'Saved to Watch Later');

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
      final response = await RpcClient.instance.call('playlist.forVideo', {'videoId': videoId}) as Map<String, dynamic>;
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
      failure = e.code == 'AUTH_REQUIRED' ? 'Sign in to edit Watch Later' : e.message;
    } catch (e) {
      failure = '$e';
    }

    if (failure != null) {
      actions.restore(videoId, had: had, previous: previous);
    } else {
      container.invalidate(playlistMembershipProvider(videoId));
    }

    if (!mounted || generation != _videoGeneration || widget.item.id != videoId) return;

    setState(() => _savingWatchLater = false);
    _say(failure ?? 'Removed from Watch Later');
  }

  /// Like, dislike and un-rate, all through one path: tapping the currently
  /// active side clears the rating, tapping the other switches straight to
  /// it. `action.dislike` while liked removes the like server-side on its
  /// own, so this never has to call `action.removeRating` first.
  Future<void> _setRating(VideoRating target) async {
    if (_ratingBusy) return;
    final videoId = widget.item.id;
    final generation = _videoGeneration;
    final actions = ref.read(ratingActionsProvider.notifier);
    final had = ref.read(ratingActionsProvider).containsKey(videoId);
    final previous = ref.read(ratingActionsProvider)[videoId];
    final current = previous ?? widget.info.value?.myRating ?? VideoRating.none;
    final next = current == target ? VideoRating.none : target;

    actions.set(videoId, next);
    setState(() => _ratingBusy = true);

    final method = switch (next) {
      VideoRating.like => 'action.like',
      VideoRating.dislike => 'action.dislike',
      VideoRating.none => 'action.removeRating',
    };

    String? failure;
    try {
      await RpcClient.instance.call(method, {'videoId': videoId});
    } on RpcException catch (e) {
      failure = e.code == 'AUTH_REQUIRED' ? 'Sign in to rate videos' : e.message;
    } catch (e) {
      failure = '$e';
    }

    // Undone in the store whatever became of this widget — a rating that failed
    // while the layout was switching must not stay drawn as set.
    if (failure != null) actions.restore(videoId, had: had, previous: previous);

    if (!mounted || generation != _videoGeneration || widget.item.id != videoId) return;

    setState(() => _ratingBusy = false);
    if (failure != null) _say(failure);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface),
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
        final background = Color.lerp(scheme.surfaceContainerHigh, scheme.inverseSurface, tint)!;
        final foreground = Color.lerp(scheme.onSurface, scheme.onInverseSurface, tint)!;

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
            side: edge == 0 ? BorderSide.none : BorderSide(color: scheme.inverseSurface.withValues(alpha: edge)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
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
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: foreground),
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

/// The share sheet (mock 4) + OS shows the system sharesheet.
///
/// Drawn **disabled**: we need `IDataTransferManagerInterop::ShowShareUIForWindow(HWND)`
/// WinRT interop through the runner.
class _ShareDialog extends StatefulWidget {
  const _ShareDialog({required this.item, required this.position});

  final VideoItem item;

  /// Where the video was when the dialog opened. `Duration.zero` when this is
  /// not the video that is playing, which is what hides "Start at".
  final Duration position;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  bool _startAt = false;

  /// The short form, because it is the one that survives being pasted into a
  /// chat client that eats query strings — and `?t=` is the only parameter
  /// anything here appends.
  String get _link {
    final base = 'https://youtu.be/${widget.item.id}';
    if (!_startAt) return base;
    return '$base?t=${widget.position.inSeconds}';
  }

  String get _embed {
    final start = _startAt ? '?start=${widget.position.inSeconds}' : '';
    return '<iframe width="560" height="315" '
        'src="https://www.youtube.com/embed/${widget.item.id}$start" '
        'title="${htmlEscape.convert(widget.item.title)}" frameborder="0" allowfullscreen></iframe>';
  }

  Future<void> _copy(String value, String said) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
  }

  // ignore: rill_lints/no_color_literals
  final faceBookColor = const Color(0xFF0866FF);
  // ignore: rill_lints/no_color_literals
  final xColor = const Color(0xFF000000);
  // ignore: rill_lints/no_color_literals
  final redditColor = const Color(0xFFFF4500);
  // ignore: rill_lints/no_color_literals
  final messagesColor = const Color(0xFFFFFFFF);
  // ignore: rill_lints/no_color_literals
  final telegramColor = const Color(0xFF0088CC);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.item.title;

    // Six targets at 56 + 12 of gutter fit the 460 the dialog is wide, so there
    // is no scroll and therefore no chevron. Mock 4 has one because YouTube's
    // row genuinely runs off the edge; drawing the affordance over content that
    // never moves would be worse than not drawing it.
    final targets = <Widget>[
      _ShareTarget(
        label: 'Embed',
        icon: Icons.code,
        onTap: () => _copy(_embed, 'Embed code copied'),
      ),
      _ShareTarget(
        label: 'X',
        hoverColor: xColor,
        iconBuilder: (color, _) => SizedBox(
          width: 21,
          height: 21,
          child: SvgPicture.asset(
            'assets/icons/x.svg',
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://x.com/intent/post'
          '?url=${Uri.encodeComponent(_link)}&text=${Uri.encodeComponent(title)}',
        ),
      ),
      _ShareTarget(
        label: 'Reddit',
        hoverColor: redditColor,
        iconBuilder: (color, isHovered) => SizedBox(
          width: 31,
          height: 31,
          child: SvgPicture.asset(
            'assets/icons/reddit.svg',
          ),
        ),
        onTap: () => _openInBrowser(
          'https://www.reddit.com/submit'
          '?url=${Uri.encodeComponent(_link)}&title=${Uri.encodeComponent(title)}',
        ),
      ),
      _ShareTarget(
        label: 'Facebook',
        hoverColor: faceBookColor,
        iconBuilder: (color, _) => SizedBox(
          width: 48,
          height: 48,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Transform.scale(
              scale: 1.35,
              child: SvgPicture.asset(
                'assets/icons/facebook.svg',
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
            ),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://www.facebook.com/sharer/sharer.php?u=${Uri.encodeComponent(_link)}',
        ),
      ),
      _ShareTarget(
        label: 'Messages',
        hoverColor: messagesColor,
        iconBuilder: (color, isHovered) => SizedBox(
          width: 48,
          height: 48,
          child: Padding(
            padding: const EdgeInsets.all(10).copyWith(top: 13),
            child: SvgPicture.asset(
              'assets/icons/messages.svg',
            ),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://messages.google.com/web/welcome?redirectUrl=${Uri.encodeComponent("/share?text=${Uri.encodeComponent(_link)}")}',
        ),
      ),
      _ShareTarget(
        label: 'Telegram',
        hoverColor: telegramColor,
        iconBuilder: (color, _) => SizedBox(
          width: 40,
          height: 40,
          child: SvgPicture.asset(
            'assets/icons/telegram.svg',
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://t.me/share/url'
          '?url=${Uri.encodeComponent(_link)}&text=${Uri.encodeComponent(title)}',
        ),
      ),
      _ShareTarget(
        label: 'Email',
        icon: Icons.mail_outline,
        onTap: () => _openInBrowser(
          'mailto:?subject=${Uri.encodeComponent(title)}&body=${Uri.encodeComponent(_link)}',
        ),
      ),
    ];

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 460,
        child: Padding(
          // The gutters live on each section rather than on the whole column:
          // the close button has to sit closer to the edge than the content
          // does, and a single outer padding cannot give it that.
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 12),
                child: Row(
                  children: [
                    const SizedBox(width: 36),
                    Expanded(
                      child: Text(
                        'Share',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 20),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Column(
                children: [
                  FilledButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share via Windows…'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Share this video using the OS share sheet.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  // Not "Share" a second time: the title already said it, and
                  // the label's job here is to separate the row that works from
                  // the button above it that does not yet.
                  'Send to',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  height: 70,
                  child: SilkyListView.builder(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    scrollDirection: Axis.horizontal,
                    itemBuilder: (context, index) => Padding(
                      padding: EdgeInsets.only(right: index == targets.length - 1 ? 0 : 6),
                      child: targets[index],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.only(left: 16, right: 6),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _link,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: scheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // The one white thing in the dialog, same as the mock and
                      // the same role the pills go to when they are on.
                      FilledButton(
                        onPressed: () => _copy(_link, 'Link copied'),
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.inverseSurface,
                          foregroundColor: scheme.onInverseSurface,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        ),
                        child: Transform.translate(offset: const Offset(0, -1), child: const Text('Copy')),
                      ),
                    ],
                  ),
                ),
              ),
              // Nothing to start at on a video that has not started, and nothing
              // to offer when the thing being shared is not the thing playing.
              if (widget.position > Duration.zero) ...[
                const SizedBox(height: 10),
                InkWell(
                  borderRadius: BorderRadius.only(bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
                  onTap: () => setState(() => _startAt = !_startAt),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _startAt,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (next) => setState(() => _startAt = next ?? false),
                        ),
                        const SizedBox(width: 8),
                        Text('Start at', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                        const SizedBox(width: 8),
                        Text(
                          formatClock(widget.position),
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One circle in the share row.
///
/// [glyph] exists for X, which is the one target in the row Material Icons has
/// no glyph for — the set ships `reddit`, `facebook` and `telegram` and simply
/// stops there. A letterform in the same circle is a better answer than an
/// approximate icon that means something else.
class _ShareTarget extends StatefulWidget {
  const _ShareTarget({
    required this.label,
    this.icon,
    this.iconBuilder,
    this.hoverColor,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final Widget Function(Color color, bool isHovered)? iconBuilder;
  final Color? hoverColor;
  final VoidCallback onTap;

  @override
  State<_ShareTarget> createState() => _ShareTargetState();
}

class _ShareTargetState extends State<_ShareTarget> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isHoverState = _isHovered && widget.hoverColor != null;
    final bg = isHoverState ? widget.hoverColor! : scheme.surfaceContainerHighest;
    // ignore: rill_lints/no_color_literals
    final iconColor = isHoverState ? const Color(0xFFFFFFFF) : scheme.onSurface;

    return SizedBox(
      width: 60,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bg,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onHover: (hovered) => setState(() => _isHovered = hovered),
                onTap: widget.onTap,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: widget.icon != null
                        ? Icon(widget.icon, size: 22, color: iconColor)
                        : widget.iconBuilder != null
                        ? widget.iconBuilder!(iconColor, _isHovered)
                        : Text(
                            widget.label,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: iconColor,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The last description measured, kept because these two `TextPainter.layout()`
/// calls are the most expensive thing on the page and they are not asked for
/// once per description — the aspect-ratio morph rebuilds this subtree on every
/// one of its ~18 frames, and text layout over a long description is not a
/// per-frame cost. One entry is enough: only one description is ever on screen.
({String text, TextStyle style, double width, double collapsed, double full, bool overflowing})? _descriptionMeasurement;

({double collapsed, double full, bool overflowing}) _measureDescription(
  String text,
  TextStyle style,
  double width,
) {
  final cached = _descriptionMeasurement;
  if (cached != null && cached.text == text && cached.style == style && cached.width == width) {
    return (collapsed: cached.collapsed, full: cached.full, overflowing: cached.overflowing);
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
  const _Description({required this.detail, required this.expanded, required this.onToggle});

  final VideoDetail detail;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = detail.description;
    if (description == null || description.isEmpty) return const SizedBox.shrink();

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
          final measured = _measureDescription(description, style, constraints.maxWidth);
          final collapsedHeight = measured.collapsed;
          final isOverflowing = measured.overflowing;
          final fullHeight = measured.full;

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
              linkStyle: style.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
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
                  final isFullyCollapsed = height == collapsedHeight && !expanded;
                  return SizedBox(
                    height: height,
                    child: ClipRect(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: isFullyCollapsed ? collapsedTextWidget : fullTextWidget,
                      ),
                    ),
                  );
                },
              ),
              if (isOverflowing || expanded) ...[
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
    if (oldWidget.text != widget.text || oldWidget.baseStyle != widget.baseStyle || oldWidget.linkStyle != widget.linkStyle) {
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
        spans.add(TextSpan(text: widget.text.substring(start, match.start), style: widget.baseStyle));
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()..onTap = () => _openInBrowser(url);
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
      spans.add(TextSpan(text: widget.text.substring(start), style: widget.baseStyle));
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
