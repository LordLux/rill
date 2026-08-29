import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../verified_channels_controller.dart';

class ChannelBadge extends ConsumerWidget {
  const ChannelBadge({
    super.key,
    required this.channelName,
    required this.isArtistChannel,
    required this.isVerified,
    this.size = 13.0,
    this.paddingLeft = 0.0,
  });

  final String channelName;
  final bool isArtistChannel;
  final bool isVerified;
  final double size;
  final double paddingLeft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.watch(verifiedChannelsProvider);
    final actuallyVerified = isVerified || cache.contains(channelName);
    
    // Auto-warm the cache if this instance *is* verified from the API!
    if (isVerified && channelName.isNotEmpty && !cache.contains(channelName)) {
      Future.microtask(() => ref.read(verifiedChannelsProvider.notifier).markVerified(channelName));
    }

    if (!isArtistChannel && !actuallyVerified) return const SizedBox.shrink();
    
    final scheme = Theme.of(context).colorScheme;
    final asset = isArtistChannel ? 'assets/icons/verified_artist.svg' : 'assets/icons/verified.svg';
    
    final icon = SvgPicture.asset(
      asset,
      width: size,
      height: size,
      // ignore: deprecated_member_use
      color: scheme.onSurfaceVariant,
    );

    if (paddingLeft > 0) {
      return Padding(padding: EdgeInsets.only(left: paddingLeft), child: icon);
    }
    return icon;
  }
}
