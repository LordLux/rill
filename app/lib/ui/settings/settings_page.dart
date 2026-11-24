import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../focus_ring.dart';
import '../focus_surface.dart';
import '../player_shell.dart' show rootNavigatorKey;
import '../widgets/topbar.dart';
import 'settings_section.dart';
import 'settings_sections.dart';

/// Settings (`architecture.md` §2.19): a sidebar of sections and the one chosen beside it,
/// in **a dialog over whatever page is open**.
///
/// **Not a route, and its scrim starts below the top bar.** A `showDialog` barrier covers the
/// whole navigator, and every page draws its own top bar — window buttons included — inside
/// it, so a modal route would leave minimize, maximize and close dead while Settings is open
/// (the login page did that once). This is an `OverlayEntry`, like the account menu: the
/// scrim covers the page and the rail, the top bar stays live, and focus is held in the
/// dialog's own scope. Escape, the close button and a click on the scrim close it, and focus
/// goes back to what had it.

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

/// The sidebar entry for a section; tests find one by it.
ValueKey<String> settingsSectionTabKey(String id) => ValueKey('settings-tab-$id');

/// The dialog's close button; tests find it by this key.
const ValueKey<String> settingsCloseKey = ValueKey('settings-close');

OverlayEntry? _entry;

/// The open dialog's focus scope, so closing knows whether focus was in it.
FocusScopeNode? _openScope;

/// Whether the dialog is open. An entry whose overlay went away with it (a whole app torn
/// down) is not open.
bool get settingsDialogOpen => _entry?.mounted ?? false;

/// What had focus when the dialog opened, for closing to give it back.
FocusNode? _previous;

/// Opens Settings, at [section] when one is given. Already open, it only switches section.
void openSettingsPage(WidgetRef ref, {String? section}) {
  if (section != null) ref.read(settingsSectionProvider.notifier).show(section);
  if (settingsDialogOpen) return;
  final overlay = rootNavigatorKey.currentState?.overlay;
  if (overlay == null) return;
  _previous = null;
  late final OverlayEntry entry;
  void close() {
    if (!identical(_entry, entry)) return;
    final focus = FocusManager.instance.primaryFocus;
    final scope = _openScope;
    final focusWasInside = focus == null || (scope != null && (focus == scope || focus.ancestors.contains(scope)));
    _entry = null;
    entry.remove();
    // Back to what had focus before, if it is still there. Focus somewhere else by now (the
    // search box beside the dialog) is the user's choice and is left alone.
    final previous = _previous;
    _previous = null;
    if (focusWasInside && previous != null && previous.context != null && previous.canRequestFocus) {
      previous.requestFocus();
    }
  }

  entry = OverlayEntry(builder: (_) => SettingsDialog(onClose: close));
  _entry = entry;
  overlay.insert(entry);
}

/// Forgets an entry whose overlay a test has already torn down.
@visibleForTesting
void resetSettingsDialogForTest() {
  _entry = null;
  _openScope = null;
  _previous = null;
}

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'settings dialog');

  @override
  void initState() {
    super.initState();
    _openScope = _scope;
    HardwareKeyboard.instance.addHandler(_onKey);
    // Focus moves in, so Tab starts inside and cannot reach the page under the scrim.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Read a frame late: a menu that opened this has handed focus back to its button by
      // now, and that button, not the menu's own scope, is where focus returns.
      _previous = FocusManager.instance.primaryFocus;
      _scope.requestFocus();
      if (KeyboardNavigation.active) _scope.nextFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (identical(_openScope, _scope)) _openScope = null;
    _scope.dispose();
    super.dispose();
  }

  /// Escape closes — while focus is in the dialog, or nowhere. Not from the top bar's search
  /// box, which stays live beside the dialog: there Escape belongs to the field.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!mounted) return false;
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus != _scope && !focus.ancestors.contains(_scope)) return false;
    widget.onClose();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top + TopBar.preferredHeight;
    return Positioned.fill(
      top: top,
      child: Stack(
        children: [
          // The scrim: covers the page and the rail, and a click on it closes.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.onClose,
              child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.55)),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth - 48).clamp(0.0, _dialogMaxWidth);
              final height = (constraints.maxHeight - 48).clamp(0.0, _dialogMaxHeight);
              return Center(
                child: SizedBox(
                  width: width,
                  height: height,
                  child: FocusScope(
                    node: _scope,
                    child: Semantics(
                      scopesRoute: true,
                      namesRoute: true,
                      explicitChildNodes: true,
                      label: 'Settings',
                      child: Material(
                        color: scheme.surfaceContainerLow,
                        elevation: 3,
                        shape: RoundedRectangleBorder(
                          borderRadius: const BorderRadius.all(Radius.circular(20)),
                          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: SettingsPanel(onClose: widget.onClose),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

const double _dialogMaxWidth = 1000;
const double _dialogMaxHeight = 760;

/// The dialog's contents: a header with the close button, then the sidebar and the section.
/// Public so a test can mount it without the overlay.
class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key, this.onClose});

  /// Null draws no close button.
  final VoidCallback? onClose;

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
    final scheme = Theme.of(context).colorScheme;
    final onClose = widget.onClose;

    return FocusSurface(
      ordered: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: _SectionSidebar(current: current.id, onPick: _show),
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(
            child: FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 20, 12, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(current.title, style: textTheme.headlineSmall),
                            ),
                          ),
                          if (onClose != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: IconButton(
                                key: settingsCloseKey,
                                onPressed: onClose,
                                icon: const Icon(Icons.close, semanticLabel: 'Close settings'),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      // Smooth wheel scrolling, as everywhere else in the app; a `Silky…` view also
                      // keeps the wheel from reaching the page under the dialog (§2.8).
                      child: SilkySingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
                        // Keyed so a section's state never carries over to the next.
                        child: KeyedSubtree(key: ValueKey(current.id), child: Builder(builder: current.builder)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
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
