import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/features/messaging/application/blocs/chat_list/chat_list_bloc.dart';
import 'package:sgtp_flutter/features/shell/presentation/widgets/main_bottom_navigation.dart';
import 'package:sgtp_flutter/features/messaging/presentation/pages/chat_list_screen.dart';

/// Main container for the app with bottom navigation
class MainContainer extends StatefulWidget {
  final VoidCallback? onChatSelected;

  const MainContainer({
    Key? key,
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
        return const Center(
          child: Text('Settings are available in the main Home screen.'),
        );
    }
  }
}

/// Convenience wrapper that provides ChatListBloc if not already provided
class MainContainerWithBloc extends StatelessWidget {
  final VoidCallback? onChatSelected;
  final ChatListBloc? chatListBloc;

  const MainContainerWithBloc({
    Key? key,
    this.onChatSelected,
    this.chatListBloc,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bloc = chatListBloc ?? context.read<ChatListBloc>();

    return BlocProvider.value(
      value: bloc,
      child: MainContainer(
        onChatSelected: onChatSelected,
      ),
    );
  }
}
