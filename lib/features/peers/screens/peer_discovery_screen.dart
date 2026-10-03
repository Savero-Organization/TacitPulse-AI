// peer_discovery_screen.dart — layar penemuan peer LAN realtime.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_colors.dart';
import '../cubit/peer_discovery_cubit.dart';
import '../widgets/peer_tile.dart';

class PeerDiscoveryScreen extends StatelessWidget {
  const PeerDiscoveryScreen({
    super.key,
    required this.localDeviceName,
    required this.localPort,
    this.txtRecords,
  });

  final String localDeviceName;
  final int localPort;
  final Map<String, String>? txtRecords;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PeerDiscoveryCubit, PeerDiscoveryState>(
      builder: (context, state) {
        final scanning = state is PeerDiscoveryScanning;
        return Scaffold(
          backgroundColor: AppColors.slateDark,
          appBar: AppBar(
            title: const Text('Peers di LAN'),
            backgroundColor: AppColors.deepCharcoal,
          ),
          body: RefreshIndicator(
            onRefresh: () => context.read<PeerDiscoveryCubit>().refresh(
                  deviceName: localDeviceName,
                  port: localPort,
                  txtRecords: txtRecords,
                ),
            child: ListView(
              key: const Key('peer_discovery_list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  key: const Key('peer_local_header'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.deepCharcoal,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.broadcast_on_personal,
                        color: scanning
                            ? AppColors.success
                            : AppColors.textMuted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Perangkat ini: $localDeviceName · port $localPort\n'
                          'Status: ${scanning ? 'Broadcasting + scanning' : 'idle'}',
                          key: const Key('peer_local_info'),
                          style: const TextStyle(
                              color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (scanning) ...[
                  const Center(
                    key: Key('peer_scanning_indicator'),
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Center(
                    key: Key('peer_empty_state'),
                    child: Text(
                      'Searching for nearby Tacit Pulse devices...',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                ] else if (state is PeerDiscoveryActivePeers) ...[
                  for (final p in state.peers) PeerTile(peer: p),
                ] else if (state is PeerDiscoveryError)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Error: ${state.message}',
                      key: const Key('peer_error'),
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  )
                else
                  const Center(
                    child: Text(
                      'Belum ada scanning aktif.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
