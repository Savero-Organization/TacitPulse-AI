import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/models/citation.dart';
import 'package:tacit_pulse_ai/core/rag/intent_router.dart';

void main() {
  final router = IntentRouter.instance;

  group('fast path regex', () {
    test('salam -> greeting, tanpa RAG', () {
      final d = router.route('halo, apa kabar?');
      expect(d.kind, IntentKind.greeting);
      expect(d.usesRag, isFalse);
      expect(d.contextChunks, isEmpty);
      expect(d.contextDocs, isEmpty);
      expect(d.systemPrompt, kGeneralSystemPrompt);
    });

    test('sebutan sapaan pagi/siang/malam', () {
      expect(router.route('Selamat pagi').kind, IntentKind.greeting);
      expect(router.route('assalamualaikum').kind, IntentKind.greeting);
    });

    test('matematika -> math, tanpa RAG', () {
      final d = router.route('berapa 15 * 4?');
      expect(d.kind, IntentKind.math);
      expect(d.usesRag, isFalse);
    });

    test('aritmetika lintas konteks tetap terdeteksi', () {
      expect(router.route('hitung 3,5 + 2,5').kind, IntentKind.math);
      expect(router.route('120 / 6').kind, IntentKind.math);
    });

    test('frasa pendek -> generalShortcut, tanpa RAG', () {
      final d = router.route('tes');
      expect(d.kind, IntentKind.generalShortcut);
      expect(d.usesRag, isFalse);
    });

    test('query kosong -> generalShortcut', () {
      expect(router.route('   ').kind, IntentKind.generalShortcut);
    });
  });

  group('rag thresholding', () {
    test('query operasional kompresor -> RAG dengan skor >= ambang', () {
      final d = router.route(
        'Berapa tekanan oli yang benar saat cold start kompresor screw?',
      );
      expect(d.kind, IntentKind.question);
      expect(d.usesRag, isTrue);
      expect(d.topScore, greaterThanOrEqualTo(kRagScoreThreshold));
      expect(
        d.contextChunks.first.title,
        contains('SOP PM-KOM-014: Cold Start'),
      );
    });

    test('query AA-221 -> RAG dengan chunk alarm pressure switch', () {
      final d = router.route('Kode error "AA-221" muncul di panel?');
      expect(d.usesRag, isTrue);
      expect(d.contextChunks.any((c) => c.id == 'kom-014-alarm'), isTrue);
      expect(d.topScore, greaterThanOrEqualTo(kRagScoreThreshold));
    });

    test('query tidak relevan -> context dikosongkan (skor di bawah ambang)',
        () {
      final d = router.route('Tolong ceritakan tentang pemeliharaan mesin ya');
      expect(d.usesRag, isFalse);
      expect(d.topScore, lessThan(kRagScoreThreshold));
      expect(d.contextChunks, isEmpty);
      expect(d.systemPrompt, kGeneralSystemPrompt);
    });

    test('citations mengikuti chunk yang lolos ambang', () {
      final d = router.route(
        'Berapa tekanan oli yang benar saat cold start kompresor screw?',
      );
      expect(d.citations, isNotEmpty);
      for (final c in d.citations) {
        expect(c, isA<SourceCitation>());
        expect(c.score, greaterThanOrEqualTo(kRagScoreThreshold));
        expect(c.type, CitationType.sop);
      }
    });

    test('contextDocs memuat referensi berformat [N]', () {
      final d = router.route(
        'Berapa tekanan oli yang benar saat cold start kompresor screw?',
      );
      expect(d.contextDocs, contains('[1] '));
      expect(d.contextDocs, contains('(hlm. 3): '));
    });
  });

  group('prompt conditioning', () {
    test('RAG memakai prompt operasional', () {
      final d = router.route(
        'Berapa tekanan oli yang benar saat cold start kompresor screw?',
      );
      expect(d.systemPrompt, kOperationalSystemPrompt);
      expect(d.usesRag, isTrue);
    });

    test('fast path memakai prompt umum', () {
      final d = router.route('halo');
      expect(d.systemPrompt, kGeneralSystemPrompt);
    });
  });
}