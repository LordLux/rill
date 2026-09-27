import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/update/update_state.dart';
import '../update_controller.dart';

/// A strip above the page for a required update only (`minimumVersion` above
/// the running version). Not dismissible, never modal, never over the player:
/// it pushes the page down rather than covering it (architecture.md §2.14).
/// An ordinary update is the avatar dot and the account menu, nothing more.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final manifest = state.phase.manifest;
    if (!state.isMandatory || manifest == null) return const SizedBox.shrink();

    final controller = ref.read(updateControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final version = manifest.version.toString();

    final (String text, Widget? action) = switch (state.phase) {
      UpdateReady() => (
        'Rill $version is a required update and is ready to install.',
        FilledButton(onPressed: controller.install, child: const Text('Restart to update')),
      ),
      UpdateDownloading(:final received, :final total) => (
        'Rill $version is a required update. Downloading… ${total == 0 ? 0 : received * 100 ~/ total}%',
        null,
      ),
      UpdateInstalling() => ('Restarting to update…', null),
      UpdateAvailable() => (
        'Rill $version is a required update.',
        FilledButton(onPressed: controller.download, child: const Text('Download')),
      ),
      _ => (
        'Rill $version is a required update, and the last attempt failed.',
        TextButton(onPressed: () => controller.checkNow(), child: const Text('Try again')),
      ),
    };

    return Material(
      key: const ValueKey('update-banner'),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.system_update_alt, size: 20, color: scheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, style: textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer)),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}
