import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/shelf.dart';
import '../promoted_preference.dart';
import '../shelf_visibility.dart';

/// The settings page for the home feed's shelves (`todo.md` 111): one switch per
/// category of shelf, saying whether that shelf is shown with its contents.
///
/// A category and not a shelf, because the title that names a shelf is localised and
/// changes; what a shelf *is* is decided by the sidecar from what is in it
/// (`protocol.md` §3.2). A switch applies at once and needs no request: every shelf is
/// already loaded and the app filters.
/// The switch under "Promotions"; tests find it by this key.
const ValueKey<String> promotedSwitchKey = ValueKey('promoted-switch');

class HomeFeedSettingsPanel extends ConsumerWidget {
  const HomeFeedSettingsPanel({super.key});

  /// What each switch is called, and the line under it.
  static const List<(ShelfCategory, String, String)> rows = [
    (ShelfCategory.members, 'Memberships', 'The row of videos from channels you are a member of.'),
    (ShelfCategory.shorts, 'Shorts', 'Rows of Shorts.'),
    (ShelfCategory.posts, 'Community posts', 'Rows of posts from channels.'),
    (ShelfCategory.other, 'Other rows', 'Every other titled row between the videos.'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final shown = ref.watch(shelfVisibilityProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Show these rows on the home page', style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (final (category, label, detail) in rows)
            _SwitchRow(
              switchKey: ValueKey('shelf-switch-${category.name}'),
              label: label,
              detail: detail,
              value: shown[category] ?? shelfVisibilityDefaults[category]!,
              onChanged: (value) => unawaited(ref.read(shelfVisibilityProvider.notifier).set(category, value)),
            ),
          const SizedBox(height: 12),
          Text('Promotions', style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          _SwitchRow(
            switchKey: promotedSwitchKey,
            label: 'Promoted videos',
            detail: 'Cards YouTube marks as promoted, such as a Premium offer, in feeds and in related videos.',
            value: ref.watch(promotedVisibleProvider),
            onChanged: (value) => unawaited(ref.read(promotedVisibleProvider.notifier).set(value)),
          ),
        ],
      ),
    );
  }
}

/// One labelled switch. One semantics node for the label and the state, read once.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.switchKey,
    required this.label,
    required this.detail,
    required this.value,
    required this.onChanged,
  });

  final Key switchKey;
  final String label;
  final String detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: textTheme.bodyMedium),
                  Text(detail, style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            SizedBox(
              height: 28,
              child: FittedBox(
                alignment: Alignment.centerRight,
                child: Switch(
                  key: switchKey,
                  value: value,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
