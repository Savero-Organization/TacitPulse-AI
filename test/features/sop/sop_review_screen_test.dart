import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/sop/models/sop_draft_model.dart';
import 'package:tacit_pulse_ai/features/sop/screens/sop_review_screen.dart';
import 'package:tacit_pulse_ai/features/sop/sop_knowledge_store.dart';

class _FakeStore implements SopStore {
  SopDraftModel? saved;
  @override
  Future<void> saveSop(SopDraftModel draft) async {
    saved = draft;
  }
}

SopDraftModel _sample() => SopDraftModel.fromJson({
      'title': 'Ganti Oli Pompa',
      'equipment': 'Pompa P-01',
      'category': 'Perawatan Rutin',
      'summary': 'Prosedur penggantian oli pompa.',
      'hazards': ['permukaan panas'],
      'requiredTools': ['kunci pas'],
      'steps': [
        {'stepNumber': 1, 'action': 'Matikan mesin', 'safetyNote': 'tunggu dingin'},
        {'stepNumber': 2, 'action': 'Buang oli lama'},
      ],
    });

void main() {
  Widget wrap(Widget child) => MaterialApp(home: child);

  testWidgets('menampilkan semua komponen draft', (tester) async {
    await tester.pumpWidget(wrap(SopReviewScreen(initialDraft: _sample())));
    expect(find.text('Voice-Generated SOP Draft'), findsOneWidget);
    expect(find.text('Ganti Oli Pompa'), findsOneWidget);
    expect(find.text('Pompa P-01'), findsOneWidget);
    expect(find.text('Perawatan Rutin'), findsOneWidget);
    expect(find.text('Prosedur penggantian oli pompa.'), findsOneWidget);
    expect(find.text('permukaan panas'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump();
    expect(find.text('kunci pas'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump();
    expect(find.text('Matikan mesin'), findsOneWidget);
    expect(find.text('tunggu dingin'), findsOneWidget);
  });

  testWidgets('edit action dan safetyNote memperbarui state', (tester) async {
    final store = _FakeStore();
    await tester.pumpWidget(wrap(
      SopReviewScreen(initialDraft: _sample(), store: store),
    ));
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('step_action_1')),
      'Matikan dan kunci mesin',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('step_note_1')));
    await tester.enterText(
      find.byKey(const Key('step_note_1')),
      'kunci LOTO',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('sop_save_button')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.saved?.steps.first.action, 'Matikan dan kunci mesin');
    expect(store.saved?.steps.first.safetyNote, 'kunci LOTO');
  });

  testWidgets('tambah dan hapus langkah', (tester) async {
    final store = _FakeStore();
    await tester.pumpWidget(wrap(
      SopReviewScreen(initialDraft: _sample(), store: store),
    ));
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pump();
    await tester.tap(find.byKey(const Key('step_insert_1')));
    await tester.pump();
    // Langkah baru (kosong) disisipkan di posisi 2: stepNumber 1,2,3.
    await tester.enterText(find.byKey(const Key('step_action_2')), 'Isi oli baru');
    await tester.pump();
    await tester.dragUntilVisible(
      find.byKey(const Key('step_delete_3')),
      find.byType(ListView).first,
      const Offset(0, -100),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('step_delete_3')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sop_save_button')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.saved?.steps.length, 2);
    expect(store.saved?.steps[1].action, 'Isi oli baru');
  });

  testWidgets('validasi: judul kosong ditolak', (tester) async {
    final store = _FakeStore();
    await tester.pumpWidget(wrap(SopReviewScreen(
      initialDraft: _sample().copyWith(title: '   '),
      store: store,
    )));
    await tester.tap(find.byKey(const Key('sop_save_button')));
    await tester.pump();
    expect(find.textContaining('Judul wajib diisi'), findsOneWidget);
    expect(store.saved, isNull);
  });

  testWidgets('simpan menampilkan SnackBar sukses', (tester) async {
    final store = _FakeStore();
    await tester.pumpWidget(wrap(
      SopReviewScreen(initialDraft: _sample(), store: store),
    ));
    await tester.tap(find.byKey(const Key('sop_save_button')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('SOP successfully saved to Knowledge Store'),
      findsOneWidget,
    );
  });

  testWidgets('tambah hazard via input', (tester) async {
    final store = _FakeStore();
    await tester.pumpWidget(wrap(
      SopReviewScreen(initialDraft: _sample(), store: store),
    ));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('hazard_input')), 'tekanan tinggi');
    await tester.tap(find.byKey(const Key('hazard_add')));
    await tester.pump();
    expect(find.widgetWithText(Chip, 'tekanan tinggi'), findsOneWidget);
  });
}
