// nearby_peers_screen.dart — layar daftar peer LAN dengan radar scan.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/models/discovered_peer.dart';
import '../../peers/cubit/peer_discovery_cubit.dart';
import '../widgets/radar_scan_widget.dart';

/// Layar daftar peer di sekitar dengan animasi radar. Dipasang dengan
/// `BlocProvider<PeerDiscoveryCubit>`.
class NearbyPeersScreen extends StatelessWidget {
  const NearbyPeersScreen({
    super.key,
    required this.localDeviceName,
    required this.localPort,
    this.txtRecords,
    this.onPeerConnect,
  });

  final String localDeviceName;
  final int localPort;
  final Map<String, String>? txtRecords;

  /// Dipanggil saat tombol Connect/Pair pada sebuah peer ditekan.
  final void Function(DiscoveredPeer peer)? onPeerConnect;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PeerDiscoveryCubit, PeerDiscoveryState>(
      builder: (context, state) {
        // Anggap sedang scan bila tidak berhenti/error: radar terus berputar
        // selagi discovery aktif, termasuk saat daftar peer sudah terisi.
        final scanning = state is PeerDiscoveryScanning ||
            state is PeerDiscoveryActivePeers;
        final peers = state is PeerDiscoveryActivePeers
            ? state.peers
            : const <DiscoveredPeer>[];
        return Scaffold(
          appBar: AppBar(title: const Text('Nearby Devices')),
          body: Column(
            children: [
              Center(
                child: RadarScanWidget(scanning: scanning, size: 180),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: FilledButton.tonalIcon(
                  key: const Key('scan_toggle'),
                  onPressed: () {
                    final cubit = context.read<PeerDiscoveryCubit>();
                    if (scanning) {
                      cubit.stop();
                    } else {
                      cubit.start(
                        deviceName: localDeviceName,
                        port: localPort,
                        txtRecords: txtRecords,
                      );
                    }
                  },
                  icon: Icon(scanning ? Icons.stop : Icons.radar),
                  label: Text(scanning ? 'Stop Scan' : 'Start Scan'),
                ),
              ),
              if (state is PeerDiscoveryError)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(state.message,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                )
              else if (peers.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (scanning)
                          const SizedBox(
                            key: Key('peer_scanning_indicator'),
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        const SizedBox(height: 12),
                        Text(scanning
                            ? 'Scanning for nearby devices...'
                            : 'No devices found. Start the scan.'),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.separated(
                    key: const Key('nearby_peers_list'),
                    itemCount: peers.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final peer = peers[i];
                      return ListTile(
                        key: Key('peer_${peer.id}'),
                        leading: Icon(
                          Icons.wifi,
                          key: Key('signal_${peer.id}'),
                          color: Colors.green,
                        ),
                        title: Text(peer.name),
                        subtitle: Text('${peer.primaryAddress}:${peer.port}'),
                        trailing: FilledButton(
                          key: Key('connect_${peer.id}'),
                          onPressed: () => onPeerConnect?.call(peer),
                          child: const Text('Connect'),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}