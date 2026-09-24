import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/mesh_node.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/model_path_picker_sheet.dart';
import '../../../core/widgets/widgets.dart';
import '../cubit/mesh_cubit.dart';
import 'airdrop_radar.dart';
import 'node_control_bar.dart';
import 'peers_cache_panel.dart';
import 'sync_status_panel.dart';

/// Tampilan mobile satu halaman (tanpa nested tabs):
/// radar hero, sinkronisasi, peers/caches, kontrol node, ringkasan jaringan.
class MobileMeshView extends StatelessWidget {
  const MobileMeshView({
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slateDark,
      appBar: AppBar(
        title: const Text('Node Mesh'),
        actions: [
          IconButton(
            tooltip: 'Pilih File Model (.gguf)',
            onPressed: () => ModelPathPickerSheet.show(context),
            icon: const Icon(Icons.smart_toy_outlined,
                color: AppColors.textSecondary, size: 20),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: BadgeChip(
                label: state.isLocalFullNode ? 'FULL NODE' : 'LIGHT NODE',
                color: AppColors.industrialAmber,
                light: AppColors.industrialAmber,
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => context.read<MeshMonitorCubit>().reloadProfile(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _buildRadarHero(context),
            const SizedBox(height: 16),
            SyncStatusPanel(transfers: transfers),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Active Peers'),
            for (final n in state.nodes)
              PeerTile(
                node: n,
                isSelf: n.id == 'node-00' || n.id == state.localDeviceId,
                displayName: (n.id == 'node-00' || n.id == state.localDeviceId)
                    ? (state.profile?.fullName ?? 'Savero Madajaya')
                    : null,
                onTap: () => onPeerTap(n),
              ),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Knowledge Caches'),
            for (final item in cacheItems)
              CacheRow(
                item: item,
                shared: item.requiresLocalFile
                    ? state.modelHosted && (sharedCaches[item.name] ?? true)
                    : (sharedCaches[item.name] ?? true),
                enabled: !item.requiresLocalFile || state.modelHosted,
                onToggle: () => onCacheToggle(item.name),
              ),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Node Role Config'),
            SizedBox(
              width: double.infinity,
              child: RoleConfig(state: state),
            ),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Storage Quota'),
            StorageQuota(storage: state.storage),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Live Traffic'),
            LiveTrafficCard(up: upRate, down: downRate),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Jaringan'),
            _buildNetworkSummary(context),
            const SizedBox(height: 24),
            _buildQrPairingButton(context),
          ],
        ),
      ),
    );
  }

  Widget _buildRadarHero(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 200,
          width: double.infinity,
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: LayoutBuilder(
                builder: (context, c) {
                  final side = math.min(c.maxWidth, c.maxHeight);
                  return Center(
                    child: SizedBox(
                      width: side,
                      height: side,
                      child: AirdropRadar(
                        nodes: state.nodes,
                        onNodeTap: onPeerTap,
                      ),
                    ),
                  );
                },
              ),
            ),
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
    );
  }

  Widget _buildNetworkSummary(BuildContext context) {
    final stats = state.meshStats;
    final self = state.nodes.firstWhere(
      (n) => n.id == 'node-00' || n.id == state.localDeviceId,
      orElse: () => state.nodes.first,
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        children: [
          _row(Icons.devices_other_rounded, 'Node ID', state.localDeviceId),
          const Divider(height: 16),
          _row(Icons.hub_rounded, 'Terhubung', '${stats.connectedNodes} / ${state.nodes.length}'),
          const Divider(height: 16),
          _row(Icons.account_tree_rounded, 'K-Buckets Aktif', '${stats.kbucketsActive}'),
          const Divider(height: 16),
          _row(Icons.sync_rounded, 'Tersinkron', '${stats.syncedBytesMb} MB'),
          const Divider(height: 16),
          _row(Icons.battery_std_rounded, 'Baterai', '${self.battery}% · signal ${self.signal}/4'),
        ],
      ),
    );
  }

  Widget _buildQrPairingButton(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onOpenQrPair,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.cyanAccent,
        side: BorderSide(color: AppColors.cyanAccent.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      icon: const Icon(Icons.qr_code_scanner_rounded),
      label: const Text('QR Instant Pairing', style: TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: AppColors.cyanAccent, size: 16),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        const Spacer(),
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: MonoStyles.value),
      ],
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