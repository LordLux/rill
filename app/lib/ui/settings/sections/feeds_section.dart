import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/shelf.dart';
import '../../members_only_preference.dart';
import '../../promoted_preference.dart';
import '../../shelf_visibility.dart';
import '../settings_section.dart';
import '../settings_widgets.dart';

/// The switch under "In every list" for promoted cards; tests find it by this key.
const ValueKey<String> promotedSwitchKey = ValueKey('promoted-switch');

/// The members-only switch; tests find it by this key.
const ValueKey<String> membersOnlySwitchKey = ValueKey('members-only-switch');

/// A home-row switch, by category.
ValueKey<String> shelfSwitchKey(ShelfCategory category) => ValueKey('shelf-switch-${category.name}');

final SettingsSection feedsSection = SettingsSection(
  id: 'feeds',
  title: 'Feeds',
  icon: Icons.view_agenda_outlined,
  order: 20,
  builder: (_) => const _FeedsSection(),
);

/// The home page's rows (`todo.md` 111) and what is filtered out of every list.
///
/// A row switch is per category and not per row, because the title that names a row is
/// localised and changes; what a row *is* is decided by the sidecar from what is in it
/// (`protocol.md` §3.2). Every switch applies at once and needs no request: the app
/// filters what is already loaded.
class _FeedsSection extends ConsumerWidget {
  const _FeedsSection();

  /// What each row switch is called, and the line under it.
  static const List<(ShelfCategory, String, String)> rows = [
    (ShelfCategory.members, 'Memberships', 'The row of videos from channels you are a member of.'),
    (ShelfCategory.shorts, 'Shorts', 'Rows of Shorts.'),
    (ShelfCategory.posts, 'Community posts', 'Rows of posts from channels.'),
    (ShelfCategory.other, 'Other rows', 'Every other titled row between the videos.'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.watch(shelfVisibilityProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          title: 'Home page rows',
          detail: 'Show these rows between the videos on the home page.',
          children: [
            for (final (category, label, detail) in rows)
              SettingsSwitchRow(
                switchKey: shelfSwitchKey(category),
                label: label,
                detail: detail,
                value: shown[category] ?? shelfVisibilityDefaults[category]!,
                onChanged: (value) => unawaited(ref.read(shelfVisibilityProvider.notifier).set(category, value)),
              ),
          ],
        ),
        SettingsCard(
          title: 'In every list',
          detail: 'The home page, subscriptions, search, its rows and related videos.',
          children: [
            SettingsSwitchRow(
              switchKey: membersOnlySwitchKey,
              label: 'Members-only videos',
              detail: 'Videos only channel members can watch, wherever they appear.',
              value: ref.watch(membersOnlyVisibleProvider),
              onChanged: (value) => unawaited(ref.read(membersOnlyVisibleProvider.notifier).set(value)),
            ),
            SettingsSwitchRow(
              switchKey: promotedSwitchKey,
              label: 'Promoted videos',
              detail: 'Cards YouTube marks as promoted, such as a Premium offer.',
              value: ref.watch(promotedVisibleProvider),
              onChanged: (value) => unawaited(ref.read(promotedVisibleProvider.notifier).set(value)),
            ),
          ],
        ),
      ],
    );
  }
}
