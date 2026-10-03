// mdns_peer_discovery_service.dart — implementasi mDNS via package:nsd.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import 'peer_discovery_service.dart';

/// Layanan discovery peer menggunakan mDNS/DNS-SD (`_tacitpulse._tcp`).
class MdnsPeerDiscoveryService implements PeerDiscoveryService {
  MdnsPeerDiscoveryService();

  static const String serviceType = '_tacitpulse._tcp';

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  final StreamController<List<DiscoveredPeer>> _controller =
      StreamController<List<DiscoveredPeer>>.broadcast();
  List<DiscoveredPeer> _current = const [];

  @override
  Stream<List<DiscoveredPeer>> get discoveredPeersStream => _controller.stream;

  @override
  Future<void> startBroadcasting({
    required String deviceName,
    required int port,
    Map<String, String>? txtRecords,
  }) async {
    await stopBroadcasting();
    final txt = <String, Uint8List?>{};
    for (final e in (txtRecords ?? const <String, String>{}).entries) {
      // UTF-8, bukan code-units UTF-16 — selaras dengan decode UTF-8 di
      // DiscoveredPeer.decodeTxt; sebaliknya karakter di luar ASCII rusak.
      txt[e.key] = Uint8List.fromList(utf8.encode(e.value));
    }
    _registration = await nsd.register(
      nsd.Service(
        name: deviceName,
        type: serviceType,
        port: port,
        txt: txt,
      ),
    );
  }

  @override
  Future<void> stopBroadcasting() async {
    final reg = _registration;
    _registration = null;
    if (reg != null) {
      await nsd.unregister(reg);
    }
  }

  @override
  Future<void> startDiscovery() async {
    await stopDiscovery();
    _current = const [];
    _controller.add(_current);
    _discovery = await nsd.startDiscovery(serviceType, autoResolve: true);
    _discovery!.addListener(_onServicesChanged);
  }

  @override
  Future<void> stopDiscovery() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      d.removeListener(_onServicesChanged);
      await nsd.stopDiscovery(d);
    }
  }

  void _onServicesChanged() {
    final services = _discovery?.services ?? const [];
    final now = DateTime.now();
    final peers = services.map((s) {
      final txt = DiscoveredPeer.decodeTxt(s.txt);
      return DiscoveredPeer(
        id: txt['deviceId'] ?? s.name ?? '',
        name: txt['deviceName'] ?? s.name ?? '',
        host: s.host ?? '',
        addresses: s.addresses?.map((a) => a.address).toList() ?? const [],
        port: s.port ?? 0,
        txtRecords: txt,
        lastSeen: now,
      );
    }).toList(growable: false);
    final changed = peers.length != _current.length ||
        peers.any((p) => !_current.any((c) => c.id == p.id)) ||
        _current.any((c) => !peers.any((p) => p.id == c.id));
    _current = peers;
    if (changed) {
      _controller.add(_current);
    }
  }

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await stopBroadcasting();
    await _controller.close();
  }
}
