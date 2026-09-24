import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/models/mesh_node.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/model_path_picker_sheet.dart';
import '../cubit/mesh_cubit.dart';
import 'airdrop_radar.dart';
import 'daemon_cli_terminal.dart';
import 'node_control_bar.dart';
import 'peers_cache_panel.dart';
import 'sync_status_panel.dart';

/// Tampilan desktop 2 kolom: sidebar peers/caches + radar + panel bawah.
class DesktopMeshView extends StatefulWidget {
  const DesktopMeshView({
    super.key,
    required this.state,
    required this.sharedCaches,
    required this.onCacheToggle,
    required this.upRate,
    required this.downRate,
    required this.transfers,
    required this.onOpenQrPair,
    required this.onPeerTap,
  });

  final MeshMonitorState state;
  final Map<String, bool> sharedCaches;
  final ValueChanged<String> onCacheToggle;
  final double upRate;
  final double downRate;
  final List<MeshTransfer> transfers;
  final VoidCallback onOpenQrPair;
  final ValueChanged<MeshNode> onPeerTap;

  @override
  State<DesktopMeshView> createState() => _DesktopMeshViewState();
}

class _DesktopMeshViewState extends State<DesktopMeshView> {
  int _bottomPanelTab = 0;
  double _bottomPanelHeight = 220.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slateDark,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PeersSharedCachesPanel(
            state: widget.state,
            sharedCaches: widget.sharedCaches,
            onCacheToggle: widget.onCacheToggle,
            onPeerTap: widget.onPeerTap,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  state: widget.state,
                  upRate: widget.upRate,
                  downRate: widget.downRate,
                  onOpenQrPair: widget.onOpenQrPair,
                ),
                _RadarArea(onNodeTap: widget.onPeerTap, nodes: widget.state.nodes),
                _buildResizableBottomPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResizableBottomPanel() {
    return Container(
      height: _bottomPanelHeight,
      decoration: const BoxDecoration(
        color: AppColors.deepCharcoal,
        border: Border(top: BorderSide(color: AppColors.surfaceBorder)),
      ),
      child: Column(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              onVerticalDragUpdate: (details) {
                setState(() {
                  _bottomPanelHeight = (_bottomPanelHeight - details.delta.dy).clamp(110.0, 480.0);
                });
              },
              child: Container(
                height: 12,
                width: double.infinity,
                color: AppColors.slateDark,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.slateMuted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: AppColors.slateDark,
            child: Row(
              children: [
                _panelTabButton(0, 'Active Sync Status', Icons.sync_rounded),
                const SizedBox(width: 12),
                _panelTabButton(1, 'Daemon CLI Terminal', Icons.terminal_rounded),
              ],
            ),
          ),
          Expanded(
            child: _bottomPanelTab == 0
                ? SyncStatusPanel(transfers: widget.transfers)
                : DaemonCliTerminal(modelHosted: widget.state.modelHosted),
          ),
        ],
      ),
    );
  }

  Widget _panelTabButton(int index, String label, IconData icon) {
    final active = _bottomPanelTab == index;
    return InkWell(
      onTap: () => setState(() => _bottomPanelTab = index),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: active
              ? const Border(bottom: BorderSide(color: AppColors.cyanAccent, width: 2))
              : null,
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? AppColors.cyanAccent : AppColors.textMuted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? AppColors.textPrimary : AppColors.textMuted,
                fontSize: 11,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.upRate,
    required this.downRate,
    required this.onOpenQrPair,
  });

  final MeshMonitorState state;
  final double upRate;
  final double downRate;
  final VoidCallback onOpenQrPair;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: const BoxDecoration(
        color: AppColors.deepCharcoal,
        border: Border(bottom: BorderSide(color: AppColors.surfaceBorder)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= 720) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.account_tree_rounded, color: AppColors.industrialAmber, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'Node Control & P2P Radar',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    TrafficChips(up: upRate, down: downRate),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Pilih File Model (.gguf)',
                      onPressed: () => ModelPathPickerSheet.show(context),
                      icon: const Icon(Icons.smart_toy_outlined,
                          color: AppColors.cyanAccent, size: 18),
                    ),
                    const SizedBox(width: 4),
                    OutlinedButton.icon(
                      onPressed: onOpenQrPair,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.cyanAccent,
                        side: BorderSide(color: AppColors.cyanAccent.withValues(alpha: 0.5)),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 15),
                      label: const Text('Pair via QR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    RoleConfig(state: state),
                    const SizedBox(width: 16),
                    Expanded(child: StorageQuota(storage: state.storage)),
                  ],
                ),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_tree_rounded, color: AppColors.industrialAmber, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'Node Control & P2P Radar',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Pilih File Model (.gguf)',
                    onPressed: () => ModelPathPickerSheet.show(context),
                    icon: const Icon(Icons.smart_toy_outlined,
                        color: AppColors.cyanAccent, size: 18),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpenQrPair,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.cyanAccent,
                      side: BorderSide(color: AppColors.cyanAccent.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 14),
                    label: const Text('Pair', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  RoleConfig(state: state),
                  TrafficChips(up: upRate, down: downRate),
                ],
              ),
              const SizedBox(height: 8),
              StorageQuota(storage: state.storage),
            ],
          );
        },
      ),
    );
  }
}

class _RadarArea extends StatelessWidget {
  const _RadarArea({required this.nodes, required this.onNodeTap});

  final List<MeshNode> nodes;
  final ValueChanged<MeshNode> onNodeTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final side = math.min(c.maxWidth, c.maxHeight);
                  return Center(
                    child: SizedBox(
                      width: side,
                      height: side,
                      child: AirdropRadar(
                        nodes: nodes,
                        onNodeTap: onNodeTap,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RadarLegend(AppColors.success, 'Terhubung'),
                SizedBox(width: 14),
                _RadarLegend(AppColors.industrialAmber, 'Sync'),
                SizedBox(width: 14),
                _RadarLegend(AppColors.textMuted, 'Lepas'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarLegend extends StatelessWidget {
  const _RadarLegend(this.color, this.label);

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
      ],
    );
  }
}