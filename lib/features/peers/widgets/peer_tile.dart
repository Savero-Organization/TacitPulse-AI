// peer_tile.dart — satu baris peer yang ditemukan.

import 'package:flutter/material.dart';

import '../../../core/network/peer_discovery_service.dart';
import '../../../core/theme/app_colors.dart';

class PeerTile extends StatelessWidget {
  const PeerTile({super.key, required this.peer});

  final DiscoveredPeer peer;

  String _lastSeen() {
    final diff = DateTime.now().difference(peer.lastSeen);
    if (diff.inSeconds < 5) return 'baru saja';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s lalu';
    return '${diff.inMinutes}m lalu';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('peer_tile_${peer.id}'),
      leading: const CircleAvatar(
        backgroundColor: AppColors.cyanAccent,
        child: Icon(Icons.devices, color: AppColors.deepCharcoal),
      ),
      title: Text(
        peer.name,
        style: const TextStyle(color: AppColors.textPrimary),
      ),
      subtitle: Text(
        '${peer.primaryAddress}:${peer.port}',
        style: const TextStyle(color: AppColors.textSecondary),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Icon(Icons.sensors, size: 16, color: AppColors.success),
          Text(
            _lastSeen(),
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
