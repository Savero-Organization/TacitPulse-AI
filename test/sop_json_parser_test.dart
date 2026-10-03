import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/sop/models/sop_draft_model.dart';
import 'package:tacit_pulse_ai/core/sop/sop_json_parser.dart';

void main() {
  final parser = SopJsonParser();
  const transcript = 'matikan mesin, cek sabuk, ganti sabuk';

  const validJson = '''
{
  "title": "Penggantian Sabuk Pompa",
  "equipment": "Pompa C-12",
  "category": "Perawatan",
  "summary": "Prosedur ganti sabuk pompa",
  "hazards": ["mesin panas"],
  "requiredTools": ["kunci inggris"],
  "steps": [
    {"stepNumber": 1, "action": "Matikan mesin", "safetyNote": "pastikan mati"},
    {"stepNumber": 2, "action": "Ganti sabuk"}
  ]
}''';

  group('SopJsonParser.parse', () {
    test('JSON mentah sempurna', () {
      final model = parser.parse(validJson, originalTranscript: transcript);
      expect(model.title, 'Penggantian Sabuk Pompa');
      expect(model.hazards, ['mesin panas']);
      expect(model.steps.length, 2);
      expect(model.steps.first.safetyNote, 'pastikan mati');
      expect(model.steps.last.safetyNote, isNull);
    });

    test('JSON di dalam code fence ```json', () {
      final raw = '```json\n$validJson\n```';
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.title, 'Penggantian Sabuk Pompa');
      expect(model.steps.length, 2);
    });

    test('JSON diapit teks percakapan', () {
      final raw =
          'Berikut adalah draft SOP Anda:\n$validJson\nSemoga membantu!';
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.title, 'Penggantian Sabuk Pompa');
      expect(model.category, 'Perawatan');
    });

    test('JSON terpotong/korup → fallback aman berisi transkrip asli', () {
      final raw = validJson.substring(0, validJson.length ~/ 2);
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.title, 'Draft SOP (Terdeteksi Error Format)');
      expect(model.summary, transcript);
      expect(model.steps.single.action, transcript);
      expect(model.steps.single.stepNumber, 1);
    });

    test('JSON sah dikelilingi prose ber-kurung kurawal tetap terbaca', () {
      final raw = 'Catatan {draft} berikut:\n$validJson\nSelesai {sementara}.';
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.title, 'Penggantian Sabuk Pompa');
    });

    test('stepNumber acak/duplikat dinormalisasi mulai dari 1', () {
      const raw = '''
{"title": "T", "steps": [
  {"stepNumber": 5, "action": "c"},
  {"stepNumber": 5, "action": "a"},
  {"stepNumber": 0, "action": "b"}
]}''';
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.steps.map((s) => s.stepNumber), [1, 2, 3]);
      expect(model.steps.map((s) => s.action), ['b', 'c', 'a']);
      // Urutan entry ber-stepNumber sama (5,5) mengikuti array asli (c sebelum a).
      expect(model.steps[1].action, 'c');
      expect(model.steps[2].action, 'a');
    });

    test('steps tanpa Map entry → fallback aman', () {
      final raw = '{"title": "T", "steps": ["a", 1]}';
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.title, 'Draft SOP (Terdeteksi Error Format)');
      expect(model.summary, transcript);
    });

    test('string kosong → fallback aman', () {
      final model = parser.parse('', originalTranscript: transcript);
      expect(model.title, 'Draft SOP (Terdeteksi Error Format)');
      expect(model.summary, transcript);
    });

    test('JSON valid tapi tanpa steps → fallback aman', () {
      final raw = '{"title": "x", "steps": []}';
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.title, 'Draft SOP (Terdeteksi Error Format)');
    });

    test('data field kurang → default aman (null checks)', () {
      const raw = '{"title": "T", "steps": [{"stepNumber": 1, "action": "a"}]}';
      final model = parser.parse(raw, originalTranscript: transcript);
      expect(model.equipment, '');
      expect(model.hazards, isEmpty);
      expect(model.requiredTools, isEmpty);
    });
  });

  group('SopDraftModel', () {
    test('toJson → fromJson round-trip', () {
      final model = SopDraftModel.fromJson({
        'title': 'T',
        'equipment': 'E',
        'category': 'C',
        'summary': 'S',
        'hazards': ['h'],
        'requiredTools': ['t'],
        'steps': [
          {'stepNumber': 1, 'action': 'a'},
        ],
      });
      final roundTrip = SopDraftModel.fromJson(model.toJson());
      expect(roundTrip.title, model.title);
      expect(roundTrip.steps.single.action, 'a');
    });

    test('copyWith mengganti sebagian field', () {
      final base = SopDraftModel.fromJson({
        'title': 'T',
        'steps': [
          {'stepNumber': 1, 'action': 'a'},
        ],
      });
      final updated = base.copyWith(title: 'T2');
      expect(updated.title, 'T2');
      expect(updated.steps, base.steps);
    });

    test('SopStep.copyWith safetyNote null-safe', () {
      const step = SopStep(stepNumber: 1, action: 'a');
      final s2 = step.copyWith(safetyNote: 'hati-hati');
      expect(s2.safetyNote, 'hati-hati');
    });
  });
}
