import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/native/llm_inference.dart';

void main() {
  test('kDefaultStopTokens berisi token kontrol Qwen/llama', () {
    expect(
      kDefaultStopTokens,
      containsAll(['<|im_end|>', '<|im_start|>', '<|endoftext|>', '</s>']),
    );
  });

  group('firstStopTokenIndex', () {
    test('-1 untuk teks tanpa stop-sequence', () {
      expect(
        firstStopTokenIndex('Jawaban biasa tanpa token.', kDefaultStopTokens),
        -1,
      );
    });

    test('menemukan token di tengah teks', () {
      expect(firstStopTokenIndex('OK <|im_end|>', kDefaultStopTokens), 3);
    });

    test('menemukan token di awal teks', () {
      expect(firstStopTokenIndex('<|im_start|>user', kDefaultStopTokens), 0);
    });
  });

  group('truncateAtStopTokens', () {
    test('memotong teks tepat sebelum stop-sequence pertama', () {
      expect(
        truncateAtStopTokens('Lanjut langkah-langkah.<|im_start|>user'),
        'Lanjut langkah-langkah.',
      );
    });

    test('mengembalikan teks utuh bila tidak ada token', () {
      expect(truncateAtStopTokens('Jawaban normal.'), 'Jawaban normal.');
    });

    test('berhenti pada token pendek </s>', () {
      expect(
        truncateAtStopTokens('teks</s>  ', stops: kDefaultStopTokens),
        'teks',
      );
    });

    test('memotong pada awalan parsial <|im_end', () {
      expect(truncateAtStopTokens('langkah 1<|im_end baru'), 'langkah 1');
    });

    test('memotong pada awalan parsial <|im_start', () {
      expect(truncateAtStopTokens('a<|im_start b'), 'a');
    });

    test('memotong pada awalan parsial <|endoftext', () {
      expect(truncateAtStopTokens('a<|endoftext b'), 'a');
    });
  });

  group('effectiveStopTokens', () {
    test('menggabungkan token utuh dan awalan parsial', () {
      final effective = effectiveStopTokens();
      expect(effective, containsAll(kDefaultStopTokens));
      expect(effective, containsAll(kStopTokenPrefixes));
      expect(effective.toSet().length, effective.length);
    });
  });
}