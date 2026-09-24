import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/model_download_status_bar.dart';
import '../../core/widgets/responsive_shell.dart';
import '../capture/capture_screen.dart';
import '../chat/chat_screen.dart';
import '../mesh/cubit/mesh_cubit.dart';
import '../mesh/mesh_screen.dart';

/// Shell aplikasi: navigasi tab Mesh / Chat / Capture dengan responsive layout.
/// Desktop (>=800px): NavigationRail di kiri + konten centered (max 850px).
/// Mobile (<800px): BottomNavigationBar standar.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.onRefreshProfile});

  final VoidCallback? onRefreshProfile;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _pages = [MeshScreen(), ChatScreen(), CaptureScreen()];

  static const _destinations = [
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
  ];

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (ctx) => MeshMonitorCubit()..start(),
      // Status bar unduhan global di atas shell: tetap hidup di semua tab
      // sementara user mengerjakan hal lain saat model diunduh di background.
      child: Column(
        children: [
          const ModelDownloadStatusBar(),
          Expanded(
            child: ResponsiveShell(
              pages: _pages,
              initialIndex: _index,
              destinations: _destinations,
              onDestinationSelected: (i) => setState(() => _index = i),
            ),
          ),
        ],
      ),
    );
  }
}