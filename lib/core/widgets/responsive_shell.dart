import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Breakpoint layar: >= [kDesktopBreakpoint] dianggap desktop/multi-pane.
const double kDesktopBreakpoint = 800;

/// Adaptive navigation shell that switches between:
/// - Desktop (width >= [desktopBreakpoint]): NavigationRail sidebar on the left
///   with a full-bleed active page filling the remaining width (multi-pane ready).
/// - Mobile (width < [desktopBreakpoint]): standard Scaffold with BottomNavigationBar.
///
/// The active page is responsible for its own internal split-view layout
/// (screens use `LayoutBuilder` internally to adapt).
class ResponsiveShell extends StatefulWidget {
  const ResponsiveShell({
    super.key,
    required this.pages,
    this.initialIndex = 0,
    this.onDestinationSelected,
    this.destinations = const [],
    this.sidebarWidth = 80,
    this.desktopBreakpoint = 800,
  });

  final List<Widget> pages;
  final int initialIndex;
  final ValueChanged<int>? onDestinationSelected;
  final List<NavigationDestination> destinations;
  final double sidebarWidth;
  final double desktopBreakpoint;

  @override
  State<ResponsiveShell> createState() => _ResponsiveShellState();
}

class _ResponsiveShellState extends State<ResponsiveShell> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
  }

  void _onDestinationSelected(int index) {
    setState(() => _selectedIndex = index);
    widget.onDestinationSelected?.call(index);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= widget.desktopBreakpoint;
        return isDesktop ? _buildDesktopLayout() : _buildMobileLayout();
      },
    );
  }

  Widget _buildDesktopLayout() {
    return Scaffold(
      backgroundColor: AppColors.slateDark,
      body: Row(
        children: [
          Container(
            width: widget.sidebarWidth,
            color: AppColors.deepCharcoal,
            child: NavigationRail(
              selectedIndex: _selectedIndex,
              onDestinationSelected: _onDestinationSelected,
              backgroundColor: AppColors.deepCharcoal,
              indicatorColor: AppColors.industrialAmber.withValues(alpha: 0.16),
              selectedIconTheme:
                  const IconThemeData(color: AppColors.industrialAmber, size: 24),
              unselectedIconTheme:
                  const IconThemeData(color: AppColors.textSecondary, size: 24),
              selectedLabelTextStyle: const TextStyle(
                color: AppColors.industrialAmber,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelTextStyle: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in widget.destinations)
                  NavigationRailDestination(
                    icon: d.icon,
                    selectedIcon: d.selectedIcon ?? d.icon,
                    label: Text(d.label),
                  ),
              ],
            ),
          ),
          Container(width: 1, color: AppColors.surfaceBorder),
          Expanded(
            child: IndexedStack(index: _selectedIndex, children: widget.pages),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout() {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: widget.pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: widget.destinations,
      ),
    );
  }
}