// Widget test PairingPinModal: input 4 digit, validasi, reject, timeout.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tacit_pulse_ai/features/p2p/widgets/pairing_pin_modal.dart';

Widget _host({
  required WidgetBuilder builder,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) {
        Future<void>.microtask(
          () => showDialog<void>(context: context, builder: builder),
        );
        return const Scaffold(body: SizedBox.shrink());
      },
    ),
  );
}

void main() {
  group('PairingPinModal', () {
    testWidgets('input 4 digit trigger validasi → onApprove saat PIN cocok',
        (tester) async {
      var approved = false;
      await tester.pumpWidget(_host(
        builder: (_) => PairingPinModal(
          peerName: 'RAFT-01',
          expectedPin: '1234',
          mode: PairingPinMode.entry,
          onApprove: () => approved = true,
        ),
      ));
      await tester.pump();

      await tester.enterText(find.byKey(const Key('pin_digit_0')), '1');
      await tester.enterText(find.byKey(const Key('pin_digit_1')), '2');
      await tester.enterText(find.byKey(const Key('pin_digit_2')), '3');
      await tester.enterText(find.byKey(const Key('pin_digit_3')), '4');
      await tester.tap(find.byKey(const Key('pin_approve')));
      await tester.pump();
      expect(approved, isTrue);
      expect(find.byKey(const Key('pin_error')), findsNothing);
    });

    testWidgets('PIN salah menampilkan error & tidak memanggil onApprove',
        (tester) async {
      var approved = false;
      await tester.pumpWidget(_host(
        builder: (_) => PairingPinModal(
          peerName: 'RAFT-01',
          expectedPin: '9999',
          onApprove: () => approved = true,
        ),
      ));
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.enterText(find.byKey(Key('pin_digit_$i')), '0');
      }
      await tester.tap(find.byKey(const Key('pin_approve')));
      await tester.pump();
      expect(approved, isFalse);
      expect(find.text('PIN salah, coba lagi'), findsOneWidget);
    });

    testWidgets('Tombol Reject memicu onReject', (tester) async {
      var rejected = false;
      await tester.pumpWidget(_host(
        builder: (_) => PairingPinModal(
          peerName: 'RAFT-01',
          expectedPin: '1234',
          onReject: () => rejected = true,
        ),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pin_reject')));
      await tester.pump();
      expect(rejected, isTrue);
    });

    testWidgets('countdown habis → onTimeout + error', (tester) async {
      var timedOut = false;
      await tester.pumpWidget(_host(
        builder: (_) => PairingPinModal(
          peerName: 'RAFT-01',
          expectedPin: '1234',
          timeoutSeconds: 1,
          onTimeout: () => timedOut = true,
        ),
      ));
      await tester.pump(); // tampilkan dialog
      // Ticker menghitung mundur mengikuti clock binding → dorong 2 detik.
      await tester.pump(const Duration(seconds: 2));
      expect(timedOut, isTrue);
      expect(find.text('Waktu habis'), findsOneWidget);
    });

    testWidgets('mode generate menampilkan PIN dan tombol Selesai memanggil onApprove',
        (tester) async {
      var approved = false;
      await tester.pumpWidget(_host(
        builder: (_) => PairingPinModal(
          peerName: 'RAFT-01',
          expectedPin: '6789',
          mode: PairingPinMode.generate,
          onApprove: () => approved = true,
        ),
      ));
      await tester.pump();
      expect(find.byKey(const Key('generated_pin_display')), findsOneWidget);
      expect(find.text('6789'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pin_approve')));
      await tester.pump();
      expect(approved, isTrue);
    });
  });
}