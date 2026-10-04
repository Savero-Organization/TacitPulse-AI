import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/utils/chatml.dart';

void main() {
  test('stripChatMlTokens mempertahankan multi-line text dan hanya memangkas ekor', () {
    const input = 'Baris satu\nBaris dua\nBaris tiga\n<|im_start|>assistant\nBaris empat';
    final cleaned = stripChatMlTokens(input);
    expect(cleaned, contains('Baris satu'));
    expect(cleaned, contains('Baris dua'));
    expect(cleaned, contains('Baris tiga'));
    expect(cleaned, isNot(contains('<|im_start|>')));
  });

  test('stripChatMlTokens pada multi-line dengan <|im_end|> tidak menghasilkan kosong', () {
    const input = 'Jawaban lapis pertama\n\nJawaban rincian\n<|im_end|>\n';
    final cleaned = stripChatMlTokens(input);
    expect(cleaned, 'Jawaban lapis pertama\n\nJawaban rincian\n\n');
  });

  test('stripChatMlTokens tidak merusak teks yang mengandung baris kosong', () {
    // Bug dotAll: `.*$` dengan dotAll:true menghabiskan baris berikutnya.
    const input = 'Teks utama\n\n<|im_start|>user\nteks kedua';
    final cleaned = stripChatMlTokens(input);
    expect(cleaned, contains('Teks utama'));
    expect(cleaned, contains('user'));
    expect(cleaned, isNot(contains('<|im_start|>')));
    expect(cleaned, isNotEmpty);
  });
}