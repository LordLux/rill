import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../auth_controller.dart';
import '../playlist_controller.dart';
import '../queue_controller.dart';
import '../widgets/media_tile.dart';
import '../widgets/share_dialog.dart';
import '../widgets/shortcut_tooltip.dart';
import '../page_wrapper.dart';
import '../player_shell.dart' show rootNavigatorKey;
import '../open_video.dart';
import '../focus_surface.dart';
import '../../theme/screen_values.dart';
import '../../theme/tokens.dart';
import '../../domain/artist_panel.dart';

const String playlistRouteName = 'playlist';

/// Pushes a playlist's page, the same way `openSearch` pushes the results page.
///
/// **A named page route, and that is the point.** `RouteTracker` reports a
/// route by its name: an unnamed one reads as "no route", which hid the back
/// arrow on this page and lit Home in the rail. Whatever was showing stays
/// mounted underneath, the watch page included, so Back returns to it.
void openPlaylistPage(String playlistId) {
  rootNavigatorKey.currentState?.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: playlistRouteName),
      builder: (_) => PlaylistPage(playlistId: playlistId),
    ),
  );
}

class PlaylistPage extends ConsumerStatefulWidget {
  const PlaylistPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  final _scrollController = ScrollController();

  /// At this page width or less the header sits above the list, not beside it.
  static const double _narrowBreakpoint = 950;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 400) {
      ref.read(playlistProvider(widget.playlistId).notifier).loadNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlistState = ref.watch(playlistProvider(widget.playlistId));

    return PageWrapper(
      title: const Text('Playlist'),
      // The wrapper paints the page's ground from it too, so it fades in and
      // out with the title bar when the page changes.
      tint: _PlaylistTint.of(context, playlistState.value?.header).wash,
      body: playlistState.when(
        // A re-read after a sign-in or sign-out keeps the page it has until the
        // new one lands, instead of dropping back to the skeleton.
        skipLoadingOnReload: true,
        data: (state) => _PlaylistContent(state: state, scrollController: _scrollController),
        loading: () => const _PlaylistSkeleton(),
        error: (e, st) => Center(child: Text(e.toString())),
      ),
    );
  }
}

/// How long the playlist's tint takes to arrive, so it never pops in.
const Duration _tintFade = Duration(milliseconds: 500);

/// The colours the page takes from the playlist: YouTube's own tint for it
/// (`PlaylistHeader.backgroundColor`), and what stays legible on top of it.
class _PlaylistTint {
  const _PlaylistTint({
    required this.card,
    required this.page,
    required this.wash,
    required this.cardFoot,
    required this.on,
    required this.onInverse,
    required this.artGround,
  });

  factory _PlaylistTint.of(BuildContext context, PlaylistHeader? header) {
    final theme = Theme.of(context);
    final page = theme.scaffoldBackgroundColor;
    final themed = header?.backgroundColor?.resolve(theme.brightness);
    // No tint in the payload reads as an ordinary raised card on a plain page.
    final card = themed ?? theme.colorScheme.surfaceContainerHigh;
    final dark = ThemeData.estimateBrightnessForColor(card) == Brightness.dark;
    return _PlaylistTint(
      card: card,
      page: page,
      wash: themed == null ? page : Color.lerp(page, themed, 0.4)!,
      // YouTube's own last stop: the page on a dark theme, the tint again on a
      // light one, where fading out would leave light text on a light ground.
      cardFoot: theme.brightness == Brightness.dark ? page : card.withValues(alpha: 0.8),
      on: dark ? theme.tokens.onScrim : theme.tokens.onPaleTint,
      onInverse: dark ? theme.tokens.onPaleTint : theme.tokens.onScrim,
      artGround: theme.tokens.scrim.withValues(alpha: 0.22),
    );
  }

  /// The top of the header card, at full strength.
  final Color card;

  /// The page's own background, which both gradients fade into.
  final Color page;

  /// What the page hands its wrapper to tint the title bar, the rail and the
  /// top of its ground with: [card], mostly washed out.
  final Color wash;

  /// Where the header card's gradient ends.
  final Color cardFoot;

  /// Text and icons on [card], and what goes on a button filled with them.
  final Color on;
  final Color onInverse;

  /// Behind the artwork, where it does not fill its box.
  final Color artGround;

  Color get onMuted => on.withValues(alpha: 0.72);

  /// What lies over the header card's blurred artwork — YouTube's own stops
  /// for it (`gradientColorConfig`): the tint at 80%, at 30% a third of the way
  /// down, then [cardFoot].
  LinearGradient get cardGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [card.withValues(alpha: 0.8), card.withValues(alpha: 0.3), cardFoot],
    stops: const [0.0, 0.33, 1.0],
  );
}

