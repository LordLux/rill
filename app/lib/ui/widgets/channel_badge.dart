import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../verified_channels_controller.dart';

class ChannelBadge extends ConsumerWidget {
  const ChannelBadge({
    super.key,
    required this.channelId,
    required this.isArtistChannel,
    required this.isVerified,
    this.size = 13.0,
    this.paddingLeft = 0.0,
  });

  /// The channel this badge belongs to, and the key the verified cache is
  /// held under. Null where the surface has no id for it — a `MixItem` or
  /// `PlaylistItem` tile, or a video whose `channelId` did not resolve — in
  /// which case the badge simply renders what this response said and takes no
  /// part in the cache. Never keyed on the display name: see
  /// `verified_channels_controller.dart`.
  final String? channelId;

  final bool isArtistChannel;
  final bool isVerified;
  final double size;
  final double paddingLeft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = channelId;
    final cache = ref.watch(verifiedChannelsProvider);
    final actuallyVerified = isVerified || (id != null && cache.contains(id));

    // Auto-warm the cache if this instance *is* verified from the API!
    // `context.mounted` guards the read: a tile can be scrolled far enough
    // off (a fast alphabet-index jump, say) to be disposed before this
    // microtask runs, and reading `ref` off a dead element throws
    // `StateError`. `WidgetRef` has no `mounted` of its own on this
    // Riverpod version — `context`'s is the one that's actually checked.
    if (isVerified && id != null && id.isNotEmpty && !cache.contains(id)) {
      Future.microtask(() {
        if (!context.mounted) return;
        ref.read(verifiedChannelsProvider.notifier).markVerified(id);
      });
    }

    if (!isArtistChannel && !actuallyVerified) return const SizedBox.shrink();
    
    final scheme = Theme.of(context).colorScheme;
    final asset = isArtistChannel ? 'assets/icons/verified_artist.svg' : 'assets/icons/verified.svg';
    
    final icon = Tooltip(
      message: isArtistChannel ? 'Verified artist channel' : 'Verified channel',
      child: SvgPicture.asset(
        asset,
        width: size,
        height: size,
        // ignore: deprecated_member_use
        color: scheme.onSurfaceVariant,
      ),
    );

    if (paddingLeft > 0) {
      return Padding(padding: EdgeInsets.only(left: paddingLeft), child: icon);
    }
    return icon;
  }
}
