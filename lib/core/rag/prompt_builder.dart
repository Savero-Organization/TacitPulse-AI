// prompt_builder.dart — GABUT-38: bangun prompt ChatML ber-augmentasi
// konteks retrieval untuk inferensi Qwen on-device.
//
// Berbeda dari pemanggilan langsung LLMInference: format konteks di sini
// dinormalisasi (blok "Referensi" dengan nomor sumber, judul, halaman,
// skor) supaya model kecil lebih terikat pada sumber dan tidak mudah
// berhalusinasi di luar konteks.

import 'rag_retriever_service.dart';

/// System prompt yang menahan model agar hanya memakai konteks referensi.
const String kRagSystemPrompt =
    'Kamu adalah asisten teknisi maintenance pabrik. Jawab singkat, padat, '
    'dan langsung praktis. Gunakan HANYA informasi dari blok "Referensi" '
    'di bawah. Sebutkan sumber (nama dokumen + halaman) untuk tiap klaim. '
    'Jangan menebak fakta yang tidak ada di referensi; bila referensi tidak '
    'memuat jawabannya, katakan dengan jelas bahwa dokumen tidak memuatnya.';

/// Builder prompt ChatML untuk RAG.
class PromptBuilder {
  const PromptBuilder({this.systemPrompt = kRagSystemPrompt});

  final String systemPrompt;

  /// Format satu chunk referensi sebagai blok bernomor.
  String _formatContextBlock(int index, RetrievedChunk chunk) {
    final r = chunk.record;
    final bbox =
        '(x: ${r.x.toStringAsFixed(2)}, y: ${r.y.toStringAsFixed(2)}, '
        'w: ${r.w.toStringAsFixed(2)}, h: ${r.h.toStringAsFixed(2)})';
    return '[${index + 1}] Dokumen: ${r.documentName} | Halaman: ${r.page} '
        '| Kemiripan: ${(chunk.similarity * 100).toStringAsFixed(0)}% '
        '| Area: $bbox\n${r.chunkText.trim()}';
  }

  /// Gabungkan semua konteks menjadi blok referensi bernomor.
  String buildContextBlocks(List<RetrievedChunk> contexts) {
    if (contexts.isEmpty) return '';
    final buffer = StringBuffer();
    for (var i = 0; i < contexts.length; i++) {
      buffer.writeln(_formatContextBlock(i, contexts[i]));
      if (i < contexts.length - 1) buffer.writeln();
    }
    return buffer.toString();
  }

  /// Rangkai prompt lengkap ChatML untuk satu pertanyaan RAG.
  String buildPrompt(String query, List<RetrievedChunk> contexts) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(query, 'query', 'kosong');
    }
    final contextSection = contexts.isEmpty
        ? ''
        : '\n\nReferensi:\n${buildContextBlocks(contexts)}';
    return '<|im_start|>system\n$systemPrompt<|im_end|>\n'
        '<|im_start|>user\n$trimmed$contextSection<|im_end|>\n'
        '<|im_start|>assistant\n';
  }
}
