import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/utils/thinking_utils.dart';

void main() {
  group('thinkingContent', () {
    test('mengambil konten antara tag berpikir', () {
      const text = 'Prolog thinking Hidup ternyata begitu tenang response '
          'Jawaban.';
      expect(thinkingContent(text), 'Hidup ternyata begitu tenang');
    });

    test('null bila tidak ada blok berpikir', () {
      expect(thinkingContent('Hanya jawaban biasa.'), isNull);
    });

    test('null bila tag pembuka ada tapi belum ditutup', () {
      expect(thinkingContent('Masih thinking begini saja belum selesai...'),
          isNull);
    });
  });

  group('answerContent', () {
    test('mengembalikan teks setelah tag penutup', () {
      const text = 'Sebentar thinking perkirakan risikonya response Perlu cek '
          'SOP. Jawaban final ada.';
      expect(answerContent(text), 'Perlu cek SOP. Jawaban final ada.');
    });

    test('tanpa blok berpikir = teks utuh', () {
      expect(answerContent('Biasa saja.'), 'Biasa saja.');
    });

    test('masih di dalam blok berpikir = kosong', () {
      expect(answerContent('Saya thinking masih mikir... jadi gimana?'), '');
    });
  });

  group('thinkingPreview', () {
    test('berisi konten parsial walau tag penutup belum muncul', () {
      expect(
        thinkingPreview('Sedang thinking mikir belum selesai...'),
        'mikir belum selesai...',
      );
    });

    test('identik dengan thinkingContent bila blok sudah tertutup', () {
      const text = 'Sedang thinking mikir selesai response Jawaban.';
      expect(thinkingPreview(text), thinkingContent(text));
    });

    test('null bila tidak ada tag pembuka', () {
      expect(thinkingPreview('jawaban polos tanpa berpikir'), isNull);
    });
  });

  group('isInsideThinkingBlock', () {
    test('true bila pembuka ada tanpa penutup', () {
      expect(isInsideThinkingBlock('Tes thinking masih mikir....'), isTrue);
    });

    test('false bila sudah ada penutup', () {
      expect(
        isInsideThinkingBlock('Saya thinking selesai mikir response jawaban'),
        isFalse,
      );
    });

    test('false tanpa tag sama sekali', () {
      expect(isInsideThinkingBlock('jawaban polos'), isFalse);
    });

    test('format XML: true bila belum ada penutup', () {
      expect(isInsideThinkingBlock('<thinking>masih mikir...'), isTrue);
    });

    test('format XML: false setelah ditutup', () {
      expect(
        isInsideThinkingBlock('<thinking>selesai</thinking> jawaban'),
        isFalse,
      );
    });
  });

  group('format XML (<thinking>)', () {
    test('findThinkingSpan mendeteksi <thinking>', () {
      final span = findThinkingSpan('<thinking>mikir...</thinking>jawaban');
      expect(span, isNotNull);
      expect(span!.open, kXmlThinkingStartToken);
      expect(span.close, kXmlThinkingEndToken);
    });

    test('memilih pembuka yang muncul lebih dulu saat dua format tercampur', () {
      final span = findThinkingSpan(
        'aa thinking literal... response lalu <thinking>xml</thinking>',
      );
      expect(span!.open, kThinkingStartToken);
    });

    test('thinkingContent format XML', () {
      expect(
        thinkingContent('<thinking>mikir dulu</thinking>jawaban'),
        'mikir dulu',
      );
    });

    test('thinkingContent null untuk <thinking> tanpa penutup', () {
      expect(thinkingContent('<thinking>belum selesai...'), isNull);
    });

    test('thinkingPreview baru separuh <thinking>', () {
      expect(thinkingPreview('<thinking>sedang mikir'), 'sedang mikir');
    });

    test('answerContent format XML', () {
      expect(
        answerContent('<thinking>mikir</thinking> Jawaban final.'),
        'Jawaban final.',
      );
    });

    test('matchingCloseTag menghasilkan tag penutup yang cocok', () {
      expect(matchingCloseTag(kThinkingStartToken), kThinkingEndTag);
      expect(matchingCloseTag(kXmlThinkingStartToken), kXmlThinkingEndTag);
      expect(matchingCloseToken(kXmlThinkingStartToken), kXmlThinkingEndToken);
    });
  });

  group('stripSpecialTokens', () {
    test('membuang semua token kontrol', () {
      const raw = 'Hai<|im_end|><|im_start|>user<|endoftext|></s>';
      expect(stripSpecialTokens(raw), 'Haiuser');
    });

    test('mempertahankan whitespace agar penggabungan per-piece aman', () {
      expect(stripSpecialTokens('pertama '), 'pertama ');
    });

    test('teks bersih tanpa token tidak berubah', () {
      expect(stripSpecialTokens('Jawaban normal.'), 'Jawaban normal.');
    });

    test('membuang token parsial <|im_end di ujung teks', () {
      expect(stripSpecialTokens('Jawaban <|im_end'), 'Jawaban ');
    });

    test('membuang token parsial <|im_start di ujung teks', () {
      expect(stripSpecialTokens('Halo<|im_start'), 'Halo');
    });

    test('membuang token parsial <|endoftext di ujung teks', () {
      expect(stripSpecialTokens('analisis<|endoftext'), 'analisis');
    });

    test('membuang tag parsial </s di ujung teks', () {
      expect(stripSpecialTokens('teks</s'), 'teks');
    });

    test('token parsial di tengah kalimat bukan jatah strip (jatah truncation)',
    () {
  expect(stripSpecialTokens('a<|im_end b'), 'a<|im_end b');
});

    test('membuang token parsial di ujung baris (multiLine \$)', () {
      expect(stripSpecialTokens('baris1<|im_end\nbaris2'), 'baris1\nbaris2');
    });

    test('sisa token parsial bertumpuk dibersihkan berlapis', () {
      expect(stripSpecialTokens('ok<|im_end<|im_start'), 'ok');
    });

    test('membuang token <|im_end_of_text|> utuh maupun terpotong', () {
      expect(stripSpecialTokens('Halo<|im_end_of_text|>sisa'), 'Halosisa');
      expect(stripSpecialTokens('jawaban<|im_end_of_text'), 'jawaban');
      expect(stripSpecialTokens('<|im_end_of_text'), '');
    });
  });

  group('removeEmptyThinkingBlocks', () {
    test('membuang blok reasoning literal yang kosong', () {
      const text = 'Halo  thinking  response  Jawaban.';
      final cleaned = removeEmptyThinkingBlocks(text);
      expect(cleaned, isNot(contains('thinking')));
      expect(cleaned, isNot(contains('response')));
      expect(cleaned, contains('Jawaban.'));
    });

    test('membuang blok reasoning literal kosong dengan newline', () {
      const text = 'Halo thinking\n\nresponse\nJawaban.';
      expect(removeEmptyThinkingBlocks(text), isNot(contains('thinking')));
      expect(removeEmptyThinkingBlocks(text), contains('Jawaban.'));
    });

    test('membuang blok XML kosong <thinking></thinking>', () {
      const text = '<thinking>\n  </thinking>Halo.';
      final cleaned = removeEmptyThinkingBlocks(text);
      expect(cleaned, isNot(contains('<thinking>')));
      expect(cleaned, isNot(contains('</thinking>')));
      expect(cleaned, contains('Halo.'));
    });

    test('tidak menyentuh blok berpikir yang berisi konten', () {
      const text = 'Prolog  thinking mikir dulu  response Jawaban.';
      final cleaned = removeEmptyThinkingBlocks(text);
      expect(cleaned, contains('mikir dulu'));
      expect(cleaned, contains('response'));
      expect(answerContent(cleaned), 'Jawaban.');
    });

    test('teks tanpa blok tidak berubah', () {
      const clean = 'Jawaban biasa tanpa reasoning.';
      expect(removeEmptyThinkingBlocks(clean), clean);
    });
  });
}