import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/screen_values.dart';
import '../pages/search_results.dart';
import '../search_suggest_controller.dart';
import 'account_button.dart';
import 'titlebar_button.dart';
import 'window_controls.dart';

class TopBar extends ConsumerWidget implements PreferredSizeWidget {
  const TopBar({
    super.key,
    required this.toggleDrawer,
    this.showBackButton = false,
    this.onBack,
  });

  final VoidCallback toggleDrawer;

  /// Whether to show the back-navigation arrow to the left of the logo.
  final bool showBackButton;
  final VoidCallback? onBack;

  /// One source of truth for `player_shell.dart`'s caption clip, which has no
  /// other way to know how tall this bar is without instantiating one.
  static const double preferredHeight = ScreenValues.titlebarsHeight;

  @override
  Size get preferredSize => const Size.fromHeight(preferredHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    // The drag region and the window buttons are the only two native pieces of
    // this bar, and neither can be built under `flutter test` — see
    // `window_controls.dart` for why, and why the seam is a provider.
    final windowControls = ref.watch(windowControlsProvider);

    return SizedBox(
      height: preferredHeight,
      child: Stack(
        children: [
          // Drag-to-move region covering the whole bar.  Translucent, so
          // pointer events pass through to the interactive children below.
          Positioned.fill(child: windowControls.dragRegion()),

          // The actual titlebar content sits above the drag detector.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── LEFT: menu + optional back + logo ───────────────────────
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    TitleBarIconButton(
                      icon: Icons.menu,
                      tooltip: 'Toggle menu',
                      onTap: toggleDrawer,
                      scheme: scheme,
                    ),
                    ClipRect(
                      child: AnimatedAlign(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.centerLeft,
                        widthFactor: showBackButton ? 1.0 : 0.0,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          opacity: showBackButton ? 1.0 : 0.0,
                          // Collapsed to zero width, the arrow is still in the
                          // tree with a live `onTap`: without these, Tab stops on
                          // an invisible button and a screen reader announces it.
                          child: ExcludeFocus(
                            excluding: !showBackButton,
                            child: ExcludeSemantics(
                              excluding: !showBackButton,
                              child: IgnorePointer(
                                ignoring: !showBackButton,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(width: 2),
                                    TitleBarIconButton(
                                      icon: Icons.arrow_back,
                                      tooltip: 'Back',
                                      onTap: onBack,
                                      scheme: scheme,
                                      overrideRadius: ScreenValues.railItemBorderRadius,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _RillLogo(scheme: scheme),
                    const SizedBox(width: 12),
                  ],
                ),
              ),

              // ── CENTER: search bar fills remaining space ─────────────────
              const Expanded(child: SizedBox.shrink()),

              // ── RIGHT: notifications + avatar + window controls ──────────
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 8),
                  _NotificationButton(scheme: scheme),
                  const SizedBox(width: 8),
                  const AccountButton(),
                  const SizedBox(width: 8),
                  // Window control buttons — drawn right at the edge so they
                  // line up with where Windows expects them.
                  windowControls.buttons(Theme.of(context)),
                ],
              ),
            ],
          ),
          Row(
            children: [
              Expanded(child: SizedBox.shrink()),
              Expanded(child: _CenteredSearch()),
              Expanded(child: SizedBox.shrink()),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Logo
// ─────────────────────────────────────────────────────────────────────────────

class _RillLogo extends StatelessWidget {
  const _RillLogo({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, 1.5),
      child: Text(
        'Rill',
        style: TextStyle(
          color: scheme.primary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search — centred and constrained
// ─────────────────────────────────────────────────────────────────────────────

/// Vertically centres the search field inside the titlebar and keeps it from
/// ever touching the left or right sections.
class _CenteredSearch extends StatelessWidget {
  const _CenteredSearch();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        // Never wider than 600 px; shrinks on small windows.
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: const _SearchField(),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Notification button
// ─────────────────────────────────────────────────────────────────────────────

/// The notifications entry point — **disabled until something is behind it.**
///
/// There is no notifications source: `protocol.md` has no method for YouTube's
/// notification menu. This used to be a live button that did nothing, under a
/// hard-coded "9+" — a count of nothing, which is the "live control that lies"
/// `architecture.md` §2.7 argues against. So it is drawn disabled, with a
/// tooltip saying so, and the badge draws only when there is a count to show.
/// Today that is never; wiring a source means replacing [unreadCount] and
/// giving the button an `onTap`.
class _NotificationButton extends StatelessWidget {
  const _NotificationButton({required this.scheme});
  final ColorScheme scheme;

  /// Unread notifications. Zero until a source exists (see above).
  final int unreadCount = 0;

  @override
  Widget build(BuildContext context) {
    final button = TitleBarIconButton(
      icon: Icons.notifications_none,
      tooltip: 'Notifications — not available yet',
      onTap: null,
      scheme: scheme,
      overrideRadius: ScreenValues.railItemBorderRadius,
    );
    if (unreadCount <= 0) return button;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        Positioned(
          right: 8,
          top: 11,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              // An attention marker — §3.3: no accent on badges, error is
              // the semantic role for attention indicators.
              color: scheme.error,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.surface, width: 2.15, strokeAlign: BorderSide.strokeAlignOutside),
            ),
            constraints: const BoxConstraints(minWidth: 20, minHeight: 13),
            child: Center(
              child: Transform.translate(
                offset: const Offset(0.5, -0.51),
                child: Text(
                  unreadCount > 9 ? '9+' : '$unreadCount',
                  style: TextStyle(
                    color: scheme.onError,
                    fontSize: 9,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search field — identical logic to the previous implementation
// ─────────────────────────────────────────────────────────────────────────────

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
    openSearchOrVideo(ref, text);
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
            offset: const Offset(0, 38),
            // Same group as the TextField's default `groupId` (`EditableText`)
            // so a click in here isn't "outside" it. Without this, the pointer
            // *down* on a ListTile unfocuses the field and tears down this
            // overlay before the ListTile's onTap ever fires — the tap is lost,
            // and only keyboard selection (which never touches focus) works.
            child: TextFieldTapRegion(
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: focused ? scheme.primary : scheme.outlineVariant, width: focused ? 1.5 : 1, strokeAlign: BorderSide.strokeAlignOutside),
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
                      style: TextStyle(color: scheme.onSurface, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search',
                        hintStyle: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
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
                  width: 48,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: scheme.outlineVariant, width: 1),
                    ),
                  ),
                  child: Center(
                    child: Icon(Icons.search, color: scheme.onSurface, size: 20),
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

class _CloseSearchIntent extends Intent {
  const _CloseSearchIntent();
}

/// Arrow-down (`1`) or arrow-up (`-1`) through the suggestions dropdown.
class _MoveHighlightIntent extends Intent {
  const _MoveHighlightIntent(this.delta);
  final int delta;
}
