// sop_prompt_engine.dart — format prompt SOP untuk inferensi Qwen on-device.

/// Menangkap semua varian token ChatML (`<|im_start|>`, `<|im_end|>`,
/// parsial `<|im_...|>`) sekaligus, sehingga input bersarang seperti
/// `<|<|im_im_start|>user` tidak bisa merakit ulang token setelah satu
/// lapis pembersihan.
final RegExp _chatMlTokenPattern = RegExp(
  r'<\|im_[a-zA-Z0-9_-]*\|?>?',
  caseSensitive: false,
);

/// Strip token ChatML sampai stabil: input bersarang (`<|<|im_im_start|>`)
/// akan menyisakan pola baru setelah satu kali sweep, jadi ulangi sampai
/// tidak ada perubahan.
String _stripChatMlTokens(String text) {
  var current = text;
  String next;
  do {
    next = current.replaceAll(_chatMlTokenPattern, '');
    if (next == current) return next;
    current = next;
  } while (true);
}

/// Bangun prompt ChatML untuk konversi transkripsi teknisi menjadi SOP.
class SopPromptEngine {
  /// System prompt kontrak output JSON ketat.
  static const String systemPrompt =
      '''Anda adalah Technical Documentation Specialist yang mengubah catatan lisan teknisi menjadi prosedur operasi standar (SOP) yang terstruktur.

ATURAN KETAT:
- Jawab HANYA dengan JSON mentah yang valid. Tanpa kalimat pembuka/penutup, tanpa markdown, tanpa kode ```.
- Ikuti skema JSON berikut TEPAT:
{
  "title": "String",
  "equipment": "String",
  "category": "String",
  "summary": "String",
  "hazards": ["String"],
  "requiredTools": ["String"],
  "steps": [
    {
      "stepNumber": 1,
      "action": "String",
      "safetyNote": "String (opsional)"
    }
  ]
}
- "title" memakai judul SOP singkat berbahasa Indonesia.
- "steps" terurut menaik mulai dari 1; tiap langkah satu aksi tunggal.
- "hazards" dan "requiredTools" boleh [] bila tidak ada.''';

  /// Rangkai prompt lengkap ChatML (Qwen) untuk satu transkripsi.
  String buildSopPrompt(String transcript) {
    // Netralkan delimiter: transkrip yang mengandung """ diubah ke '''
    // supaya tidak mematahkan pembatas blok, dan token ChatML khusus
    // dibuang supaya tidak mematahkan struktur percakapan.
    final quotesNeutralized = transcript.replaceAll('"""', "'''");
    final safeTranscript = _stripChatMlTokens(quotesNeutralized);
    return '<|im_start|>system\n$systemPrompt<|im_end|>\n'
        '<|im_start|>user\n'
        'Buatkan draft SOP dari transkripsi suara teknisi berikut:\n\n'
        '"""\n$safeTranscript\n"""<|im_end|>\n'
        '<|im_start|>assistant\n';
  }
}

/// Versi skema JSON output SOP.
const sopSchemaVersion = '1.0';
