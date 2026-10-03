// Widget test TransferProgressCard: progress, speed/ETA, Retry & tap callback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tacit_pulse_ai/features/p2p/widgets/transfer_progress_card.dart';
import 'package:tacit_pulse_ai/features/p2p/models/transfer_status.dart';

void main() {
  Widget wrap(TransferStatusController c,
      {void Function()? onRetry, void Function()? onCancel}) {
    return MaterialApp(
      home: Scaffold(
        body: TransferProgressCard(
          controller: c,
          onRetry: onRetry,
          onCancel: onCancel,
        ),
      ),
    );
  }

  group('TransferProgressCard', () {
    testWidgets('progress bar mengikuti perubahan persentase', (tester) async {
      final c = TransferStatusController(TransferStatus(
        fileName: 'sop_knowledge_delta.json',
        receivedBytes: 0,
        totalBytes: 100 << 20,
        state: TransferState.transferring,
      ));
      await tester.pumpWidget(wrap(c));
      var bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('transfer_progress_bar')));
      expect(bar.value, 0.0);

      c.value = c.value.copyWith(receivedBytes: 75 << 20);
      await tester.pump();
      bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('transfer_progress_bar')));
      expect(bar.value, closeTo(0.75, 1e-9));
      expect(find.text('75.0%'), findsOneWidget);
    });

    testWidgets('format speed MB/s & ETA mm:ss', (tester) async {
      final c = TransferStatusController(TransferStatus(
        fileName: 'qwen2.5-0.5b-instruct.gguf',
        receivedBytes: 50 << 20,
        totalBytes: 100 << 20,
        speedBytesPerSec: 5 * 1024 * 1024,
        state: TransferState.transferring,
      ));
      await tester.pumpWidget(wrap(c));
      expect(find.text('5.0 MB/s'), findsOneWidget);
      expect(find.text('ETA 00:10'), findsOneWidget);
      expect(find.text('50.0 MB / 100.0 MB'), findsOneWidget);
    });

    testWidgets('mode KB/s untuk kecepatan kecil', (tester) async {
      final c = TransferStatusController(TransferStatus(
        fileName: 's.json',
        receivedBytes: 100 * 1024,
        totalBytes: 200 * 1024,
        speedBytesPerSec: 64 * 1024,
        state: TransferState.transferring,
      ));
      await tester.pumpWidget(wrap(c));
      expect(find.text('64 KB/s'), findsOneWidget);
    });

    testWidgets('status failed menampilkan tombol Retry & Callback',
        (tester) async {
      var retried = false;
      final c = TransferStatusController(const TransferStatus(
        fileName: 'qwen2.5-0.5b-instruct.gguf',
        receivedBytes: 10 << 20,
        totalBytes: 100 << 20,
        state: TransferState.failed,
      ));
      await tester.pumpWidget(wrap(c, onRetry: () => retried = true));
      expect(find.text('Failed'), findsOneWidget);
      expect(find.byKey(const Key('retry_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('retry_button')));
      await tester.pump();
      expect(retried, isTrue);
    });

    testWidgets('Pause/Resume beralih tombol & label; Retry hidden saat transfer',
        (tester) async {
      final c = TransferStatusController(TransferStatus(
        fileName: 's.gguf',
        receivedBytes: 10 << 20,
        totalBytes: 100 << 20,
        speedBytesPerSec: 1024 * 1024,
        state: TransferState.transferring,
      ));
      await tester.pumpWidget(wrap(c));
      expect(find.byKey(const Key('retry_button')), findsNothing);
      await tester.tap(find.byKey(const Key('pause_toggle')));
      await tester.pump();
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pause_toggle')));
      await tester.pump();
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Transferring'), findsOneWidget);
    });
  });
}