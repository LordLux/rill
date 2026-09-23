import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';

import '../../domain/video_detail.dart';
import '../../domain/feed_item.dart';
import '../../theme/tokens.dart';
import '../audio_mode_controller.dart';
import 'audio_mode_view.dart';
import '../playback_controller.dart';
import '../video_info.dart';

const Key premiereSlateKey = ValueKey('premiere-slate');
const Key premiereNotifyKey = ValueKey('premiere-notify');
const Key membersOnlySlateKey = ValueKey('members-only-slate');
const Key membersOnlyJoinKey = ValueKey('members-only-join');

/// what arrives when `video.info` has not answered yet or carried no timestamp.
@visibleForTesting
String premiereText(int? premiereAtMs, String? fallback) {
  if (premiereAtMs == null) return fallback ?? 'Premieres soon';
  final at = DateTime.fromMillisecondsSinceEpoch(premiereAtMs).toLocal();
  final time = TimeOfDay.fromDateTime(at);
  final minute = time.minute.toString().padLeft(2, '0');
  return 'Premieres ${at.day}/${at.month}/${at.year} at ${time.hour}:$minute';
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

/// A video that has not premiered yet: thumbnail, date and a reminder, never a
/// *Try again* — nothing is wrong with it, it has a start time.
///
/// The time comes from `video.info` (`premiereAtMs`), falling back to YouTube's
/// own prose on the error message ("Premieres in 9 days"). One of the two is
/// always present, which is why this need not wait on `video.info` to draw.
class PremiereSlate extends ConsumerWidget {
  const PremiereSlate({super.key, required this.playback});

  final PlaybackState playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.tokens;
    final item = playback.item;
    final detail = item == null
        ? null
        : ref.watch(videoInfoProvider(item.id)).value;
    final premiereAt = detail?.premiereAtMs;
    final thumbnailUrl = item?.thumbnailUrl;

    return Stack(
      key: premiereSlateKey,
      fit: StackFit.expand,
      children: [
        // The thumbnail YouTube shows in place of the video. `contain` rather
        // than `cover`: a 16:9 thumbnail in a 16:9 box is the same either way,
        // and anything else loses its edges rather than its bars.
        if (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
          Image.network(
            thumbnailUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
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
class MembersOnlySlate extends ConsumerWidget {
  const MembersOnlySlate({super.key, required this.playback});

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
    final detail = item == null
        ? null
        : ref.watch(videoInfoProvider(item.id)).value;
    final channel =
        [
              detail?.channelName,
              item?.maybeMap(video: (v) => v.channelName, orElse: () => null),
            ]
            .map((name) => name?.trim() ?? '')
            .firstWhere((name) => name.isNotEmpty, orElse: () => '');

    return Stack(
      key: membersOnlySlateKey,
      fit: StackFit.expand,
      children: [
        if (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
          Image.network(
            thumbnailUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
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
                    Icon(
                      Icons.star_rounded,
                      size: 14,
                      color: tokens.membersOnScrim,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'MEMBERS ONLY',
                      style: TextStyle(
                        color: tokens.membersOnScrim,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  channel.isEmpty
                      ? 'This video is for channel members.'
                      : 'This video is for members of $channel.',
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

class UnavailableSlate extends ConsumerWidget {
  const UnavailableSlate({super.key, required this.playback});

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
                playback.isRateLimited
                    ? 'YouTube is limiting requests from this connection.'
                    : 'This video would not open.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.tokens.onScrim, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                playback.isRateLimited
                    ? 'Wait a few minutes, then try again.'
                    : playback.error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.tokens.onScrim.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
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

class PlayerSlates extends ConsumerWidget {
  const PlayerSlates({super.key, this.showQueue = false, this.injectMaterial = false});

  final bool showQueue;
  final bool injectMaterial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);
    final isAudioOnly = ref.watch(audioModeProvider);
    final item = playback.item;
    final detailAsync = item == null
        ? null
        : ref.watch(videoInfoProvider(item.id));
    final detail = detailAsync?.value;

    final stack = Stack(
      fit: StackFit.expand,
      children: [
        if (isAudioOnly) AudioModeView(showQueue: showQueue),
        if (playback.isUpcoming)
          PremiereSlate(playback: playback)
        else if (isMembersOnlyFailure(playback, detail))
          MembersOnlySlate(playback: playback)
        else if (playback.error != null)
          UnavailableSlate(playback: playback),
      ],
    );

    return injectMaterial ? Material(child: stack) : stack;
  }
}
