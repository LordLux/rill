import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/update/update_config.dart';
import '../../domain/update/update_state.dart';
import '../../domain/ytdlp/ytdlp_state.dart';
import '../focus_ring.dart';
import '../update_controller.dart';
import '../ytdlp_controller.dart';
import 'settings_widgets.dart';

/// The updater's and yt-dlp's widgets, shared by Settings › About and the account menu's
/// Updates page: one provider each, drawn in two places, never a second copy of a value.

/// The "Download updates automatically" switch; tests find it by this key.
const ValueKey<String> autoUpdateSwitchKey = ValueKey('auto-update-switch');

/// The updater: a card for whatever it has to say — the update on offer with its notes
/// and actions, a download in progress, a failure, or that all is well — then the
/// running version, the last check, and the automatic-update switch (`architecture.md`
/// §2.14).
///
/// **One widget in two places, on one provider:** Settings › About, and the account
/// menu's Updates page. Each caller draws its own header, with [UpdateRefreshButton] and
/// a bar while [updateChecking] says a check runs.
class UpdatePanel extends ConsumerStatefulWidget {
  const UpdatePanel({super.key, this.showAutoUpdate = true, this.onLaterDone});

  /// The "Download updates automatically" switch under the version. Settings › About has
  /// it; the account menu's page is the card, the version and the last check, nothing
  /// to set (the switch is the settings page's, and yt-dlp is About's own card).
  final bool showAutoUpdate;

  /// After "Later": the account menu goes back to its root page. Null stays put, and
  /// hands keyboard focus to the card's main button, since "Later" removes itself.
  final VoidCallback? onLaterDone;

  @override
  ConsumerState<UpdatePanel> createState() => _UpdatePanelState();
}

/// Whether a check is running, for the header's loading bar.
bool updateChecking(UpdateState state) => state.phase is UpdateChecking;

class _UpdatePanelState extends ConsumerState<UpdatePanel> {
  /// What the card showed before the current check started. A check is shown by the bar
  /// under the header; the card keeps its last result until the new one arrives, so it
  /// never collapses to a short "checking" card and grows back a frame later
  /// (architecture.md §2.14).
  UpdatePhase? _settled;

  /// The card's main button. "Later" removes itself, so a keyboard press of it hands focus
  /// here rather than dropping it (CLAUDE.md, Task 32: focus is never left on nothing).
  final FocusNode _primary = FocusNode(debugLabel: 'update card primary');

  @override
  void dispose() {
    _primary.dispose();
    super.dispose();
  }

  Future<void> _later() async {
    final hadFocus = KeyboardNavigation.active && (FocusManager.instance.primaryFocus?.context?.mounted ?? false);
    await ref.read(updateControllerProvider.notifier).dismiss();
    if (!mounted) return;
    final done = widget.onLaterDone;
    if (done != null) {
      done();
      return;
    }
    if (!hadFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _primary.context != null) _primary.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(updateControllerProvider);
    if (!updateChecking(live)) _settled = live.phase;
    final settled = _settled;
    final state = updateChecking(live) && settled != null ? live.copyWith(phase: settled) : live;
    final config = ref.watch(updateConfigProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final lastChecked = state.lastChecked;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (config.overridden)
          Container(
            key: const ValueKey('update-test-marker'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer,
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
            child: Text(
              'TEST FEED · ${config.activeOverrides.join('/')}',
              style: textTheme.labelSmall?.copyWith(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700),
            ),
          ),
        _UpdateCard(
          state: state,
          enabled: config.enabled,
          primaryFocus: _primary,
          onLater: () => unawaited(_later()),
        ),
        const SizedBox(height: 12),
        _UpdateInfoRow(label: 'Version', value: state.currentVersion?.toString() ?? 'Development build'),
        _UpdateInfoRow(label: 'Last checked', value: lastChecked == null ? 'Never' : _ago(lastChecked)),
        if (widget.showAutoUpdate) ...[
          const SizedBox(height: 4),
          SettingsSwitchRow(
            switchKey: autoUpdateSwitchKey,
            label: 'Download updates automatically',
            detail: 'Check every 12 hours and download a new version in the background. It installs only when you restart.',
            value: state.autoUpdate,
            onChanged: config.enabled ? (value) => unawaited(controller.setAutoUpdate(value)) : null,
          ),
        ],
      ],
    );
  }
}

