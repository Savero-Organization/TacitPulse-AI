import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../capture/capture_screen.dart';
import '../chat/chat_screen.dart';
import '../mesh/cubit/mesh_cubit.dart';
import '../mesh/mesh_screen.dart';

/// Shell aplikasi: navigasi tab Mesh / Chat / Capture.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.onRefreshProfile});

  final VoidCallback? onRefreshProfile;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _pages = [MeshScreen(), ChatScreen(), CaptureScreen()];

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (ctx) => MeshMonitorCubit()..start(),
      child: Scaffold(
        body: IndexedStack(index: _index, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.near_me_outlined, color: AppColors.textSecondary),
              selectedIcon: Icon(Icons.near_me, color: AppColors.industrialAmber),
              label: 'AirDrop',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline_rounded, color: AppColors.textSecondary),
              selectedIcon: Icon(Icons.chat_bubble_rounded, color: AppColors.industrialAmber),
              label: 'Chat',
            ),
            NavigationDestination(
              icon: Icon(Icons.mic_none_rounded, color: AppColors.textSecondary),
              selectedIcon: Icon(Icons.mic_rounded, color: AppColors.industrialAmber),
              label: 'Capture',
            ),
          ],
        ),
      ),
    );
  }
}