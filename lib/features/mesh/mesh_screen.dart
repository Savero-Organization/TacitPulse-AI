import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/mesh_node.dart';
import '../../core/models/worker_profile.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/widgets.dart';
import 'cubit/mesh_cubit.dart';
import 'widgets/airdrop_radar.dart';
import 'widgets/qr_pair_sheet.dart';

/// AirDrop & Local Sharing Hub — menggantikan tampilan mesh dev-centric.
/// Cubit disediakan di level [AppShell] agar profil bisa di-reload
/// dari halaman lain (Profile AppBar Action).
class MeshScreen extends StatelessWidget {
  const MeshScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _MeshView();
  }
}

class _MeshView extends StatelessWidget {
  const _MeshView();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MeshMonitorCubit, MeshMonitorState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('AirDrop & Sync Terdekat'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: BlocBuilder<MeshMonitorCubit, MeshMonitorState>(
                  buildWhen: (p, n) => p.isLocalFullNode != n.isLocalFullNode,
                  builder: (context, state) => BadgeChip(
                    label: state.isLocalFullNode ? 'FULL NODE' : 'LIGHT NODE',
                    color: AppColors.industrialAmber,
                    light: AppColors.industrialAmber,
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _openQrPair(context, state),
            backgroundColor: AppColors.cyanAccent,
            foregroundColor: AppColors.slateDark,
            tooltip: 'QR Instant Pairing',
            child: const Icon(Icons.qr_code_scanner_rounded),
          ),
          body: RefreshIndicator(
            onRefresh: () async => context.read<MeshMonitorCubit>().reloadProfile(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                _WorkerBadge(profile: state.profile),
                const SizedBox(height: 16),
                const SectionHeader(title: 'Radar Rekan & Stasiun Terdekat'),
                _radarCard(context, state),
                const SizedBox(height: 12),
                _quickActions(state: state, context: context),
                const SizedBox(height: 18),
                const SectionHeader(title: 'Teknisi di Sekitar'),
                _nearbyList(context, state),
                const SizedBox(height: 18),
                const SectionHeader(title: 'Penyimpanan Lokal & Cache GGUF'),
                _storageCard(state),
                const SizedBox(height: 80),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openQrPair(BuildContext context, MeshMonitorState state) {
    final nodeName = state.profile?.nodeName ?? state.localDeviceId;
    final payload = 'TPAIR://${state.localDeviceId}|${state.profile?.workArea ?? 'UNKNOWN'}';
    QrPairSheet.show(context, nodeName: nodeName, qrPayload: payload);
  }

  Widget _radarCard(BuildContext context, MeshMonitorState state) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 4),
            child: Text('Radius Wi-Fi / hotspot P2P · ketuk blip untuk kirim',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          ),
          AirdropRadar(
            nodes: state.nodes,
            onNodeTap: (node) => _onNodeTap(context, state, node),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _legend(AppColors.success, 'Terhubung'),
              const SizedBox(width: 12),
              _legend(AppColors.industrialAmber, 'Sync'),
              const SizedBox(width: 12),
              _legend(AppColors.textMuted, 'Lepas'),
              const Spacer(),
              const PulseDot(color: AppColors.success),
            ],
          ),
        ],
      ),
    );
  }

  void _onNodeTap(BuildContext context, MeshMonitorState state, MeshNode node) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _NodeActionSheet(node: node),
    );
  }

  Widget _quickActions(
      {required MeshMonitorState state, required BuildContext context}) {
    return Row(
      children: [
        Expanded(
          child: _QuickActionTile(
            icon: Icons.upload_file_rounded,
            title: 'Kirim SOP / File',
            subtitle: 'Transfer P2P langsung',
            color: AppColors.cyanAccent,
            onTap: () => _snack(context,
                'Pilih file PDF / voice note dari HP untuk dikirim langsung'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionTile(
            icon: Icons.download_for_offline_rounded,
            title: 'Tarik Cache SOP',
            subtitle: 'Ambil dokumen RAG rekan',
            color: AppColors.industrialAmber,
            onTap: () => _snack(context,
                'Meminta dokumen RAG dari HP kawan terdekat…'),
          ),
        ),
      ],
    );
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  Widget _nearbyList(BuildContext context, MeshMonitorState state) {
    final items = [
      for (final n in state.nodes)
        _NearbyCard(
          node: n,
          isSelf: n.id == 'node-00' || n.id == state.localDeviceId,
          onShare: () {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(
                content: n.id == 'node-00'
                    ? const Text('Pilih file untuk dikirim dari profil Anda')
                    : Text('Mengirim SOP ke ${n.technicianName}… (${n.name})'),
                duration: const Duration(seconds: 2),
              ));
          },
          onPull: () {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(
                content: Text('Meminta cache dokumen RAG dari rekan terdekat…'),
                duration: Duration(seconds: 2),
              ));
          },
        ),
    ];
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          items[i],
          if (i < items.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _storageCard(MeshMonitorState state) {
    final storage = state.storage;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storage_rounded, color: AppColors.cyanAccent, size: 20),
              const SizedBox(width: 8),
              const Expanded(child: Text('Sqlite Knowledge Store', style: MonoStyles.value)),
              Text('${storage.documents} DOC', style: MonoStyles.small),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: storage.usageFraction,
              minHeight: 8,
              backgroundColor: AppColors.slateMuted,
              valueColor: const AlwaysStoppedAnimation(AppColors.industrialAmber),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${storage.usedGb.toStringAsFixed(1)} / ${storage.totalGb.toStringAsFixed(0)} GB dipakai · '
            '${storage.freeGb.toStringAsFixed(1)} GB bebas',
            style: MonoStyles.small,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              PulseDot(color: storage.modelLoaded ? AppColors.success : AppColors.warning),
              const SizedBox(width: 8),
              const Text('Model GGUF', style: MonoStyles.value),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${storage.modelName} · ${storage.modelSizeMb} MB',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MonoStyles.small,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _legend(Color color, String label) {
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

/// Header / Worker Badge: profil teknisi aktif + status koneksi lokal.
class _WorkerBadge extends StatelessWidget {
  const _WorkerBadge({required this.profile});

  final WorkerProfile? profile;

  @override
  Widget build(BuildContext context) {
    final name = profile?.fullName ?? 'Teknisi';
    final area = profile?.workArea ?? 'Belum di-setup';
    final shift = profile?.shift ?? '—';
    final node = profile?.nodeName ?? 'TEK-LOKAL-01';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.deepCharcoal, AppColors.slateDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.industrialAmber.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.industrialAmber),
                ),
                child: Center(
                  child: Text(
                    name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: AppColors.industrialAmber, fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: MonoStyles.value.copyWith(fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(area, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 1),
                    Text('$shift · $node', style: MonoStyles.small),
                  ],
                ),
              ),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  PulseDot(color: AppColors.success),
                  SizedBox(height: 6),
                  Text('LOKAL', style: TextStyle(color: AppColors.success, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.slateMuted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              children: [
                Icon(Icons.wifi_rounded, color: AppColors.success, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Terhubung ke hotspot lokal · sinkron offline-first aktif',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kartu node teknisi di sekitar (AirDrop-style).
class _NearbyCard extends StatelessWidget {
  const _NearbyCard({
    required this.node,
    required this.isSelf,
    required this.onShare,
    required this.onPull,
  });

  final MeshNode node;
  final bool isSelf;
  final VoidCallback onShare;
  final VoidCallback onPull;

  Color get _statusColor => switch (node.status) {
        NodeStatus.online => AppColors.success,
        NodeStatus.syncing => AppColors.industrialAmber,
        NodeStatus.offline => AppColors.textMuted,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSelf ? AppColors.slateMuted.withValues(alpha: 0.25) : AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelf ? AppColors.industrialAmber.withValues(alpha: 0.6) : AppColors.surfaceBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    node.technicianName.isEmpty ? '?' : node.technicianName.substring(0, 1).toUpperCase(),
                    style: TextStyle(color: _statusColor, fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            node.technicianName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (isSelf) ...[
                          const SizedBox(width: 6),
                          const BadgeChip(label: 'SELF', color: AppColors.industrialAmber, light: AppColors.industrialAmber),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('${node.line} · ${node.name}', style: MonoStyles.small),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.battery_std_rounded,
                          color: node.battery < 20 ? AppColors.danger : AppColors.textSecondary, size: 15),
                      const SizedBox(width: 2),
                      Text('${node.battery}%', style: MonoStyles.small),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Icon(Icons.signal_wifi_4_bar_rounded, color: _signalColor, size: 15),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.slateDark,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.description_outlined, color: AppColors.cyanAccent, size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    node.recentSop,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isSelf ? null : onShare,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.cyanAccent,
                    side: BorderSide(color: AppColors.cyanAccent.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  icon: const Icon(Icons.upload_file_rounded, size: 16),
                  label: const Text('Kirim SOP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isSelf ? null : onPull,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.industrialAmber,
                    side: BorderSide(color: AppColors.industrialAmber.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  icon: const Icon(Icons.download_for_offline_rounded, size: 16),
                  label: const Text('Tarik Cache', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color get _signalColor => node.signal >= 3
      ? AppColors.success
      : node.signal == 2
          ? AppColors.warning
          : AppColors.textMuted;
}

/// Bottom sheet saat blip radar diketuk.
class _NodeActionSheet extends StatelessWidget {
  const _NodeActionSheet({required this.node});

  final MeshNode node;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.cyanAccent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    node.technicianName.isEmpty ? '?' : node.technicianName.substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: AppColors.cyanAccent, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(node.technicianName,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
                    Text('${node.line} · ${node.status.label}', style: MonoStyles.small),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('SOP terbaru yang disimpan:', style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          const SizedBox(height: 4),
          Text(node.recentSop, style: MonoStyles.value),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.cyanAccent,
                    foregroundColor: AppColors.slateDark,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Kirim SOP / File', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.industrialAmber,
                    side: BorderSide(color: AppColors.industrialAmber.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  icon: const Icon(Icons.download_for_offline_rounded, size: 18),
                  label: const Text('Tarik Cache Model / SOP', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tile aksi cepat (kirim / tarik) di atas daftar teknisi.
class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.deepCharcoal,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}