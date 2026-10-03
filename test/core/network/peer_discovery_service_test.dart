import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tacit_pulse_ai/features/peers/cubit/peer_discovery_cubit.dart';
import 'package:tacit_pulse_ai/core/network/peer_discovery_service.dart';

class FakePeerDiscoveryService implements PeerDiscoveryService {
  final StreamController<List<DiscoveredPeer>> _controller =
      StreamController<List<DiscoveredPeer>>.broadcast();
  bool broadcasting = false;
  bool discovering = false;
  String? lastDeviceName;
  int? lastPort;

  @override
  Future<void> startBroadcasting({
    required String deviceName,
    required int port,
    Map<String, String>? txtRecords,
  }) async {
    broadcasting = true;
    lastDeviceName = deviceName;
    lastPort = port;
  }

  @override
  Future<void> stopBroadcasting() async => broadcasting = false;

  @override
  Future<void> startDiscovery() async => discovering = true;

  @override
  Future<void> stopDiscovery() async => discovering = false;

  @override
  Stream<List<DiscoveredPeer>> get discoveredPeersStream => _controller.stream;

  void emitPeers(List<DiscoveredPeer> peers) => _controller.add(peers);

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

DiscoveredPeer _peer(String id) => DiscoveredPeer(
      id: id,
      name: 'Device-$id',
      host: '$id.local',
      addresses: const ['192.168.1.10'],
      port: 8080,
      txtRecords: const {'deviceId': 'x', 'deviceName': 'D'},
      lastSeen: DateTime(2026),
    );

void main() {
  group('DiscoveredPeer', () {
    test('equality mengabaikan lastSeen', () {
      final a = _peer('1');
      final b = a.copyWith(lastSeen: DateTime(2027));
      expect(a == b, isTrue);
    });

    test('toJson/fromJson round-trip', () {
      final a = _peer('p1');
      final b = DiscoveredPeer.fromJson(a.toJson());
      expect(b.id, 'p1');
      expect(b.port, 8080);
      expect(b.txtRecords['deviceName'], 'D');
    });

    test('round-trip TXT record UTF-8 (karakter selain ASCII)', () {
      final encoded = Uint8List.fromList(utf8.encode('André-日本'));
      final out = DiscoveredPeer.decodeTxt({'deviceName': encoded});
      expect(out['deviceName'], 'André-日本');
    });

    test('decodeTxt parsing Uint8List → String', () {
      final out = DiscoveredPeer.decodeTxt({
        'deviceId': Uint8List.fromList('abc'.codeUnits),
        'deviceName': null,
      });
      expect(out['deviceId'], 'abc');
      expect(out['deviceName'], '');
    });
  });

  group('PeerDiscoveryCubit', () {
    late FakePeerDiscoveryService service;
    late PeerDiscoveryCubit cubit;

    setUp(() {
      service = FakePeerDiscoveryService();
      cubit = PeerDiscoveryCubit(service);
    });

    tearDown(() => cubit.close());

    test('start memancarkan Scanning lalu ActivePeers saat peer datang',
        () async {
      final states = <PeerDiscoveryState>[];
      final sub = cubit.stream.listen(states.add);
      await cubit.start(deviceName: 'dev', port: 8080);
      expect(states.last, isA<PeerDiscoveryScanning>());
      service.emitPeers([_peer('1')]);
      await Future<void>.delayed(Duration.zero);
      expect(states.last, isA<PeerDiscoveryActivePeers>());
      expect(
          (states.last as PeerDiscoveryActivePeers).peers.single.id, '1');
      await sub.cancel();
    });

    test('peer hilang kembali ke state Scanning (timeout)', () async {
      final states = <PeerDiscoveryState>[];
      final sub = cubit.stream.listen(states.add);
      await cubit.start(deviceName: 'dev', port: 8080);
      service.emitPeers([_peer('1')]);
      await Future<void>.delayed(Duration.zero);
      service.emitPeers(const []);
      await Future<void>.delayed(Duration.zero);
      expect(states.last, isA<PeerDiscoveryScanning>());
      await sub.cancel();
    });

    test('stop menghentikan broadcasting + kembali ke Initial', () async {
      await cubit.start(deviceName: 'dev', port: 8080);
      await cubit.stop();
      expect(service.broadcasting, isFalse);
      expect(service.discovering, isFalse);
      expect(cubit.state, isA<PeerDiscoveryInitial>());
    });
  });
}
