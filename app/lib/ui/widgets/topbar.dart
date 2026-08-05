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
                            icon: const Icon(Icons.menu, color: Colors.white),
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
                        ? _buildFullSearchBar() 
                        : _buildCollapsedSearchButton(),
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
                            const Icon(Icons.notifications_none, color: Colors.white, size: 28),
                            Positioned(
                              right: -8,
                              top: -4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFCC0000),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFF0F0F0F),
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
                                        color: Colors.white,
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
                        const CircleAvatar(
                          radius: 16,
                          backgroundColor: Color(0xFF404040),
                          child: Icon(Icons.person, color: Colors.white, size: 20),
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
  Widget _buildFullSearchBar() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: const Color.fromARGB(66, 0, 0, 0),
          borderRadius: BorderRadius.circular(40),
          border: Border.all(
            color: const Color.fromARGB(109, 105, 105, 105),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // Search Input Field
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16.0, right: 8.0),
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Search',
                    hintStyle: TextStyle(
                      color: Colors.grey.shade500,
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
              decoration: const BoxDecoration(
                color: Color.fromARGB(100, 51, 51, 51),
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
                border: Border(
                  left: BorderSide(color: Color(0xFF303030), width: 1),
                ),
              ),
              child: const Center(
                child: Icon(Icons.search, color: Colors.white, size: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedSearchButton() {
    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(
        color: Color.fromARGB(66, 0, 0, 0), // Same styling as the search bar background
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.search, color: Colors.white, size: 20),
        onPressed: () {
          // TODO: Open search overlay / expand search
        },
      ),
    );
  }
  
  @override
  Size get preferredSize => const Size.fromHeight(64.0);
}