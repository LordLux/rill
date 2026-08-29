import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/rpc/client.dart';
import '../../domain/artist_panel.dart';
import '../../theme/screen_values.dart';
import 'channel_badge.dart';

/// The "official artist channel" panel `search.query` carries above the
/// ordinary results for an artist-name query (Task 21 §3, `protocol.md`
/// §3.3) — avatar, handle, subscriber/video count, description, and the
/// panel's own action row.
///
/// "View Channel" and "Mix" are inert: this app has no channel page and no
/// `mix.start` RPC wired at all yet (both pre-existing gaps, out of scope
/// here), so they fall back to the same "Not implemented" snackbar
/// `search_results.dart`'s own filter pills already use. **Subscribe** is
/// real — `action.subscribe` — and follows the same write-only asymmetry as
/// the tile's Watch Later pill (`protocol.md` §3.4): there is no
/// `action.unsubscribe`, so an already-subscribed panel shows a static label
/// rather than a button promising an action nothing backs.
class ArtistPanelCard extends ConsumerStatefulWidget {
  const ArtistPanelCard({super.key, required this.artist});

  final ArtistPanel artist;

  @override
  ConsumerState<ArtistPanelCard> createState() => _ArtistPanelCardState();
}

class _ArtistPanelCardState extends ConsumerState<ArtistPanelCard> {
  bool _subscribed = false;
  bool _subscribing = false;

  @override
  void initState() {
    super.initState();
    _subscribed = widget.artist.isSubscribed;
  }

  @override
  void didUpdateWidget(ArtistPanelCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.channelId != widget.artist.channelId) {
      _subscribed = widget.artist.isSubscribed;
    }
  }

  Future<void> _subscribe() async {
    setState(() => _subscribing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RpcClient.instance.call('action.subscribe', {'channelId': widget.artist.channelId});
      if (!mounted) return;
      setState(() {
        _subscribed = true;
        _subscribing = false;
      });
    } on RpcException catch (e) {
      if (!mounted) return;
      setState(() => _subscribing = false);
      messenger.showSnackBar(
        SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to subscribe' : e.message)),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _subscribing = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _notImplemented() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not implemented')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final artist = widget.artist;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ScreenValues.contentMaxWidth),
        child: Container(
          margin: const EdgeInsets.only(bottom: 16.0),
          padding: const EdgeInsets.all(20.0),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 44,
                backgroundImage: artist.avatarUrl.isEmpty ? null : NetworkImage(artist.avatarUrl),
                onBackgroundImageError: artist.avatarUrl.isEmpty ? null : (error, stackTrace) {},
                child: artist.avatarUrl.isEmpty ? const Icon(Icons.person, size: 44) : null,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            artist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        ChannelBadge(channelName: artist.name, isArtistChannel: true, isVerified: false, size: 18, paddingLeft: 6),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (artist.handle != null) artist.handle!,
                        if (artist.subscriberText != null) artist.subscriberText!,
                        if (artist.videoCountText != null) artist.videoCountText!,
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                    if (artist.description != null && artist.description!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        artist.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _subscribed
                            ? OutlinedButton(onPressed: null, child: const Text('Subscribed'))
                            : FilledButton(
                                onPressed: _subscribing ? null : _subscribe,
                                child: _subscribing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Text('Subscribe'),
                              ),
                        OutlinedButton(onPressed: _notImplemented, child: const Text('View Channel')),
                        if (artist.mixPlaylistId != null)
                          OutlinedButton(onPressed: _notImplemented, child: const Text('Mix')),
                        OutlinedButton(onPressed: _notImplemented, child: const Text('YouTube Music')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
