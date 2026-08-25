import 'package:flutter/material.dart';

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
            final bool showFullSearch = screenWidth > 700;

            return SizedBox(
              height: preferredSize.height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 1. LEFT SECTION (Menu & Title)
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

                  // 2. CENTER SECTION (Search Bar - ABSOLUTE CENTER)
                  // The horizontal padding guarantees it shrinks on medium screens
                  // without overlapping the left/right sections.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 280.0),
                    child: showFullSearch
                        ? const _SearchField()
                        : _buildCollapsedSearchButton(scheme),
                  ),

                  // 3. RIGHT SECTION (Actions)
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

                        // User Profile Avatar
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: scheme.surfaceContainerHighest,
                          child: Icon(Icons.person, color: scheme.onSurfaceVariant, size: 20),
                        ),

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

/// The search field, stateful only so it can own a [FocusNode].
///
/// The field draws its own container rather than using an `InputBorder`, so the
/// focus ring has to be drawn here too — and a focus ring is one of the places
/// the accent belongs (§3.3). Nothing else about the field changes on focus.
class _SearchField extends StatefulWidget {
  const _SearchField();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  /// `mounted` because `FocusNode.dispose()` unfocuses, and unfocusing notifies
  /// listeners — after the element is defunct. Without the guard that path calls
  /// `setState` on a disposed State.
  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _focus.hasFocus;

    return ConstrainedBox(
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
                child: TextField(
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
                ),
              ),
            ),
            // Search Button
            Container(
              width: 64,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
                border: Border(
                  left: BorderSide(color: scheme.outlineVariant, width: 1),
                ),
              ),
              child: Center(
                child: Icon(Icons.search, color: scheme.onSurface, size: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
