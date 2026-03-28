import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/chat_list/chat_list_bloc.dart';
import '../widgets/main_bottom_navigation.dart';
import '../pages/chat_list_screen.dart';
import '../pages/settings_screen.dart';

/// Main container for the app with bottom navigation
class MainContainer extends StatefulWidget {
  final Set<String> whitelist;
  final ValueChanged<Set<String>>? onWhitelistChanged;
  final VoidCallback? onChatSelected;

  const MainContainer({
    Key? key,
    required this.whitelist,
    this.onWhitelistChanged,
    this.onChatSelected,
  }) : super(key: key);

  @override
  State<MainContainer> createState() => _MainContainerState();
}

class _MainContainerState extends State<MainContainer> {
  MainTab _currentTab = MainTab.chats;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildTabContent(),
      bottomNavigationBar: MainBottomNavigation(
        currentTab: _currentTab,
        onTabChanged: (tab) {
          setState(() => _currentTab = tab);
        },
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_currentTab) {
      case MainTab.chats:
        return ChatListScreen(
          onChatSelected: widget.onChatSelected,
        );
      case MainTab.settings:
        return SettingsScreen(
          whitelist: widget.whitelist,
          onWhitelistChanged: (newWhitelist) {
            widget.onWhitelistChanged?.call(newWhitelist);
          },
        );
    }
  }
}

/// Convenience wrapper that provides ChatListBloc if not already provided
class MainContainerWithBloc extends StatelessWidget {
  final Set<String> whitelist;
  final ValueChanged<Set<String>>? onWhitelistChanged;
  final VoidCallback? onChatSelected;
  final ChatListBloc? chatListBloc;

  const MainContainerWithBloc({
    Key? key,
    required this.whitelist,
    this.onWhitelistChanged,
    this.onChatSelected,
    this.chatListBloc,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bloc = chatListBloc ?? context.read<ChatListBloc>();

    return BlocProvider.value(
      value: bloc,
      child: MainContainer(
        whitelist: whitelist,
        onWhitelistChanged: onWhitelistChanged,
        onChatSelected: onChatSelected,
      ),
    );
  }
}
