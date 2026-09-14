import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../data/rpc/client.dart';
import '../../domain/playlist_membership.dart';

final _random = Random();

/// Opens the save-to-playlist dialog for [videoId].
///
/// **One dialog, one controller** (`docs/tasks/25-actions.md` §5) — the watch
/// page's Save pill and a tile's 3-dot menu both call this rather than each
/// carrying their own copy.
Future<void> showSaveDialog(BuildContext context, String videoId) {
  return showDialog<void>(
    context: context,
    builder: (_) => SaveDialog(videoId: videoId),
  );
}

class SaveDialog extends StatefulWidget {
  const SaveDialog({super.key, required this.videoId});

  final String videoId;

  @override
  State<SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<SaveDialog> {
  /// Null while the first `playlist.forVideo` is still in flight.
  List<PlaylistMembership>? _playlists;
  Object? _loadError;

  /// Ids with an edit in flight — the row shows a spinner instead of a
  /// checkbox rather than accepting a second tap on top of the first.
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final response =
          await RpcClient.instance.call('playlist.forVideo', {'videoId': widget.videoId})
              as Map<String, dynamic>;
      final playlists = (response['playlists'] as List<dynamic>? ?? [])
          .map((p) => PlaylistMembership.fromJson(p as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _playlists = playlists);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e);
    }
  }

  /// Flip the checkbox now, fire the edit, forget it.
  ///
  /// **Not the same "optimistic" as everywhere else in this app.** The watch
  /// page's like/dislike and Watch Later pills wait for the round trip and
  /// revert on failure (`docs/tasks/25-actions.md` §4's rule) — right for a
  /// rating or a save, where the state is singular and getting it wrong reads
  /// as a lie. A playlist checkbox is different in the one way that matters:
  /// `ACTION_ADD_VIDEO` and `ACTION_REMOVE_VIDEO` are idempotent server-side
  /// (adding an already-added video, or removing an already-removed one,
  /// both just no-op), so there is nothing for this client to get wrong by
  /// *not* waiting — the tap has done its whole job the moment the request
  /// is on the wire, and no answer this client could still be waiting for
  /// changes what that request did. So the edit is sent and never awaited by
  /// the UI; the checkbox never reverts, and the app closing or the call
  /// failing after the request left this process changes nothing about
  /// whether it was sent.
  ///
  /// The old version *did* wait — for a full `playlist.forVideo` refetch, to
  /// "confirm truth" — and that produced a worse bug than the one this
  /// avoids: on a real account, a refetch issued immediately after a
  /// successful add still answered "not in the playlist" for the entry that
  /// very call had just created (ordinary propagation lag, not a client
  /// bug), which silently un-ticked a save that had already landed and drove
  /// a real duplicate-add loop — each retry succeeding server-side and each
  /// refetch un-ticking it again. Not waiting at all removes the failure
  /// mode entirely rather than trying to time around it.
  ///
  /// The spinner's ~150–300 ms is its own thing, unrelated to the request —
  /// long enough to read as "the tap registered", short enough that a slow or
  /// hung connection never makes the checkbox wait on it. A second tap while
  /// it is showing is ignored, the same debounce a real double-click already
  /// needs, and not the 3-taps/5-seconds sort of thing worth building for an
  /// idempotent, manually-clicked checkbox.
  void _toggle(PlaylistMembership playlist, bool next) {
    if (_pending.contains(playlist.id)) return;
    final playlists = _playlists;
    if (playlists == null) return;

    setState(() {
      _pending.add(playlist.id);
      _playlists = [
        for (final p in playlists)
          if (p.id == playlist.id) p.copyWith(containsVideo: next) else p,
      ];
    });

    unawaited(_send(playlist, next));

    Future<void>.delayed(Duration(milliseconds: 150 + _random.nextInt(151)), () {
      if (mounted) setState(() => _pending.remove(playlist.id));
    });
  }

  /// The actual edit, run in the background — see `_toggle`'s doc comment for
  /// why nothing in this widget awaits it.
  Future<void> _send(PlaylistMembership playlist, bool next) async {
    try {
      if (next) {
        await RpcClient.instance.call('action.addToPlaylist', {
          'videoId': widget.videoId,
          'playlistId': playlist.id,
        });
      } else {
        // The token can be null here even for a row genuinely in the
        // playlist: a row added earlier *in this same dialog session* has
        // never been through a `playlist.forVideo` response of its own, so it
        // never got one. Fetched lazily, at the moment removal is actually
        // asked for.
        final token = playlist.removeToken ?? await _fetchRemoveToken(playlist.id);
        if (token != null) {
          await RpcClient.instance.call('action.removeFromPlaylist', {
            'playlistId': playlist.id,
            'removeToken': token,
          });
        }
      }
    } on RpcException catch (e) {
      _reportFailure(e.code == 'AUTH_REQUIRED' ? 'Sign in to edit playlists' : e.message);
    } on Object catch (e) {
      _reportFailure('$e');
    }
  }

  /// A fresh `playlist.forVideo` lookup for one row's `removeToken` — see
  /// `_send`'s doc comment for why this is spent only right before a removal
  /// rather than after every add.
  Future<String?> _fetchRemoveToken(String playlistId) async {
    final response =
        await RpcClient.instance.call('playlist.forVideo', {'videoId': widget.videoId})
            as Map<String, dynamic>;
    for (final raw in (response['playlists'] as List<dynamic>? ?? [])) {
      final row = raw as Map<String, dynamic>;
      if (row['id'] == playlistId) return row['removeToken'] as String?;
    }
    return null;
  }

  /// The checkbox never reverts (see `_toggle`), but a failure the user
  /// cannot see is still worth naming — this is a notice, not a rollback.
  void _reportFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createPlaylist() async {
    final created = await showDialog<({String title, PlaylistPrivacy privacy})>(
      context: context,
      builder: (_) => const _NewPlaylistDialog(),
    );
    if (created == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final response = await RpcClient.instance.call('playlist.create', {
        'title': created.title,
        'privacy': created.privacy.name,
      }) as Map<String, dynamic>;
      final playlistId = response['playlistId'] as String;
      // The real "Save to..." dialog adds the current video the moment a
      // playlist is created from it — creating an empty playlist you have to
      // then re-open the dialog to fill would be a worse flow for no reason.
      await RpcClient.instance.call('action.addToPlaylist', {
        'videoId': widget.videoId,
        'playlistId': playlistId,
      });
      // Inserted locally rather than re-fetched, for the same reason `_toggle`
      // no longer refetches after a mutation — a `playlist.forVideo` issued
      // this soon after the add it is meant to confirm can still miss it.
      if (mounted) {
        setState(() {
          _playlists = [
            ...?_playlists,
            PlaylistMembership(
              id: playlistId,
              title: created.title,
              privacy: created.privacy,
              containsVideo: true,
            ),
          ];
        });
      }
    } on RpcException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to create a playlist' : e.message)),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
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
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: Row(
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
              ),
              const SizedBox(height: 4),
              // Bounded and scrollable rather than however tall the account
              // happens to be — an account with forty playlists is not
              // unusual, and a dialog that grows to the height of one of
              // those is a dialog with its footer off the bottom of the
              // window.
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260, minHeight: 72),
                  child: _buildBody(context),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton.icon(
                  onPressed: _playlists == null ? null : _createPlaylist,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New playlist'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loadError != null) {
      final error = _loadError;
      final message = error is RpcException && error.code == 'AUTH_REQUIRED'
          ? 'Sign in to see your playlists'
          : 'Could not load playlists';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                message,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final playlists = _playlists;
    if (playlists == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    return SilkySingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final playlist in playlists)
            _SaveRow(
              name: playlist.title,
              privacy: playlist.privacy,
              ticked: playlist.containsVideo,
              busy: _pending.contains(playlist.id),
              onChanged: (next) => _toggle(playlist, next),
            ),
        ],
      ),
    );
  }
}