class _PlaylistContent extends ConsumerWidget {
  const _PlaylistContent({required this.state, required this.scrollController});
  final PlaylistState state;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = state.header;
    if (header == null && state.items.isEmpty) {
      if (state.loading) return const _PlaylistSkeleton();
      // The first page never arrived: there is no header to draw the page around.
      if (state.error case final error?) {
        return _PlaylistUnavailable(
          message: error,
          onRetry: () => ref.read(playlistProvider(state.playlistId).notifier).retry(),
        );
      }
    }

    Widget headerFor({required bool beside}) => FocusTraversalOrder(
      order: PlaylistFocusOrder.header,
      child: _PlaylistHeaderWidget(
        playlistId: state.playlistId,
        header: header,
        title: state.title,
        videoCount: state.videoCount,
        fillHeight: beside,
      ),
    );

    // The page's own width, not the window's: the rail takes its share first.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > _PlaylistPageState._narrowBreakpoint) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 360, child: headerFor(beside: true)),
                  Expanded(
                    child: FocusTraversalOrder(
                      order: PlaylistFocusOrder.list,
                      child: _PlaylistList(state: state, scrollController: scrollController),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return SilkyCustomScrollView(
          controller: scrollController,
          slivers: [
            SliverToBoxAdapter(child: headerFor(beside: false)),
            // A sliver cannot sit under `FocusTraversalOrder`; its rows carry the order themselves.
            _PlaylistSliverList(state: state),
          ],
        );
      },
    );
  }
}

/// A blurred, enlarged copy of the artwork, as a ground for something sharper.
///
/// Decoded small, because the blur discards the detail anyway. The clip is the
/// outermost layer and the raster cache keeps the result: a blur paints past
/// its own box, and re-running one per frame of a scroll is the expensive part.
class _BlurredArt extends StatelessWidget {
  const _BlurredArt({required this.url, required this.scale, required this.sigma});

  final String url;
  final double scale;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: RepaintBoundary(
          child: Transform.scale(
            scale: scale,
            child: ImageFiltered(
              // Clamped, or the edges blur towards transparent black.
              imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
              child: Image.network(
                url,
                fit: BoxFit.cover,
                cacheWidth: 160,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The playlist's card: artwork, title, owner, counts and its actions, over
/// the playlist's own tint and a blur of its artwork.
class _PlaylistHeaderWidget extends ConsumerWidget {
  const _PlaylistHeaderWidget({
    required this.playlistId,
    required this.header,
    required this.title,
    required this.videoCount,
    required this.fillHeight,
  });

  final String playlistId;
  final PlaylistHeader? header;
  final String? title;
  final int? videoCount;

  /// Beside the list: the card runs the height of the page and scrolls inside
  /// itself. Above the list it is as tall as what it holds.
  final bool fillHeight;

  /// From this inner width the artwork sits beside the text instead of over it.
  static const double _sideBySideWidth = 560;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tint = _PlaylistTint.of(context, header);
    final art = header?.thumbnailUrl;

    final body = Padding(
      padding: const EdgeInsets.all(22),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final art = _art(tint);
          final details = _details(context, ref, tint);
          if (constraints.maxWidth < _sideBySideWidth) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [art, const SizedBox(height: 18), details],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 300, child: art),
              const SizedBox(width: 24),
              Expanded(child: details),
            ],
          );
        },
      ),
    );