/// The header's refresh action: a manual check, a spinner while one runs.
class UpdateRefreshButton extends ConsumerWidget {
  const UpdateRefreshButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(updateControllerProvider.select((s) => s.phase));
    final enabled = ref.watch(updateConfigProvider).enabled;
    final scheme = Theme.of(context).colorScheme;
    // Disabled rather than replaced while a check runs: swapping it for a
    // spinner changed the header's width, and the bar under the header already
    // says something is loading.
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      // No tooltip: the button says what it does, and an overlay tooltip on a page that
      // scrolls is the orphaned-node fault (CLAUDE.md, "Accessibility").
      child: TextButton.icon(
          // Enabled while a check runs, ignoring the press: a control that disabled itself
          // under keyboard focus would drop it (CLAUDE.md, Task 32). Drawn dim meanwhile.
          onPressed: enabled
              ? () {
                  if (canStartCheck(ref.read(updateControllerProvider).phase)) {
                    unawaited(ref.read(updateControllerProvider.notifier).checkNow());
                  }
                }
              : null,
          iconAlignment: IconAlignment.end,
          icon: const Icon(Icons.refresh, size: 20),
          // Ellipsised rather than overflowing when the header is short of room.
          label: const Text('Check for updates', maxLines: 1, overflow: TextOverflow.ellipsis),
          style: TextButton.styleFrom(
            foregroundColor: canStartCheck(phase) ? scheme.primary : scheme.primary.withValues(alpha: 0.5),
            iconAlignment: IconAlignment.end,
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
      ),
    );
  }
}

/// The card at the top of the Updates page. Accent-coloured when there is an
/// update to act on, error-coloured for a failure, neutral otherwise.
class _UpdateCard extends ConsumerWidget {
  const _UpdateCard({required this.state, required this.enabled, required this.onLater, this.primaryFocus});

  final UpdateState state;
  final bool enabled;
  final VoidCallback onLater;
  final FocusNode? primaryFocus;

  static const _maxNotes = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(updateControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final phase = state.phase;
    final manifest = phase.manifest;
    final version = manifest?.version.toString() ?? '';

    final (Color background, Color foreground) = switch (phase) {
      _ when !enabled => (scheme.surfaceContainerHighest, scheme.onSurface),
      UpdateError() => (scheme.errorContainer, scheme.onErrorContainer),
      UpdateAvailable() || UpdateDownloading() || UpdateReady() || UpdateInstalling() => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurface),
    };
    final muted = foreground.withValues(alpha: 0.72);

    final String headline = !enabled
        ? 'Updates are off'
        : switch (phase) {
            UpdateIdle() => 'Not checked yet',
            UpdateChecking() => 'Checking for updates…',
            UpdateUpToDate() => 'Rill is up to date',
            UpdateAvailable() => 'Rill $version is available!',
            UpdateDownloading() => 'Downloading Rill $version',
            UpdateReady() => 'Rill $version is ready!',
            UpdateInstalling() => 'Restarting to update…',
            UpdateError(:final kind) => _errorHeadline(kind),
          };

    final String? detail = !enabled
        ? 'This is a development build, which has no version to compare with a release.'
        : switch (phase) {
            UpdateDownloading(:final received, :final total) => '${updatePercent(received, total)}% of ${(total / (1024 * 1024)).toStringAsFixed(1)} MB',
            UpdateError(:final message) => message,
            _ => null,
          };

    final offersNotes = enabled && manifest != null && phase is! UpdateError && manifest.notes.isNotEmpty;
    final canLater = !state.isMandatory && state.dismissedVersion != version;

