
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pages/search_results.dart';
import '../search_suggest_controller.dart';
import 'account_button.dart';

class TopBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBar({
    super.key,
    required this.title,
    required this.actions,
    required this.toggleDrawer,
  });

  final Widget title;
  final List<Widget> actions;
  final VoidCallback toggleDrawer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppBar(
      automaticallyImplyLeading: false, // We provide our own leading widget
      surfaceTintColor: Colors.transparent,
      backgroundColor: Colors.transparent, // Ensure the container color shows through
      elevation: 0,
      flexibleSpace: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screenWidth = constraints.maxWidth;
            // Define the breakpoint for when the search bar collapses
            final bool showFullSearch = screenWidth > 634;

            return SizedBox(
              height: preferredSize.height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // LEFT SECTION (Menu & Title)
                  Positioned(
                    left: 0,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 16, right: 13),
                          child: IconButton(
                            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                            icon: Icon(Icons.menu, color: scheme.onSurface),
                            onPressed: toggleDrawer,
                          ),
                        ),
                        title,
                      ],
                    ),
                  ),

                  // CENTER SECTION: Search Bar
                  // The horizontal padding guarantees it shrinks on medium screens
                  // without overlapping the left/right sections.
                  showFullSearch
                      ? Padding(
                          padding: EdgeInsets.only(left: 280.0, right: 200.0),
                          child: const _SearchField(),
                        )
                      : Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 120.0),
                            child: _buildCollapsedSearchButton(scheme),
                          ),
                        ),

                  // RIGHT SECTION (Actions)
                  Positioned(
                    right: 16,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Notification Icon with Badge
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(Icons.notifications_none, color: scheme.onSurface, size: 28),
                            Positioned(
                              right: -8,
                              top: -4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  // Was YouTube red. A count badge is an
                                  // attention marker, which is what `error` is
                                  // for — and it is emphatically not the accent
                                  // (§3.3: no accent on badges).
                                  color: scheme.error,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    // Reads as a cut-out from the bar behind it,
                                    // so it has to be the bar's own colour.
                                    color: scheme.surface,
                                    width: 2,
                                  ),
                                ),
                                constraints: const BoxConstraints(minWidth: 20, minHeight: 18),
                                child: Center(
                                  child: Transform.translate(
                                    offset: const Offset(0.5, -1),
                                    child: Text(
                                      '9+',
                                      style: TextStyle(
                                        color: scheme.onError,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        height: 1,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 24),

                        // The account surface — Task 22 §7. The placeholder
                        // person glyph that used to sit here is now what
                        // `AccountButton` draws when nobody is signed in.
                        const AccountButton(),

                        // Include any extra actions passed to the widget
                        ...actions,
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCollapsedSearchButton(ColorScheme scheme) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest, // Same styling as the search bar background
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(Icons.search, color: scheme.onSurface, size: 20),
        onPressed: () {
          // TODO: Open search overlay / expand search
        },
      ),
    );
  }

  /// One source of truth for `player_shell.dart`'s caption clip, which has no
  /// other way to know how tall this bar is without instantiating one.
  static const double preferredHeight = 64.0;

  @override
  Size get preferredSize => const Size.fromHeight(preferredHeight);
}