    return Padding(
      padding: fillHeight ? const EdgeInsets.fromLTRB(12, 12, 4, 12) : const EdgeInsets.fromLTRB(12, 12, 12, 4),
      // The card clips, so a button's tooltip is kept inside it.
      child: TooltipBounds(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          clipBehavior: Clip.antiAliasWithSaveLayer,
          // YouTube's cinematic header, layer for layer: the tint, a blurred and
          // enlarged copy of the artwork, the gradient, then the content.
          child: Stack(
            children: [
              Positioned.fill(child: AnimatedContainer(duration: _tintFade, color: tint.card)),
              if (art != null) Positioned.fill(child: _BlurredArt(url: art, scale: 1.6, sigma: 24)),
              Positioned.fill(
                child: AnimatedContainer(
                  duration: _tintFade,
                  decoration: BoxDecoration(gradient: tint.cardGradient),
                ),
              ),
              fillHeight ? SilkySingleChildScrollView(child: body) : body,
            ],
          ),
        ),
      ),
    );
  }

  /// The playlist's artwork, whole. Where it does not fill its box — square
  /// cover art — a blurred, enlarged copy of itself does, under a light scrim.
  Widget _art(_PlaylistTint tint) {
    final url = header?.thumbnailUrl;
    return ClipRRect(
      clipBehavior: Clip.antiAliasWithSaveLayer,
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: ScreenValues.normalAspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null) _BlurredArt(url: url, scale: 1.6, sigma: 14),
            ColoredBox(color: tint.artGround),
            if (url != null)
              Image.network(
                url,
                fit: BoxFit.contain,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }

  /// "Playlist • 135 videos • 4,692,461 views". A public playlist does not say
  /// so; any other visibility does.
  String _meta() {
    final visibility = header?.visibility;
    final count = videoCount;
    return [
      'Playlist',
      if (visibility != null && visibility.isNotEmpty && visibility.toLowerCase() != 'public') visibility[0].toUpperCase() + visibility.substring(1),
      if (count != null) count == 1 ? '1 video' : '$count videos',
      ?header?.viewCountText,
    ].join(' • ');
  }

  Widget _details(BuildContext context, WidgetRef ref, _PlaylistTint tint) {
    final owner = header?.ownerName;
    final avatar = header?.ownerAvatarUrl;
    final description = header?.description;
    final ownerStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tint.on);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NoTabSelectionArea(
          child: Text(
            title ?? '',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 24, height: 1.2, fontWeight: FontWeight.w700, color: tint.on),
          ),
        ),
        if (owner != null && owner.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              if (avatar != null) ...[
                CircleAvatar(
                  radius: 12,
                  backgroundColor: tint.on.withValues(alpha: 0.12),
                  backgroundImage: NetworkImage(avatar),
                  onBackgroundImageError: (error, stackTrace) {},
                ),
                const SizedBox(width: 8),
              ],
              Text('by ', style: ownerStyle),
              Flexible(
                child: NoTabSelectionArea(
                  child: Text(
                    owner,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ownerStyle,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        NoTabSelectionArea(child: Text(_meta(), style: TextStyle(fontSize: 12.5, color: tint.onMuted))),
        const SizedBox(height: 18),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: _actions(context, ref, tint),
        ),
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(description, style: TextStyle(fontSize: 13, height: 1.4, color: tint.onMuted)),
        ],
      ],
    );
  }

  /// "Play all" as the one filled button, and the rest as round ones beside it.
  Widget _actions(BuildContext context, WidgetRef ref, _PlaylistTint tint) {
    // [unavailable] is what the bubble says for an action that is not built yet;
    // the icon carries the button's name either way.
    Widget round(IconData icon, String name, {String? unavailable, VoidCallback? onPressed}) => ShortcutTooltip(
      label: unavailable ?? name,
      silent: true,
      announce: unavailable != null,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 24, semanticLabel: name),
        style: IconButton.styleFrom(
          fixedSize: const Size.square(40),
          foregroundColor: tint.on,
          backgroundColor: tint.on.withValues(alpha: 0.12),
          disabledForegroundColor: tint.on.withValues(alpha: 0.38),
          disabledBackgroundColor: tint.on.withValues(alpha: 0.06),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow_rounded, size: 30),
                label: const Text('Play all'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(40, 46),
                  backgroundColor: tint.on,
                  foregroundColor: tint.onInverse,
                  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                onPressed: () => unawaited(
                  startPlaylistFromTile(context, ref, playlistId, title: title, videoCount: videoCount),
                ),
              ),
            ),
            const SizedBox(width: 8),
            round(Icons.bookmark_border, 'Save playlist', unavailable: 'Save is not available yet'),
            const SizedBox(width: 8),
            round(Icons.reply, 'Share', onPressed: () => unawaited(showPlaylistShareDialog(context, playlistId: playlistId, title: title ?? 'Playlist'))),
            const SizedBox(width: 8),
            round(Icons.shuffle, 'Shuffle', unavailable: 'Shuffle is not available yet'),
          ],
        ),
        // Masked the moment there is no account, not when the re-read lands.
        if (header?.isOwnedByViewer == true && ref.watch(authIdentityProvider.select((identity) => identity.$1))) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              round(Icons.add, 'Add videos', unavailable: 'Add videos is not available yet'),
              const SizedBox(width: 8),
              round(Icons.edit_outlined, 'Edit playlist', unavailable: 'Edit is not available yet'),
            ],
          ),
        ],
      ],
    );
  }

}

