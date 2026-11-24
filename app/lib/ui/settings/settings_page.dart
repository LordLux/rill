import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../focus_surface.dart';
import '../page_wrapper.dart';
import '../player_shell.dart' show currentRouteProvider, rootNavigatorKey;
import 'settings_section.dart';
import 'settings_sections.dart';

/// The settings page (`architecture.md` §2.19): a sidebar of sections, and the one chosen
/// beside it.
///
/// **A page in the content navigator, like the playlist page,** so the title bar, the
/// window buttons and the rail stay where they are and Back returns to the page it was
/// opened over. Switching sections is not navigation: Back and Escape leave Settings.
const String settingsRouteName = 'settings';

/// The section showing, by [SettingsSection.id]. Kept for the run, so Settings reopens
/// where it was left.
class SettingsSectionChoice extends Notifier<String> {
  @override
  String build() => settingsSections.first.id;

  void show(String id) {
    if (settingsSections.any((s) => s.id == id)) state = id;
  }
}

final settingsSectionProvider = NotifierProvider<SettingsSectionChoice, String>(SettingsSectionChoice.new);

/// Opens Settings, at [section] when one is given. Already open, it only switches section.
void openSettingsPage(WidgetRef ref, {String? section}) {
  if (section != null) ref.read(settingsSectionProvider.notifier).show(section);
  if (ref.read(currentRouteProvider) == settingsRouteName) return;
  rootNavigatorKey.currentState?.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: settingsRouteName),
      builder: (_) => const SettingsPage(),
    ),
  );
}

/// The sidebar entry for a section; tests find one by it.
ValueKey<String> settingsSectionTabKey(String id) => ValueKey('settings-tab-$id');

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _scroll.dispose();
    super.dispose();
  }

  /// Escape leaves the page — only while it is the page on top and focus is on it (or
  /// nowhere): a menu or dialog over it closes first, and takes the key itself.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext != null && focusContext.mounted && ModalRoute.of(focusContext) != route) return false;
    rootNavigatorKey.currentState?.maybePop();
    return true;
  }

  void _show(String id) {
    if (ref.read(settingsSectionProvider) == id) return;
    ref.read(settingsSectionProvider.notifier).show(id);
    // A new section starts at its top. A jump, never an animation (CLAUDE.md, F51).
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final currentId = ref.watch(settingsSectionProvider);
    final current = settingsSections.firstWhere((s) => s.id == currentId, orElse: () => settingsSections.first);
    final textTheme = Theme.of(context).textTheme;

    return PageWrapper(
      title: const Text('Settings'),
      body: FocusSurface(
        ordered: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(1),
              child: FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: _SectionSidebar(current: current.id, onPick: _show),
              ),
            ),
            Expanded(
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: Material(
                    type: MaterialType.transparency,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Semantics(
                                  header: true,
                                  child: Text(current.title, style: textTheme.headlineSmall),
                                ),
                              ),
                              // Keyed so a section's state never carries over to the next.
                              KeyedSubtree(key: ValueKey(current.id), child: Builder(builder: current.builder)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionSidebar extends StatelessWidget {
  const _SectionSidebar({required this.current, required this.onPick});

  final String current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final section in settingsSections)
                _SectionTab(
                  key: settingsSectionTabKey(section.id),
                  section: section,
                  selected: section.id == current,
                  onTap: () => onPick(section.id),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTab extends StatelessWidget {
  const _SectionTab({super.key, required this.section, required this.selected, required this.onTap});

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(10));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.primaryContainer.withAlpha(128) : Colors.transparent,
        borderRadius: _radius,
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          label: section.title,
          selected: selected,
          button: true,
          child: InkWell(
            borderRadius: _radius,
            onTap: onTap,
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(section.icon, size: 20, color: foreground),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        section.title,
                        style: TextStyle(
                          fontSize: 14,
                          color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