    final Widget? actions = !enabled
        ? null
        : switch (phase) {
            UpdateReady() => _UpdateActions(
              primary: FilledButton(focusNode: primaryFocus, onPressed: controller.install, child: const Text('Restart to update')),
              later: canLater ? onLater : null,
            ),
            UpdateAvailable() => _UpdateActions(
              primary: FilledButton(focusNode: primaryFocus, onPressed: controller.download, child: const Text('Download')),
              later: canLater ? onLater : null,
            ),
            UpdateError() => Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: foreground),
                onPressed: () => controller.checkNow(),
                child: const Text('Try again'),
              ),
            ),
            _ => null,
          };

    return Container(
      key: const ValueKey('update-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: background, borderRadius: const BorderRadius.all(Radius.circular(16))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            headline,
            style: textTheme.titleMedium?.copyWith(color: foreground, fontWeight: FontWeight.w700),
          ),
          if (state.isMandatory) ...[
            const SizedBox(height: 2),
            Text(
              'This update is required.',
              style: textTheme.bodySmall?.copyWith(color: foreground, fontWeight: FontWeight.w600),
            ),
          ],
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(detail, style: textTheme.bodySmall?.copyWith(color: muted)),
          ],
          if (phase case UpdateDownloading(:final received, :final total)) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: total == 0 ? null : received / total),
          ],
          if (offersNotes) ...[
            const SizedBox(height: 8),
            Text(
              "WHAT'S NEW",
              style: textTheme.labelMedium?.copyWith(color: muted, fontWeight: FontWeight.w700, letterSpacing: 0.8),
            ),
            const SizedBox(height: 6),
            for (final note in manifest.notes.take(_maxNotes))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: textTheme.bodySmall?.copyWith(color: foreground)),
                    Expanded(
                      child: Text(note, style: textTheme.bodySmall?.copyWith(color: foreground)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                borderRadius: const BorderRadius.all(Radius.circular(4)),
                onTap: () => unawaited(
                  launchUrl(Uri.parse('${UpdateConfig.releasePageBase}${manifest.tag}'), mode: LaunchMode.externalApplication),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Full release notes', style: textTheme.bodySmall?.copyWith(color: scheme.primary)),
                      const SizedBox(width: 4),
                      Icon(Icons.north_east, size: 14, color: scheme.primary),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (actions != null) ...[const SizedBox(height: 12), actions],
        ],
      ),
    );
  }
}

class _UpdateActions extends StatelessWidget {
  const _UpdateActions({required this.primary, this.later});

  final Widget primary;
  final VoidCallback? later;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      primary,
      if (later != null) TextButton(onPressed: later, child: const Text('Later')),
    ],
  );
}

class _UpdateInfoRow extends StatelessWidget {
  const _UpdateInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: style?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Text(value, style: style),
        ],
      ),
    );
  }
}

/// The card shown once yt-dlp is installed, when it was missing while the page was open.
class YtDlpResolvedCard extends StatelessWidget {
  const YtDlpResolvedCard({super.key, required this.state});

  final YtDlpState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (String headline, String? detail) = switch (state.location) {
      YtDlpLocation.appManaged => ('yt-dlp has been installed!', state.appManagedVersion != null ? 'Version ${state.appManagedVersion}' : null),
      YtDlpLocation.onPath => ('yt-dlp is available', 'Found on PATH at ${state.onPathPath}'),
      YtDlpLocation.missing => ('yt-dlp is available', null),
    };