/// The page before its first response: the header card and a column of rows,
/// where the real ones will be.
///
/// One controller and one [FadeTransition] over the lot, as `FeedSkeleton` does
/// it and for the same reason: nothing below it rebuilds to pulse.
class _PlaylistSkeleton extends StatefulWidget {
  const _PlaylistSkeleton();

  @override
  State<_PlaylistSkeleton> createState() => _PlaylistSkeletonState();
}

class _PlaylistSkeletonState extends State<_PlaylistSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  ).drive(Tween<double>(begin: 0.45, end: 1.0));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final block = scheme.surfaceContainerHighest;

    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(4)),
    );

    Widget card({required bool beside}) => Padding(
      padding: beside ? const EdgeInsets.fromLTRB(12, 12, 4, 12) : const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Container(
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(15)),
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: beside ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 316),
              child: AspectRatio(
                aspectRatio: ScreenValues.normalAspectRatio,
                child: Container(
                  decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 18),
            bar(220, 24),
            const SizedBox(height: 12),
            bar(120, 13),
            const SizedBox(height: 8),
            bar(180, 12),
            const SizedBox(height: 18),
            bar(160, 46),
          ],
        ),
      ),
    );

    Widget row() => SizedBox(
      height: _PlaylistSliverList._rowMinHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const SizedBox(width: 48),
            Container(
              width: _PlaylistSliverList._thumbnailHeight * ScreenValues.normalAspectRatio,
              height: _PlaylistSliverList._thumbnailHeight,
              decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(12)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [bar(260, 16), const SizedBox(height: 10), bar(140, 12), const SizedBox(height: 14), bar(90, 12)],
              ),
            ),
          ],
        ),
      ),
    );

    // As many rows as fit, cut off at the bottom: the list that replaces them scrolls.
    Widget rows() => ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        maxHeight: double.infinity,
        child: Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 12; i++) row()]),
      ),
    );

    // Said once; the blocks are pictures of nothing.
    return Semantics(
      label: 'Loading playlist',
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: _pulse,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth > _PlaylistPageState._narrowBreakpoint) {
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 360, child: card(beside: true)),
                        Expanded(child: rows()),
                      ],
                    ),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [card(beside: false), Expanded(child: rows())],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The page when its first request failed: what was said, and a way to ask again.
class _PlaylistUnavailable extends StatelessWidget {
  const _PlaylistUnavailable({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: scheme.error, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurface)),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class _PlaylistList extends ConsumerWidget {
  const _PlaylistList({required this.state, required this.scrollController});
  final PlaylistState state;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SilkyCustomScrollView(
      controller: scrollController,
      slivers: [
        _PlaylistSliverList(state: state),
      ],
    );
  }
}

class _PlaylistSliverList extends ConsumerWidget {
  const _PlaylistSliverList({required this.state});
  final PlaylistState state;

  /// A row's thumbnail, and the row that just holds it: the thumbnail plus the
  /// tile's own padding and the row's.
  static const double _thumbnailHeight = 113;
  static const double _rowMinHeight = 145;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == state.items.length) {
            if (state.error != null) {
              return Center(
                child: Column(
                  children: [
                    Text(state.error!),
                    TextButton(
                      onPressed: () => ref.read(playlistProvider(state.playlistId).notifier).retry(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }
            if (state.loading) return const Center(child: CircularProgressIndicator());
            return const SizedBox.shrink();
          }

          final item = state.items[index];
          final spec = specFor(item)!;
          final tile = Center(
            child: ConstrainedBox(
              // The least a row is; a title on two lines makes its own row taller.
              constraints: const BoxConstraints(minHeight: _rowMinHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: MediaTile.wide(
                        spec: spec,
                        size: MediaTileSize.large,
                        thumbnailWidth: _thumbnailHeight * (spec.isShort ? ScreenValues.shortAspectRatioSecondary : ScreenValues.normalAspectRatio),
                        onAddToQueue: () => queueFromTile(ref, item),
                        onWatchLater: () => addToWatchLater(context, item),
                        menu: menuForTile(context, ref, item, spec),
                        // The tile's own path, from this row: the watch page opens, a
                        // replaced queue can be undone, and a failure is said.
                        onTap: () => unawaited(
                          startPlaylistFromTile(
                            context,
                            ref,
                            state.playlistId,
                            title: state.title,
                            videoCount: state.videoCount,
                            loadedItems: state.items,
                            continuation: state.continuation,
                            startIndex: index,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          return FocusTraversalOrder(
            order: PlaylistFocusOrder.list,
            child: tile,
          );
        },
        childCount: state.items.length + (state.continuation != null || state.error != null || state.loading ? 1 : 0),
      ),
    );
  }
}