/// The search field: a controller, a debounced suggestions dropdown, and Enter
/// to search (Task 20 §4–5). Escape and blur close the dropdown; a suggestion
/// tap or Enter navigates to results with whatever text is in the box at that
/// moment.
///
/// The field draws its own container rather than using an `InputBorder`, so the
/// focus ring has to be drawn here too — and a focus ring is one of the places
/// the accent belongs (§3.3). Nothing else about the field changes on focus.
class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final FocusNode _focus = FocusNode();
  final TextEditingController _controller = TextEditingController();
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    final current = ref.read(currentSearchQueryProvider);
    if (current != null) _controller.text = current;
  }

  /// `mounted` because `FocusNode.dispose()` unfocuses, and unfocusing notifies
  /// listeners — after the element is defunct. Without the guard that path calls
  /// `setState` on a disposed State.
  void _onFocusChanged() {
    if (!_focus.hasFocus) ref.read(searchSuggestProvider.notifier).close();
    if (mounted) setState(_syncOverlay);
  }

  @override
  void dispose() {
    _removeOverlay();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit(String text) {
    ref.read(searchSuggestProvider.notifier).close();
    _focus.unfocus();
    openSearch(ref, text);
  }

  /// Enter, with a suggestion arrow-highlighted: search *that* suggestion,
  /// not whatever is still sitting in the text field — the highlight is a
  /// choice the user just made, and submitting the box's stale text past it
  /// would silently discard it. No highlight falls back to the box's own
  /// text, which is `TextField.onSubmitted`'s ordinary behaviour.
  void _submitHighlightedOrText(String text) {
    final suggestState = ref.read(searchSuggestProvider);
    final index = suggestState.highlightedIndex;
    final chosen = (index != null && index < suggestState.suggestions.length) ? suggestState.suggestions[index] : text;
    _submit(chosen);
  }

  void _syncOverlay() {
    final state = ref.read(searchSuggestProvider);
    final shouldShow = _focus.hasFocus && state.isOpen && state.suggestions.isNotEmpty;
    if (shouldShow && _overlay == null) {
      _overlay = _buildOverlay();
      Overlay.of(context).insert(_overlay!);
    } else if (!shouldShow && _overlay != null) {
      _removeOverlay();
    } else {
      _overlay?.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  OverlayEntry _buildOverlay() {
    return OverlayEntry(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final suggestions = ref.watch(searchSuggestProvider.select((s) => s.suggestions));
        final highlightedIndex = ref.watch(searchSuggestProvider.select((s) => s.highlightedIndex));
        return Positioned(
          width: 600,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            offset: const Offset(0, 44),
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              color: scheme.surfaceContainerLowest,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: suggestions.length,
                  itemBuilder: (context, index) {
                    final suggestion = suggestions[index];
                    final isHighlighted = index == highlightedIndex;
                    return ListTile(
                      dense: true,
                      selected: isHighlighted,
                      selectedTileColor: scheme.surfaceContainerHigh,
                      leading: const Icon(Icons.search, size: 18),
                      title: Text(suggestion),
                      onTap: () {
                        _controller.text = suggestion;
                        _submit(suggestion);
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _focus.hasFocus;

    // A navigation-driven query (opening results from a tile's related search,
    // or landing back on this route) updates the box — but only while the user
    // is not actively typing in it, so a debounced suggestion fetch elsewhere
    // never overwrites what they are mid-way through.
    ref.listen(currentSearchQueryProvider, (previous, next) {
      if (next == null || _focus.hasFocus) return;
      _controller.text = next;
    });

    ref.listen(searchSuggestProvider, (previous, next) {
      if (previous?.suggestions != next.suggestions || previous?.isOpen != next.isOpen || previous?.highlightedIndex != next.highlightedIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncOverlay();
        });
      }
    });

    return CompositedTransformTarget(
      link: _link,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(40),
            border: Border.all(
              color: focused ? scheme.primary : scheme.outlineVariant,
              width: focused ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              // Search Input Field
              Expanded(
                child: Padding(
                  // The focused border is a pixel thicker; absorbing that here
                  // keeps the text from shifting when the field takes focus.
                  padding: EdgeInsets.only(left: focused ? 15.0 : 16.0, right: 8.0),
                  child: Shortcuts(
                    shortcuts: {
                      LogicalKeySet(LogicalKeyboardKey.escape): const _CloseSearchIntent(),
                      // A single-line `TextField` has no vertical text of its
                      // own to move a cursor through, so `EditableText` does
                      // not claim these — they reach here unhandled, which is
                      // exactly what let the dropdown steal them for its own
                      // navigation instead.
                      LogicalKeySet(LogicalKeyboardKey.arrowDown): const _MoveHighlightIntent(1),
                      LogicalKeySet(LogicalKeyboardKey.arrowUp): const _MoveHighlightIntent(-1),
                    },
                    child: Actions(
                      actions: {
                        _CloseSearchIntent: CallbackAction<_CloseSearchIntent>(
                          onInvoke: (_) {
                            ref.read(searchSuggestProvider.notifier).close();
                            _focus.unfocus();
                            return null;
                          },
                        ),
                        _MoveHighlightIntent: CallbackAction<_MoveHighlightIntent>(
                          onInvoke: (intent) {
                            ref.read(searchSuggestProvider.notifier).moveHighlight(intent.delta);
                            return null;
                          },
                        ),
                      },
                      child: TextField(
                        controller: _controller,
                        focusNode: _focus,
                        style: TextStyle(color: scheme.onSurface, fontSize: 16),
                        decoration: InputDecoration(
                          hintText: 'Search',
                          hintStyle: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 16,
                            fontWeight: FontWeight.w400,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onChanged: (text) => ref.read(searchSuggestProvider.notifier).onTextChanged(text),
                        onSubmitted: _submitHighlightedOrText,
                      ),
                    ),
                  ),
                ),
              ),
              // Search Button
              Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
                child: InkWell(
                  onTap: () => _submit(_controller.text),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(40),
                    bottomRight: Radius.circular(40),
                  ),
                  mouseCursor: SystemMouseCursors.click,
                  child: Container(
                    width: 64,
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: scheme.outlineVariant, width: 1),
                      ),
                    ),
                    child: Center(
                      child: Icon(Icons.search, color: scheme.onSurface, size: 24),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseSearchIntent extends Intent {
  const _CloseSearchIntent();
}

/// Arrow-down (`1`) or arrow-up (`-1`) through the suggestions dropdown.
class _MoveHighlightIntent extends Intent {
  const _MoveHighlightIntent(this.delta);
  final int delta;
}
