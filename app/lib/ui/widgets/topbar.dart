import 'package:flutter/material.dart';

class TopBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBar({
    super.key,
    required this.title,
    required this.actions,
    required this.toggleDrawer,
  });

  final Widget? title;
  final List<Widget> actions;
  final VoidCallback toggleDrawer;

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent, // Ensure the container color shows through
      elevation: 0,
      leading: SizedBox(
        width: 72,
        child: Padding(
          padding: const EdgeInsets.only(top: 8.0, left: 14.0, bottom: 4.0),
          child: IconButton(
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            icon: const Icon(Icons.menu, color: Colors.white),
            onPressed: toggleDrawer,
          ),
        ),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          title ?? const Text('YouTube', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
          
          // --- FIXED SEARCH BAR SECTION ---
          Expanded(
            child: Center( // <-- This Center widget prevents Expanded from overriding the max width
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600), // Set to a realistic max width
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color.fromARGB(66, 0, 0, 0), // Darker inner background
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(
                      color: const Color.fromARGB(109, 105, 105, 105), // Subtle gray border
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
                          color: Color.fromARGB(100, 51, 51, 51), // Lighter gray button background
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(40),
                            bottomRight: Radius.circular(40),
                          ),
                          border: Border(
                            left: BorderSide(
                              color: Color(0xFF303030),
                              width: 1,
                            ),
                          ),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.search,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ---------------------------------
    
          const SizedBox(width: 24), 
          
          // Right Action Buttons Section
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Create Button
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.add, color: Colors.white, size: 20),
                    SizedBox(width: 6),
                    Text(
                      'Create',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
        
              const SizedBox(width: 24),
        
              // Notification Icon with Badge
              Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications_none, color: Colors.white, size: 28),
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFFCC0000), // Notification red
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFF0F0F0F), 
                          width: 2,
                        ),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 18,
                      ),
                      child: const Center(
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
                ],
              ),
        
              const SizedBox(width: 24),
        
              // User Profile Avatar
              const CircleAvatar(
                radius: 16,
                backgroundColor: Color(0xFF404040),
                child: Icon(Icons.person, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      actions: actions, // Fallback if you decide to use native AppBar actions later
    );
  }
  
  @override
  Size get preferredSize => const Size.fromHeight(64.0);
}