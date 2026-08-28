import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/search_filters.dart';
import '../feed_controller.dart';
import '../page_wrapper.dart';
import '../player_shell.dart' show rootNavigatorKey;
import '../widgets/feed_view.dart';

const String searchRouteName = 'search';

/// The topbar search field's text, so it can be prefilled when navigation
/// (rather than typing) is what produced the current query — landing on a
/// results page, or coming back to one.
class CurrentSearchQuery extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? value) {
    if (state != value) state = value;
  }
}

final currentSearchQueryProvider =
    NotifierProvider<CurrentSearchQuery, String?>(CurrentSearchQuery.new);

/// Pushes the results page, the same way `openWatch` pushes the watch page —
/// `FeedPage` stays mounted underneath, which is what carries its scroll
/// position through the round trip without any extra bookkeeping (Task 20 §5).
void openSearch(WidgetRef ref, String query, {SearchFilters? filters}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return;
  ref.read(currentSearchQueryProvider.notifier).set(trimmed);
  rootNavigatorKey.currentState?.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: searchRouteName),
      builder: (_) => SearchResultsPage(query: trimmed, filters: filters),
    ),
  );
}

class SearchResultsPage extends ConsumerStatefulWidget {
  const SearchResultsPage({super.key, required this.query, this.filters});

  final String query;
  final SearchFilters? filters;

  @override
  ConsumerState<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends ConsumerState<SearchResultsPage> {
  @override
  void initState() {
    super.initState();
    // Fired once per page instance rather than in `build()`, which Riverpod
    // may call more than once for the same widget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(searchProvider.notifier).search(widget.query, filters: widget.filters);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PageWrapper(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BackButton(onPressed: () => Navigator.of(context).maybePop()),
          Flexible(
            child: Text(
              '"${widget.query}"',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 20,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: _SearchFilterBar(),
          ),
          Expanded(
            child: FeedView(
              provider: searchProvider,
              emptyMessage: 'No results for "${widget.query}".',
            ),
          ),
        ],
      ),
    );
  }
}

/// Four dropdowns — one per dimension Task 20 §3 decided on. Each is
/// independent: picking a value replaces just that dimension and re-runs the
/// search (`FeedController.updateFilters`), which starts a fresh page exactly
/// like a chip switch does.
class _SearchFilterBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchProvider.select((s) => s.filters)) ?? const SearchFilters();

    void apply(SearchFilters next) {
      ref.read(searchProvider.notifier).updateFilters(next);
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _FilterDropdown<UploadDateFilter>(
            label: 'Upload date',
            value: filters.uploadDate,
            items: UploadDateFilter.values,
            labelOf: (v) => switch (v) {
              UploadDateFilter.hour => 'Last hour',
              UploadDateFilter.today => 'Today',
              UploadDateFilter.week => 'This week',
              UploadDateFilter.month => 'This month',
              UploadDateFilter.year => 'This year',
            },
            onChanged: (v) => apply(filters.copyWith(uploadDate: v)),
          ),
          const SizedBox(width: 8),
          _FilterDropdown<SearchTypeFilter>(
            label: 'Type',
            value: filters.type,
            items: SearchTypeFilter.values,
            labelOf: (v) => switch (v) {
              SearchTypeFilter.video => 'Video',
              SearchTypeFilter.channel => 'Channel',
              SearchTypeFilter.playlist => 'Playlist',
              SearchTypeFilter.movie => 'Movie',
            },
            onChanged: (v) => apply(filters.copyWith(type: v)),
          ),
          const SizedBox(width: 8),
          _FilterDropdown<DurationFilter>(
            label: 'Duration',
            value: filters.duration,
            items: DurationFilter.values,
            labelOf: (v) => switch (v) {
              DurationFilter.short => 'Under 4 minutes',
              DurationFilter.medium => '4–20 minutes',
              DurationFilter.long => 'Over 20 minutes',
            },
            onChanged: (v) => apply(filters.copyWith(duration: v)),
          ),
          const SizedBox(width: 8),
          _FilterDropdown<SortByFilter>(
            label: 'Sort by',
            value: filters.sortBy,
            items: SortByFilter.values,
            labelOf: (v) => switch (v) {
              SortByFilter.viewCount => 'View count',
            },
            onChanged: (v) => apply(filters.copyWith(sortBy: v)),
          ),
        ],
      ),
    );
  }
}

class _FilterDropdown<T> extends StatelessWidget {
  const _FilterDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final T? value;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: value != null ? scheme.primaryContainer : scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T?>(
          value: value,
          hint: Text(label, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          isDense: true,
          items: [
            DropdownMenuItem<T?>(value: null, child: Text('Any $label'.toLowerCase())),
            ...items.map((v) => DropdownMenuItem<T?>(value: v, child: Text(labelOf(v)))),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
