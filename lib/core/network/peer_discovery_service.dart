// peer_discovery_service.dart — abstraksi penemuan peer via mDNS.
//
// Implementasi produksi: [MdnsPeerDiscoveryService]. Test memakai fake
// sehingga tidak perlu socket/ jaringan nyata.

import 'models/discovered_peer.dart';

export 'models/discovered_peer.dart';

/// Kontrak layanan discovery & broadcast peer.
abstract class PeerDiscoveryService {
  /// Mulai mengumumkan diri di LAN dengan TXT metadata.
  Future<void> startBroadcasting({
    required String deviceName,
    required int port,
    Map<String, String>? txtRecords,
  });

  /// Hentikan pengumuman.
  Future<void> stopBroadcasting();

  /// Mulai mendengarkan peer lain di jaringan.
  Future<void> startDiscovery();

  /// Hentikan pendengaran.
  Future<void> stopDiscovery();

  /// Emit daftar peer yang sedang aktif (terupdate realtime).
  Stream<List<DiscoveredPeer>> get discoveredPeersStream;

  /// Bersihkan semua resource (broadcaster + discovery + stream).
  Future<void> dispose();
}
