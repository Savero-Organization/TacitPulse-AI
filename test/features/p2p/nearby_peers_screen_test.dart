// Widget test NearbyPeersScreen: radar saat scanning + render peer + tombol Connect.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tacit_pulse_ai/core/network/models/discovered_peer.dart';
import 'package:tacit_pulse_ai/features/p2p/screens/nearby_peers_screen.dart';
import 'package:tacit_pulse_ai/features/p2p/widgets/radar_scan_widget.dart';
import 'package:tacit_pulse_ai/features/peers/cubit/peer_discovery_cubit.dart';

import '../../core/network/peer_discovery_service_test.dart';

void main() {
  Widget wrap(PeerDiscoveryCubit cubit, {void Function(dynamic)? onConnect}) =>
      MaterialApp(
        home: BlocProvider<PeerDiscoveryCubit>.value(
          value: cubit,
          child: NearbyPeersScreen(
            localDeviceName: 'Tech-01',
            localPort: 8080,
            onPeerConnect: onConnect == null ? null : (p) => onConnect(p),
          ),
        ),
      );

  group('NearbyPeersScreen', () {
    late FakePeerDiscoveryService service;
    late PeerDiscoveryCubit cubit;

    setUp(() {
      service = FakePeerDiscoveryService();
      cubit = PeerDiscoveryCubit(service);
    });
    tearDown(() => cubit.close());

    testWidgets('radar aktif saat scanning', (tester) async {
      await tester.pumpWidget(wrap(cubit));
      expect(find.byType(RadarScanWidget), findsOneWidget);
      await tester.runAsync(
          () => cubit.start(deviceName: 'd', port: 8080));
      await tester.pump();
      expect(find.text('Scanning for nearby devices...'), findsOneWidget);
      final state = tester
          .state(find.byType(RadarScanWidget)) as RadarScanWidgetState;
      expect(state.isAnimating, isTrue);
    });

    testWidgets('menampilkan peer & tombol Connect memanggil callback',
        (tester) async {
      dynamic tapped;
      await tester.pumpWidget(wrap(cubit, onConnect: (p) => tapped = p));
      await tester.runAsync(() => cubit.start(deviceName: 'd', port: 8080));
      await tester.pump();
      service.emitPeers([
        DiscoveredPeer(
          id: 'peer1',
          name: 'Handheld-02',
          host: 'h2.local',
          addresses: const ['192.168.1.22'],
          port: 9000,
          txtRecords: const {},
          lastSeen: DateTime.now(),
        ),
      ]);
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(find.text('Handheld-02'), findsOneWidget);
      expect(find.text('192.168.1.22:9000'), findsOneWidget);
      await tester.tap(find.byKey(const Key('connect_peer1')));
      await tester.pump();
      expect(tapped, isA<DiscoveredPeer>());
      expect((tapped as DiscoveredPeer).id, 'peer1');
    });
  });
}