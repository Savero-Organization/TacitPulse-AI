import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacit_pulse_ai/core/widgets/model_path_picker_sheet.dart';

void main() {
  testWidgets('picker sheet renders folder + fact-check icons & downloader',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => ModelPathPickerSheet.show(ctx),
            child: const Text('open-sheet'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    // Icon folder (kiri) → membuka File Explorer OS.
    expect(find.byTooltip('Buka File Explorer OS'), findsOneWidget);
    // Icon kanan adalah aksi validasi path — bukan lagi search picker.
    expect(find.byTooltip('Validasi Path Teks'), findsOneWidget);
    // In-App Downloader tersedia.
    expect(
      find.textContaining('Unduh Otomatis dari Server'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Klik icon folder untuk memilih file'),
      findsOneWidget,
    );
  });

  testWidgets('tapping left folder icon triggers OS picker without crashing; '
      'fallback manual-entry hint shown in minimal-WM (no portal)',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => ModelPathPickerSheet.show(ctx),
            child: const Text('open-sheet'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    // Ketuk ikon folder kiri. Di lingkungan test / WM tanpa portal,
    // picker gagal → harus tampil hint manual entry (bukan crash).
    await tester.tap(find.byTooltip('Buka File Explorer OS'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.textContaining('path absolute'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}