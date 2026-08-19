import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
import '../playback_controller.dart';
import '../player/controls.dart';
import '../player/view_mode.dart';
import '../queue_controller.dart';
import '../video_info.dart';
import '../widgets/media_tile.dart';
import '../widgets/queue_panel.dart';

/// Where the two sizing rules meet — architecture §2.8
const double _referenceAspect = 16 / 9;

const Key premiereSlateKey = ValueKey('premiere-slate');
const Key premiereNotifyKey = ValueKey('premiere-notify');

/// The aspect ratio of the frames actually being decoded, **held across a switch**.
///
/// An undecoded pair is the absence of a value, not 16:9, so the last real ratio
/// stands until the next one arrives — architecture §2.8. [_referenceAspect] is
/// only the answer before anything has decoded.
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
      actions: const [],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final theatre = ref.watch(playerViewProvider.select((view) => view.theatre));
          final detail = info.value;
          final actualAspectRatio = ref.watch(_aspectRatioProvider).value ?? (16 / 9);
          final queueHasItems = ref.watch(queueProvider.select((q) => q.items.length > 1));

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: actualAspectRatio),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, aspectRatio, _) {
              double railWidth = 0;
              double mainContainerWidth = constraints.maxWidth;
              final isDesktop = constraints.maxWidth >= 889;

              final double maxTheaterWidth = 1280.0 + 453.0 + 24.0 * 3;
              if (isDesktop) {
                final maxAllowedWidth = theatre ? maxTheaterWidth : 1950.0;
                final effectiveWidth = math.min(constraints.maxWidth, maxAllowedWidth);
                if (effectiveWidth >= 1042.0) {
                  railWidth = 453.0;
                } else {
                  railWidth = math.max(300.0, effectiveWidth - 589.0);
                }
                mainContainerWidth = effectiveWidth - railWidth;
              }

              final viewportHeight = MediaQuery.of(context).size.height;
              final maxPlayerHeight = math.max(480.0, viewportHeight - 169.0);

              final isTwoColumn = isDesktop;
              final normalPlayerWidth = mainContainerWidth - 32;

              // Whether the player is constrained by height rather than width.
              //The two rules meet at 16:9, so the reference is that.
              final heightBound = aspectRatio < _referenceAspect;

              final double playerWidth;
              final double playerHeight;
              if (heightBound) {
                final tallest = math.min(maxPlayerHeight, math.max(480.0, viewportHeight - 169.0));
                final widest = tallest * aspectRatio;
                // The clamp matters just under 16:9, where the full available
                // height would ask for more width than the column has. Without
                // it the fix would trade an overflow at the bottom for one at
                // the right.
                if (widest <= normalPlayerWidth) {
                  playerHeight = tallest;
                  playerWidth = widest;
                } else {
                  playerWidth = normalPlayerWidth;
                  playerHeight = normalPlayerWidth / aspectRatio;
                }
              } else {
                playerWidth = normalPlayerWidth;
                playerHeight = normalPlayerWidth / aspectRatio;
              }

              // Calculate player width and height for theatre mode (constrained within constraints.maxWidth x maxPlayerHeight)
              double theatreWidth = constraints.maxWidth;
              double theatreHeight = theatreWidth / aspectRatio;
              if (theatreHeight > maxPlayerHeight) {
                theatreHeight = maxPlayerHeight;
                theatreWidth = theatreHeight * aspectRatio;
              }

              final embeddedQueue = queueHasItems ? EmbeddedQueuePanel(maxHeight: playerHeight) : const SizedBox.shrink();

              final playerWidget = Center(
                child: SizedBox(
                  height: playerHeight,
                  width: playerWidth,
                  child: _PlayerSurface(
                    playback: playback,
                    actualAspectRatio: aspectRatio,
                  ),
                ),
              );

              final metadataColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!theatre)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
                      child: playerWidget,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
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
                        if (!isTwoColumn) ...[
                          const SizedBox(height: 24),
                          embeddedQueue,
                          ..._relatedSection(detail, item.id, asGrid: true),
                        ],
                      ],
                    ),
                  ),
                ],
              );

              final mainContent = isTwoColumn
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: mainContainerWidth,
                          child: metadataColumn,
                        ),
                        SizedBox(
                          key: const ValueKey('related-rail'),
                          width: railWidth,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(8, theatre ? 8 : 2, 16, 32),
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
                    )
                  : metadataColumn;

              return SilkyListView(
                padding: EdgeInsets.zero,
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (theatre)
                    Container(
                      color: Theme.of(context).tokens.scrim,
                      alignment: Alignment.center,
                      height: theatreHeight,
                      child: SizedBox(
                        height: theatreHeight,
                        width: theatreWidth,
                        child: _PlayerSurface(
                          playback: playback,
                          rounded: false,
                          actualAspectRatio: aspectRatio,
                        ),
                      ),
                    ),
                  mainContent,
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
          if (!fullscreen) engine.videoSurface(),

          if (playback.isLoading) Center(child: CircularProgressIndicator(color: scheme.onPrimary)),
          // A premiere is not a failure, so it does not get the failure screen.
          if (playback.isUpcoming) _PremiereSlate(playback: playback) else if (playback.error != null) _Unavailable(playback: playback),

          if (playback.error == null && !playback.isLoading && !fullscreen) PlayerControls(engine: engine, actualAspectRatio: ratio),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionArea(
          child: Text(
            title,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: scheme.onSurface),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              Row(
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
                            // TODO verified/music artist badge
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
                  FilledButton.tonal(
                    onPressed: () {},
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.surfaceContainerHighest,
                      foregroundColor: scheme.onSurface,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                      minimumSize: const Size(0, 45),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.notifications_active_outlined, size: 18),
                        SizedBox(width: 6),
                        Text('Subscribed'),
                        SizedBox(width: 6),
                        Icon(Icons.keyboard_arrow_down, size: 18),
                      ],
                    ),
                  ),
                ],
              ),
              _Actions(item: item, info: info),
            ],
          ),
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

  /// Optimistic — it leads the round trip, and a failure moves it back.
  ///
  /// **"You saved it just now", not "is saved".** The actions surface is
  /// write-only today (protocol §3.4), so a video saved last week opens
  /// unlatched. When the protocol can report it, this becomes real state seeded
  /// from `video.info` — and the two workarounds beside it go at the same time.
  // TODO(protocol §3.4): seed from `videoDetail.inWatchLater` once it exists.
  bool _inWatchLater = false;

  /// A save in flight, so a second tap cannot land on a pill that only looks
  /// saved while the first is still in the air.
  bool _savingWatchLater = false;

  /// Bumped whenever the video changes, to invalidate replies still in the air.
  int _saveGeneration = 0;

  /// The white has had its moment and stepped back.
  ///
  /// The pill answers the click for two seconds, then is only recording a
  /// status — and that much white sitting in the row for the rest of the video
  /// reads as an alert about something that already went fine. So it settles to
  /// the dark fill, keeping the tick and the white as an edge.
  bool _watchLaterSettled = false;
  Timer? _settleTimer;

  @override
  void didUpdateWidget(_Actions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id == widget.item.id) return;
    _saveGeneration++;
    _sheet = null;
    _inWatchLater = false;
    _savingWatchLater = false;
    _watchLaterSettled = false;
    _settleTimer?.cancel();
    _settleTimer = null;
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

    final views = detail?.viewCountText ?? item.viewCountText ?? '';
    final date = detail?.publishedText ?? '';
    final likes = detail?.likeText ?? 'Like';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Views
        if (views.isNotEmpty) ...[
          Icon(Icons.visibility_outlined, size: 18, color: scheme.onSurface),
          const SizedBox(width: 6),
          SelectionArea(
            child: Text(
              views,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface),
            ),
          ),
          const SizedBox(width: 16),
        ],

        // Date
        if (date.isNotEmpty) ...[
          Icon(Icons.calendar_today_outlined, size: 18, color: scheme.onSurface),
          const SizedBox(width: 6),
          SelectionArea(
            child: Text(
              date,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface),
            ),
          ),
          const SizedBox(width: 16),
        ],

        // Like & Dislike
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {},
                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16, right: 12, top: 8, bottom: 8),
                    child: Row(
                      children: [
                        Icon(Icons.thumb_up_outlined, size: 18, color: scheme.onSurface),
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
              Container(width: 1, height: 18, color: scheme.outlineVariant.withValues(alpha: 0.5)),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {},
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(18)),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 16, top: 8, bottom: 8),
                    child: Icon(Icons.thumb_down_outlined, size: 18, color: scheme.onSurface),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Share
        _ActionChip(
          icon: Icons.reply,
          activeLabel: 'Share',
          active: _sheet == _OpenSheet.share,
          onTap: _openShare,
        ),

        // Playlist
        _ActionChip(
          icon: Icons.playlist_add,
          activeIcon: Icons.playlist_add_check,
          activeLabel: 'Save',
          active: _sheet == _OpenSheet.save,
          onTap: _openSave,
        ),

        // Watch Later
        _ActionChip(
          icon: Icons.schedule,
          activeIcon: Icons.check,
          activeLabel: 'Watch Later',
          active: _inWatchLater && !_watchLaterSettled,
          marked: _inWatchLater && _watchLaterSettled,
          onTap: _tapWatchLater,
        ),

        // More
        _ActionChip(icon: Icons.more_horiz, semanticLabel: 'More', onTap: () {}),

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
    setState(() => _sheet = _OpenSheet.save);
    await showDialog<void>(
      context: context,
      builder: (_) => _SaveDialog(
        inWatchLater: _inWatchLater,
        onWatchLater: _saveToWatchLater,
      ),
    );
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

  /// The pill — distinct from [_saveToWatchLater] because the second tap is not a second save.
  /// `action.addToWatchLater` has no inverse (protocol §3.4), so
  /// a latched pill says so rather than quietly re-adding.
  // TODO(protocol §3.4): make this a real toggle once a removal method exists.
  Future<void> _tapWatchLater() async {
    if (_savingWatchLater) return;
    if (_inWatchLater) {
      _say('Already in Watch Later — removing is not wired up yet');
      return;
    }
    await _saveToWatchLater();
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
    final generation = _saveGeneration;
    setState(() {
      _inWatchLater = true;
      _savingWatchLater = true;
    });

    String? failure;
    try {
      await RpcClient.instance.call('action.addToWatchLater', {'videoId': videoId});
    } on RpcException catch (e) {
      failure = e.code == 'AUTH_REQUIRED' ? 'Sign in to save to Watch Later' : e.message;
    } catch (e) {
      failure = '$e';
    }

    if (!mounted || generation != _saveGeneration || widget.item.id != videoId) {
      return failure == null;
    }

    setState(() {
      _savingWatchLater = false;
      if (failure != null) _inWatchLater = false;
    });
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

/// Save to a playlist.
/// **Only the first row is real** — the protocol has `action.addToPlaylist` but
/// no `playlist.list` to populate the rest (protocol §3.4).
/// The rows below tick without saving, and the line at the bottom says so.
// TODO(protocol §3.4): build these rows from `playlist.list` once it exists.
class _SaveDialog extends StatefulWidget {
  const _SaveDialog({required this.inWatchLater, required this.onWatchLater});

  final bool inWatchLater;

  /// Answers whether the save landed, so a failed tick can be put back.
  final Future<bool> Function() onWatchLater;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late bool _watchLater = widget.inWatchLater;

  /// Layout stand-ins. Delete the moment a `playlist.list` method exists — they
  /// are here to size the dialog, not to be shipped as a feature.
  static const List<({String name, bool private})> _placeholders = [
    (name: 'Favourites', private: true),
    (name: 'Music to code to', private: false),
    (name: 'Watch on the TV', private: true),
  ];

  final Set<String> _ticked = {};

  Future<void> _toggleWatchLater(bool next) async {
    if (!next) {
      // Same missing inverse the pill runs into — see `_tapWatchLater`.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Removing from Watch Later is not wired up yet')));
      return;
    }
    setState(() => _watchLater = true);
    final saved = await widget.onWatchLater();
    if (!saved && mounted) setState(() => _watchLater = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Save video to…',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Bounded and scrollable rather than however tall the account
              // happens to be. An account with forty playlists is not unusual,
              // and a dialog that grows to the height of one of those is a
              // dialog with its footer off the bottom of the window.
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SaveRow(
                          name: 'Watch later',
                          private: true,
                          ticked: _watchLater,
                          onChanged: _toggleWatchLater,
                        ),
                        for (final playlist in _placeholders)
                          _SaveRow(
                            name: playlist.name,
                            private: playlist.private,
                            ticked: _ticked.contains(playlist.name),
                            onChanged: (next) => setState(() {
                              if (next) {
                                _ticked.add(playlist.name);
                              } else {
                                _ticked.remove(playlist.name);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton.icon(
                  // Nowhere to create it. `action.addToPlaylist` takes a
                  // playlistId it cannot mint.
                  onPressed: null,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New playlist'),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Only Watch later saves; the rest are placeholders.',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaveRow extends StatelessWidget {
  const _SaveRow({
    required this.name,
    required this.private,
    required this.ticked,
    required this.onChanged,
  });

  final String name;
  final bool private;
  final bool ticked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => onChanged(!ticked),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Row(
          children: [
            Checkbox(
              value: ticked,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (next) => onChanged(next ?? false),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: scheme.onSurface),
              ),
            ),
            Icon(
              private ? Icons.lock_outline : Icons.public,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
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