class _SaveRow extends StatelessWidget {
  const _SaveRow({
    required this.name,
    required this.privacy,
    required this.ticked,
    required this.busy,
    required this.onChanged,
  });

  final String name;
  final PlaylistPrivacy? privacy;
  final bool ticked;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final privacyIcon = switch (privacy) {
      PlaylistPrivacy.private => Icons.lock_outline,
      PlaylistPrivacy.unlisted => Icons.link,
      PlaylistPrivacy.public => Icons.public,
      null => null,
    };

    return InkWell(
      onTap: busy ? null : () => onChanged(!ticked),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(3),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Checkbox(
                      value: ticked,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (next) => onChanged(next ?? false),
                    ),
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
            if (privacyIcon != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(privacyIcon, size: 16, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

class _NewPlaylistDialog extends StatefulWidget {
  const _NewPlaylistDialog();

  @override
  State<_NewPlaylistDialog> createState() => _NewPlaylistDialogState();
}

class _NewPlaylistDialogState extends State<_NewPlaylistDialog> {
  final _controller = TextEditingController();
  PlaylistPrivacy _privacy = PlaylistPrivacy.private;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _controller.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop((title: title, privacy: _privacy));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New playlist'),
      // Fixed rather than left to the content's own intrinsic width: the
      // `SegmentedButton` renders a checkmark on whichever segment is
      // selected, which is a few pixels wider than the plain icon the other
      // two show — so an unconstrained dialog resized itself by a couple of
      // pixels every time the privacy selection changed.
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Playlist name'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            SegmentedButton<PlaylistPrivacy>(
              segments: const [
                ButtonSegment(
                  value: PlaylistPrivacy.private,
                  label: Text('Private'),
                  icon: Icon(Icons.lock_outline, size: 16),
                ),
                ButtonSegment(
                  value: PlaylistPrivacy.unlisted,
                  label: Text('Unlisted'),
                  icon: Icon(Icons.link, size: 16),
                ),
                ButtonSegment(
                  value: PlaylistPrivacy.public,
                  label: Text('Public'),
                  icon: Icon(Icons.public, size: 16),
                ),
              ],
              selected: {_privacy},
              onSelectionChanged: (next) => setState(() => _privacy = next.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
