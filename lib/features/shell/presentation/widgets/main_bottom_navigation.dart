import 'package:flutter/material.dart';

enum MainTab { chats, settings }

class MainBottomNavigation extends StatelessWidget {
  final MainTab currentTab;
  final ValueChanged<MainTab> onTabChanged;

  const MainBottomNavigation({
    Key? key,
    required this.currentTab,
    required this.onTabChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentTab.index,
      onTap: (index) {
        final newTab = MainTab.values[index];
        onTabChanged(newTab);
      },
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.chat_bubble_outline),
          activeIcon: Icon(Icons.chat_bubble),
          label: 'Chats',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.settings_outlined),
          activeIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    );
  }
}
