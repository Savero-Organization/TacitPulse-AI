import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/mesh_node.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/widgets.dart';
import '../cubit/mesh_cubit.dart';

/// Segmented toggle mode perangkat: Full Node vs Light Client.
class RoleConfig extends StatelessWidget {
  const RoleConfig({super.key, required this.state});

  final MeshMonitorState state;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: true, icon: Icon(Icons.hub_rounded, size: 14), label: Text('Full Node')),
        ButtonSegment(value: false, icon: Icon(Icons.phone_android_rounded, size: 14), label: Text('Light Client')),
      ],
      selected: {state.isLocalFullNode},
      showSelectedIcon: false,
      onSelectionChanged: (s) => context.read<MeshMonitorCubit>().setNodeRole(isFullNode: s.first),
    );
  }
}

/// Kartu kuota storage lokal dengan progress bar horizontal dinamis.
class StorageQuota extends StatelessWidget {
  const StorageQuota({super.key, required this.storage});

  final LocalStorageStatus storage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.slateMuted.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.storage_rounded, color: AppColors.cyanAccent, size: 14),
          const SizedBox(width: 8),
          const Text(
            'STORAGE',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: storage.usageFraction,
                minHeight: 6,
                backgroundColor: AppColors.slateMuted,
                valueColor: const AlwaysStoppedAnimation(AppColors.industrialAmber),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${storage.usedGb.toStringAsFixed(1)} / ${storage.totalGb.toStringAsFixed(0)} GB',
            style: MonoStyles.small,
          ),
        ],
      ),
    );
  }
}

/// Chip traffic compact untuk top bar desktop.
class TrafficChips extends StatelessWidget {
  const TrafficChips({super.key, required this.up, required this.down});

  final double up;
  final double down;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.slateMuted.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('↑ ${up.toStringAsFixed(1)} MB/s', style: const TextStyle(color: AppColors.success, fontSize: 11, fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Text('↓ ${down.toStringAsFixed(1)} MB/s', style: const TextStyle(color: AppColors.industrialAmber, fontSize: 11, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

/// Kartu traffic full-width untuk layar mobile.
class LiveTrafficCard extends StatelessWidget {
  const LiveTrafficCard({super.key, required this.up, required this.down});

  final double up;
  final double down;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.slateMuted.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.upload_rounded, color: AppColors.success, size: 18),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('UNGGAH (UP)', style: TextStyle(color: AppColors.textMuted, fontSize: 9, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('${up.toStringAsFixed(1)} MB/s', style: const TextStyle(color: AppColors.success, fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ),
              ],
            ),
          ),
          Container(width: 1, height: 32, color: AppColors.surfaceBorder),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.industrialAmber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.download_rounded, color: AppColors.industrialAmber, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('UNDUH (DOWN)', style: TextStyle(color: AppColors.textMuted, fontSize: 9, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('${down.toStringAsFixed(1)} MB/s', style: const TextStyle(color: AppColors.industrialAmber, fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}