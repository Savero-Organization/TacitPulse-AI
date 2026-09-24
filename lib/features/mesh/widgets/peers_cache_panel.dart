import 'package:flutter/material.dart';

import '../../../core/models/mesh_node.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/widgets.dart';
import '../cubit/mesh_cubit.dart';

/// Item cache pengetahuan lokal yang dibagikan ke mesh.
class CacheItem {
  const CacheItem(
    this.name,
    this.type,
    this.size,
    this.icon, {
    this.requiresLocalFile = false,
  });

  final String name;
  final String type;
  final String size;
  final IconData icon;

  /// True bila item HANYA boleh di-share bila file terkait benar-benar ada
  /// di device (mis. file model GGUF lokal). Switch dikunci-off bila node
  /// tidak memegang file tersebut.
  final bool requiresLocalFile;
}

const List<CacheItem> cacheItems = [
  CacheItem('SOP PM-KOM-014', 'SOP', '1.2 MB', Icons.description_rounded),
  CacheItem('Log Anomali Line 2', 'LOG', '240 KB', Icons.text_snippet_rounded),
  CacheItem(
    'qwen3.5-0.8b.q4_k_m.gguf',
    'MODEL',
    '620 MB',
    Icons.memory_rounded,
    requiresLocalFile: true,
  ),
];

/// Panel sidebar desktop: daftar peers aktif + cache pengetahuan yang dibagikan.
class PeersSharedCachesPanel extends StatelessWidget {
  const PeersSharedCachesPanel({
    super.key,
    required this.state,
    required this.sharedCaches,
    required this.onCacheToggle,
    required this.onPeerTap,
  });

  final MeshMonitorState state;
  final Map<String, bool> sharedCaches;
  final ValueChanged<String> onCacheToggle;
  final ValueChanged<MeshNode> onPeerTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: AppColors.deepCharcoal,
        border: Border(right: BorderSide(color: AppColors.surfaceBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                Icon(Icons.hub_rounded, color: AppColors.industrialAmber, size: 20),
                SizedBox(width: 10),
                Text('Peers & Shared Caches', style: TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const Divider(height: 20, color: AppColors.surfaceBorder),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
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
                const SizedBox(height: 18),
                const SectionHeader(title: 'Knowledge Caches'),
                for (final item in cacheItems)
                  CacheRow(
                    item: item,
                    shared: item.requiresLocalFile
                        ? state.modelHosted &&
                            (sharedCaches[item.name] ?? true)
                        : (sharedCaches[item.name] ?? true),
                    enabled:
                        !item.requiresLocalFile || state.modelHosted,
                    onToggle: () => onCacheToggle(item.name),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tile satu peer dengan badge role + info line.
class PeerTile extends StatelessWidget {
  const PeerTile({
    super.key,
    required this.node,
    required this.isSelf,
    this.displayName,
    required this.onTap,
  });

  final MeshNode node;
  final bool isSelf;
  final String? displayName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = displayName ?? node.technicianName;
    final badgeColor = node.role == NodeRole.full ? AppColors.industrialAmber : AppColors.cyanAccent;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.slateMuted.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.surfaceBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
                      Text('${node.line} · ${node.name}', style: MonoStyles.small),
                    ],
                  ),
                ),
                BadgeChip(
                  label: node.role == NodeRole.full ? 'FULL NODE' : 'EDGE NODE',
                  color: badgeColor,
                  light: badgeColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Baris satu cache dengan switch pembagian.
class CacheRow extends StatelessWidget {
  const CacheRow({
    super.key,
    required this.item,
    required this.shared,
    required this.enabled,
    required this.onToggle,
  });

  final CacheItem item;
  final bool shared;

  /// False → item tidak boleh dibagikan (mis. file model belum ada di
  /// device): switch diberi mati (off & non-interaktif) + label unhosted.
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final unhosted = item.requiresLocalFile && !enabled;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.slateMuted.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Icon(
            item.icon,
            color: unhosted ? AppColors.textMuted : AppColors.cyanAccent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: TextStyle(
                    color: unhosted
                        ? AppColors.textMuted
                        : AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (unhosted)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'unhosted — pilih model GGUF lokal dulu',
                      style:
                          TextStyle(color: AppColors.warning, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: unhosted ? false : shared,
            onChanged: unhosted ? null : (_) => onToggle(),
            activeThumbColor: AppColors.industrialAmber,
          ),
        ],
      ),
    );
  }
}