    return Container(
      key: const ValueKey('ytdlp-resolved-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: const BorderRadius.all(Radius.circular(16))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(headline, style: textTheme.titleSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700)),
                if (detail != null) ...[
                  const SizedBox(height: 4),
                  Text(detail, style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class YtDlpCard extends ConsumerWidget {
  const YtDlpCard({super.key, required this.state});

  final YtDlpState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(ytDlpControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final phase = state.phase;
    final downloading = phase is YtDlpDownloading;
    final error = phase is YtDlpPhaseError ? phase.message : null;
    final problem = state.severity == YtDlpRowSeverity.problem;

    // A calm tertiary container for the ordinary "not installed yet" case, the
    // same error container an actual failed download gets everywhere else.
    final (Color background, Color foreground) = problem ? (scheme.errorContainer, scheme.onErrorContainer) : (scheme.tertiaryContainer, scheme.onTertiaryContainer);

    return Container(
      key: const ValueKey('ytdlp-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: background, borderRadius: const BorderRadius.all(Radius.circular(16))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  problem ? 'yt-dlp download failed' : 'yt-dlp is not installed',
                  style: textTheme.titleSmall?.copyWith(color: foreground, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'yt-dlp is required for age-restricted videos and some music-label content '
            'to play. Without it, those specific videos will not play at all; every '
            'other video is unaffected.',
            style: textTheme.bodySmall?.copyWith(color: foreground.withValues(alpha: 0.85)),
          ),
          if (downloading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(color: foreground),
            const SizedBox(height: 6),
            Text('Downloading…', style: textTheme.bodySmall?.copyWith(color: foreground)),
          ] else if (error != null) ...[
            const SizedBox(height: 8),
            Text(error, style: textTheme.bodySmall?.copyWith(color: foreground)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton(
                onPressed: downloading ? null : controller.download,
                child: Text(error != null ? 'Try again' : 'Download yt-dlp'),
              ),
              // Already declined once: offering to decline again is a no-op
              // dressed up as a button.
              if (state.choice != YtDlpChoice.declined)
                TextButton(
                  onPressed: downloading ? null : controller.decline,
                  child: const Text("I don't want it"),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The Updates page's info row for yt-dlp — "a way back after declining"
/// (todo.md 49): whatever state it is actually in, with a Download action
/// only when there is something to download.
class YtDlpInfoRow extends ConsumerWidget {
  const YtDlpInfoRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ytDlpControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;

    final value = switch (state.location) {
      YtDlpLocation.appManaged => state.appManagedVersion ?? 'Installed',
      YtDlpLocation.onPath => 'On PATH',
      YtDlpLocation.missing => 'Not installed',
    };
    final downloading = state.phase is YtDlpDownloading;
    final canDownload = state.location == YtDlpLocation.missing && !downloading;

    // Three pieces of text can outgrow the 260 px panel (label, value, and
    // "Download") where `_UpdateInfoRow`'s two never do — the value shrinks
    // first, inside its own flexible group, rather than overflowing the row.
    return Row(
      children: [
        Expanded(child: Text('Status', style: style?.copyWith(color: scheme.onSurfaceVariant))),
        Flexible(
          // Right-aligned like the Version and Last checked values above it.
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(value, style: style, overflow: TextOverflow.ellipsis)),
              if (downloading) ...[
                const SizedBox(width: 8),
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              ] else if (canDownload) ...[
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                  onTap: () => ref.read(ytDlpControllerProvider.notifier).download(),
                  child: Text('Download', style: style?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
                ),
              ],
            ],
          ),
          ),
        ),
      ],
    );
  }
}

/// How far a download has got, 0 to 100. Public for the account menu's update row.
int updatePercent(int received, int total) => total <= 0 ? 0 : (received * 100 ~/ total).clamp(0, 100);

String _errorHeadline(UpdateErrorKind kind) => switch (kind) {
  UpdateErrorKind.network => "Couldn't reach the update server",
  UpdateErrorKind.signature => 'The update failed verification',
  UpdateErrorKind.manifest => 'The update information was invalid',
  UpdateErrorKind.integrity => 'The download was corrupted',
  UpdateErrorKind.disk => "Couldn't save the update",
  UpdateErrorKind.install => "Couldn't start the installer",
};

String _ago(DateTime time) {
  final elapsed = DateTime.now().difference(time);
  if (elapsed.inMinutes < 1) return 'Just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
  return elapsed.inDays == 1 ? 'Yesterday' : '${elapsed.inDays} days ago';
}