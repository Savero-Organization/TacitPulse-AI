
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tacit_pulse_ai/features/peers/cubit/peer_discovery_cubit.dart';
import 'package:tacit_pulse_ai/features/peers/screens/peer_discovery_screen.dart';
import 'package:tacit_pulse_ai/core/network/peer_discovery_service.dart';
import '../../core/network/peer_discovery_service_test.dart';

void main() {
  Widget wrap(PeerDiscoveryCubit cubit) => MaterialApp(
        home: BlocProvider<PeerDiscoveryCubit>.value(
          value: cubit,
          child: const PeerDiscoveryScreen(
            localDeviceName: 'Tech-01',
            localPort: 8080,
          ),
        ),
      );

  group('PeerDiscoveryScreen', () {
    late FakePeerDiscoveryService service;
    late PeerDiscoveryCubit cubit;

    setUp(() {
      service = FakePeerDiscoveryService();
      cubit = PeerDiscoveryCubit(service);
    });

    tearDown(() => cubit.close());

    testWidgets('menampilkan indikator scanning + empty state', (tester) async {
      await tester.pumpWidget(wrap(cubit));
      await tester.runAsync(() => cubit.start(deviceName: 'd', port: 8080));
      await tester.pump();
      expect(find.byKey(const Key('peer_scanning_indicator')), findsOneWidget);
      expect(find.text('Searching for nearby Tacit Pulse devices...'),
          findsOneWidget);
      expect(find.textContaining('Tech-01'), findsOneWidget);
    });

    testWidgets('menampilkan list peer saat ada', (tester) async {
      await tester.pumpWidget(wrap(cubit));
      await tester.runAsync(() => cubit.start(deviceName: 'd', port: 8080));
      await tester.pump();
      service.emitPeers([
        DiscoveredPeer(
          id: '1',
          name: 'Handheld-Tech-02',
          host: 'tech02.local',
          addresses: const ['192.168.1.22'],
          port: 9000,
          txtRecords: const {},
          lastSeen: DateTime.now(),
        ),
      ]);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      expect(find.text('Handheld-Tech-02'), findsOneWidget);
      expect(find.text('192.168.1.22:9000'), findsOneWidget);
    });

    testWidgets('pull-to-refresh memicu restart scanning (RefreshIndicator)',
        (tester) async {
      await tester.pumpWidget(wrap(cubit));
      await tester.runAsync(() => cubit.start(deviceName: 'd', port: 8080));
      await tester.pump();
      // Seret dari atas untuk trigger RefreshIndicator.
      await tester.drag(
          find.byKey(const Key('peer_discovery_list')), const Offset(0, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(service.broadcasting, isTrue);
    });
  });
}
