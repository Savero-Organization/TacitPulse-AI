// Repro + regression: waveform paint TypeError di jendela lebar,
// tombol Stop Rekam, dan provider CaptureCubit untuk SopDraftSheet.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tacit_pulse_ai/features/capture/capture_screen.dart';
import 'package:tacit_pulse_ai/features/capture/widgets/waveform_visualizer.dart';

void main() {
  Future<void> pumpWaveform(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 96,
              child: WaveformVisualizer(
                samples: List<double>.filled(64, 0.5),
                color: Colors.cyanAccent,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('WaveformVisualizer', () {
    testWidgets('paint di panel lebar tidak melempar TypeError', (tester) async {
      await pumpWaveform(tester, 1117);
      expect(tester.takeException(), isNull);
    });

    testWidgets('paint di preview sempit (48px) tidak melempar error', (tester) async {
      await pumpWaveform(tester, 48);
      expect(tester.takeException(), isNull);
    });
  });

  group('CaptureScreen — alur rekaman', () {
    testWidgets('tombol Stop menghentikan rekaman tanpa exception paint', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CaptureScreen()));

      await tester.tap(find.text('Rekam Voice Note'));
      await tester.pump();
      expect(find.text('Stop Rekam'), findsOneWidget);

      // Biarkan beberapa siklus timer waveform berjalan (120ms).
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Stop Rekam'));
      await tester.pump();
      expect(find.text('TRANSCRIBING'), findsOneWidget);

      // Future transkripsi 2 detik -> status drafting.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Lihat Draft SOP'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Lepas widget tree agar timer cubit dibatalkan sebelum test selesai.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('SopDraftSheet menemukan CaptureCubit (tanpa ProviderNotFound)', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CaptureScreen()));

      await tester.tap(find.text('Rekam Voice Note'));
      await tester.pump();
      await tester.tap(find.text('Stop Rekam'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Lihat Draft SOP'), findsOneWidget);

      await tester.tap(find.text('Lihat Draft SOP'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Draft SOP dari Voice Note'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}
