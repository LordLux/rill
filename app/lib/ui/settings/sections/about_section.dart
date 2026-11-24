import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/ytdlp/ytdlp_state.dart';
import '../../update_controller.dart';
import '../../ytdlp_controller.dart';
import '../settings_section.dart';
import '../settings_widgets.dart';
import '../update_panel.dart';

/// About's id, for the account menu's status rows that open it.
const String aboutSettingsSectionId = 'about';

final SettingsSection aboutSection = SettingsSection(
  id: aboutSettingsSectionId,
  title: 'About',
  icon: Icons.info_outline,
  order: 90,
  builder: (_) => const _AboutSection(),
);

/// The running version, the updater, yt-dlp and the licences (`architecture.md` §2.14).
///
/// The account menu shows the same [UpdatePanel] on its own Updates page; its yt-dlp row
/// opens this section.
class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _UpdatesCard(),
        _YtDlpSettingsCard(),
        _LicencesCard(),
      ],
    );
  }
}

/// Settings › About's updater: [UpdatePanel] under a header with the check button.
class _UpdatesCard extends ConsumerWidget {
  const _UpdatesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checking = ref.watch(updateControllerProvider.select(updateChecking));
    return SettingsCard(
      title: 'Updates',
      trailing: const UpdateRefreshButton(),
      children: [
        // The bar runs along the card's top edge while a check runs; it moves nothing.
        SizedBox(
          height: 6,
          child: checking
              ? const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(key: ValueKey('update-header-progress'), minHeight: 2),
                )
              : null,
        ),
        const UpdatePanel(),
      ],
    );
  }
}

/// yt-dlp's state and, when it is missing, the card that offers it (todo.md 49).
class _YtDlpSettingsCard extends ConsumerStatefulWidget {
  const _YtDlpSettingsCard();

  @override
  ConsumerState<_YtDlpSettingsCard> createState() => _YtDlpSettingsCardState();
}

class _YtDlpSettingsCardState extends ConsumerState<_YtDlpSettingsCard> {
  /// Whether yt-dlp was missing while this page was open: a download finishing here is
  /// how a successful install is seen, so the "installed" card is shown for it rather
  /// than the card simply vanishing.
  bool _wasMissing = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ytDlpControllerProvider);
    final missing = state.severity != YtDlpRowSeverity.none;
    if (missing) _wasMissing = true;
    return SettingsCard(
      title: 'yt-dlp',
      detail: 'Plays age-restricted videos and some music-label videos that nothing else can.',
      children: [
        const YtDlpInfoRow(),
        if (missing || _wasMissing) ...[
          const SizedBox(height: 10),
          if (missing) YtDlpCard(state: state) else YtDlpResolvedCard(state: state),
        ],
      ],
    );
  }
}

class _LicencesCard extends ConsumerWidget {
  const _LicencesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(updateControllerProvider.select((s) => s.currentVersion));
    return SettingsCard(
      title: 'Rill',
      children: [
        SettingsLinkRow(
          icon: Icons.description_outlined,
          label: 'About and licences',
          detail: 'The open-source software Rill is built on.',
          onTap: () => showAboutDialog(
            context: context,
            applicationName: 'Rill',
            applicationVersion: version?.toString() ?? 'Development build',
            applicationLegalese: 'Includes LGPL-2.1 libraries. See THIRD_PARTY_LICENSES for full compliance details.',
          ),
        ),
      ],
    );
  }
}

