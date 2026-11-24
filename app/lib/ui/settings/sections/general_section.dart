import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/accent.dart';
import '../../session_restore.dart';
import '../settings_section.dart';
import '../settings_widgets.dart';

/// The switch for reopening where the viewer left off; tests find it by this key.
const ValueKey<String> restoreSessionSwitchKey = ValueKey('restore-session-switch');

final SettingsSection generalSection = SettingsSection(
  id: 'general',
  title: 'General',
  icon: Icons.tune,
  order: 10,
  builder: (_) => const _GeneralSection(),
);

class _GeneralSection extends ConsumerWidget {
  const _GeneralSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          title: 'Starting Rill',
          children: [
            // After an update the last video is always reopened; this is for a close the
            // viewer chose (`architecture.md` §2.17).
            SettingsSwitchRow(
              switchKey: restoreSessionSwitchKey,
              label: 'Reopen where I left off',
              detail: 'Open the last video, its queue and the page you were on, paused.',
              value: ref.watch(restoreSessionProvider),
              onChanged: (value) => unawaited(ref.read(restoreSessionProvider.notifier).setEnabled(value)),
            ),
          ],
        ),
        SettingsCard(
          title: 'Appearance',
          detail: 'The colour of buttons, switches and highlights across Rill.',
          children: [
            SettingsLabelledRow(
              label: 'Accent colour',
              child: SettingsSwatches<Color>(
                label: 'Accent colour',
                size: 28,
                options: [for (final preset in kAccentPresets) (name: preset.name, color: preset.seed, value: preset.seed)],
                isSelected: (seed) => seed == accent,
                onPicked: (seed) => unawaited(ref.read(accentProvider.notifier).set(seed)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
