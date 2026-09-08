import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/search_filters.dart';
import '../../theme/screen_values.dart';
import '../feed_controller.dart';
import '../page_wrapper.dart';
import '../player_shell.dart' show rootNavigatorKey;
import '../widgets/artist_panel_card.dart';
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

final currentSearchQueryProvider = NotifierProvider<CurrentSearchQuery, String?>(CurrentSearchQuery.new);

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
    final artist = ref.watch(searchProvider.select((s) => s.artist));

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
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: ScreenValues.contentMaxWidth),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: _SearchFilterBar(),
            ),
          ),
          Expanded(
            child: FeedView(
              provider: searchProvider,
              emptyMessage: 'No results for "${widget.query}".',
              isWideLayout: true,
              header: artist != null ? ArtistPanelCard(artist: artist) : null,
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
    final scheme = Theme.of(context).colorScheme;

    void apply(SearchFilters next) {
      ref.read(searchProvider.notifier).updateFilters(next);
    }

    // Determine which pill is active
    String activePill = 'All';
    if (filters.isEmpty) {
      activePill = 'All';
    } else if (filters == const SearchFilters(type: SearchTypeFilter.video, duration: DurationFilter.short)) {
      activePill = 'Shorts';
    } else if (filters == const SearchFilters(type: SearchTypeFilter.video)) {
      activePill = 'Videos';
    } else if (filters == const SearchFilters(uploadDate: UploadDateFilter.today)) {
      activePill = 'Recently uploaded';
    } else {
      activePill = ''; // Custom filters from dialog
    }

    Widget buildPill(String label, SearchFilters targetFilters, {bool implemented = true}) {
      final isSelected = activePill == label;
      return Padding(
        padding: const EdgeInsets.only(right: 8.0),
        child: FilterChip(
          label: Text(label),
          selected: isSelected,
          showCheckmark: false,
          onSelected: (_) {
            if (implemented) {
              apply(targetFilters);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not implemented')));
            }
          },
        ),
      );
    }

    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                buildPill('All', const SearchFilters()),
                buildPill('Shorts', const SearchFilters(), implemented: false),
                buildPill('Unwatched', const SearchFilters(), implemented: false),
                buildPill('Watched', const SearchFilters(), implemented: false),
                buildPill('Videos', const SearchFilters(type: SearchTypeFilter.video)),
                buildPill('Recently uploaded', const SearchFilters(uploadDate: UploadDateFilter.today)),
                buildPill('Live', const SearchFilters(), implemented: false),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () {
              showDialog(context: context, builder: (_) => const _SearchFiltersDialog());
            },
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Filters',
                    style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w500, fontSize: 14),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.tune, size: 18, color: scheme.onSurface),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchFiltersDialog extends ConsumerWidget {
  const _SearchFiltersDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchProvider.select((s) => s.filters)) ?? const SearchFilters();
    final scheme = Theme.of(context).colorScheme;

    void apply(SearchFilters next) {
      ref.read(searchProvider.notifier).updateFilters(next);
      Navigator.of(context).pop();
    }

    Widget buildSection<T>({
      required String title,
      required List<T> items,
      required String Function(T) labelOf,
      required T? currentValue,
      required ValueChanged<T?> onSelected,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurface),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          ...items.map((item) {
            final isSelected = currentValue == item;
            return _FilterOption(
              label: labelOf(item),
              isSelected: isSelected,
              onTap: () => onSelected(isSelected ? null : item),
            );
          }),
        ],
      );
    }

    Widget buildDummySection({required String title, required List<String> items}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurface),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          ...items.map((item) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                item,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            );
          }),
        ],
      );
    }

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Search filters',
                    style: TextStyle(fontSize: 18, color: scheme.onSurface, fontWeight: FontWeight.w400),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: buildSection<SearchTypeFilter>(
                      title: 'TYPE',
                      items: SearchTypeFilter.values,
                      currentValue: filters.type,
                      labelOf: (v) => switch (v) {
                        SearchTypeFilter.video => 'Videos',
                        SearchTypeFilter.channel => 'Channels',
                        SearchTypeFilter.playlist => 'Playlists',
                        SearchTypeFilter.movie => 'Movies',
                      },
                      onSelected: (v) => apply(filters.copyWith(type: v)),
                    ),
                  ),
                  const SizedBox(width: 32),
                  Expanded(
                    child: buildSection<DurationFilter>(
                      title: 'DURATION',
                      items: DurationFilter.values,
                      currentValue: filters.duration,
                      labelOf: (v) => switch (v) {
                        DurationFilter.short => 'Under 4 minutes',
                        DurationFilter.medium => '4 - 20 minutes',
                        DurationFilter.long => 'Over 20 minutes',
                      },
                      onSelected: (v) => apply(filters.copyWith(duration: v)),
                    ),
                  ),
                  const SizedBox(width: 32),
                  Expanded(
                    child: buildSection<UploadDateFilter>(
                      title: 'UPLOAD DATE',
                      items: UploadDateFilter.values,
                      currentValue: filters.uploadDate,
                      labelOf: (v) => switch (v) {
                        UploadDateFilter.hour => 'Last hour',
                        UploadDateFilter.today => 'Today',
                        UploadDateFilter.week => 'This week',
                        UploadDateFilter.month => 'This month',
                        UploadDateFilter.year => 'This year',
                      },
                      onSelected: (v) => apply(filters.copyWith(uploadDate: v)),
                    ),
                  ),
                  const SizedBox(width: 32),
                  Expanded(
                    child: buildDummySection(
                      title: 'FEATURES',
                      items: ['Live', '4K', 'HD', 'Subtitles/CC', 'Creative Commons', '360°', 'VR180', '3D', 'HDR', 'Location', 'Purchased'],
                    ),
                  ),
                  const SizedBox(width: 32),
                  Expanded(
                    child: buildSection<SortByFilter>(
                      title: 'PRIORITIZE',
                      items: SortByFilter.values,
                      currentValue: filters.sortBy,
                      labelOf: (v) => switch (v) {
                        SortByFilter.viewCount => 'Popularity',
                      },
                      onSelected: (v) => apply(filters.copyWith(sortBy: v)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterOption extends StatefulWidget {
  const _FilterOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_FilterOption> createState() => _FilterOptionState();
}

class _FilterOptionState extends State<_FilterOption> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isHighlighted = widget.isSelected || _isHovering;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 50),
            style: TextStyle(
              fontSize: 13,
              color: isHighlighted ? scheme.onSurface : scheme.onSurfaceVariant,
              fontWeight: FontWeight.normal,
            ),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}
