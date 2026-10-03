import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/rag/prompt_builder.dart';
import 'package:tacit_pulse_ai/core/rag/rag_retriever_service.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_db.dart';

RetrievedChunk _chunk(String name, int page, String text, double sim) {
  return RetrievedChunk(
    record: KnowledgeChunkRecord(
      id: name,
      documentName: name,
      page: page,
      chunkText: text,
      x: 0.1,
      y: 0.2,
      w: 0.5,
      h: 0.3,
      embedding: const [],
    ),
    similarity: sim,
  );
}

void main() {
  const builder = PromptBuilder();

  test('buildPrompt berisi format ChatML dengan system + user + assistant', () {
    final prompt = builder.buildPrompt('cara ganti oli', const []);
    expect(prompt, startsWith('<|im_start|>system\n'));
    expect(prompt, contains('<|im_start|>user\ncara ganti oli'));
    expect(prompt, endsWith('<|im_start|>assistant\n'));
    expect(prompt.split('<|im_end|>').length - 1, 2);
  });

  test('konteks disusun sebagai blok bernomor dengan skor & bbox', () {
    final prompt = builder.buildPrompt('ganti oli', [
      _chunk('SOP-Ganti-Oli.pdf', 3, 'Matikan mesin, dinginkan.', 0.92),
      _chunk('Log-2024.pdf', 12, 'Ganti oli tiap 500 jam.', 0.81),
    ]);
    expect(prompt, contains('[1] Dokumen: SOP-Ganti-Oli.pdf'));
    expect(prompt, contains('Halaman: 3'));
    expect(prompt, contains('92%'));
    expect(prompt, contains('Matikan mesin'));
    expect(prompt, contains('[2] Dokumen: Log-2024.pdf'));
  });

  test('tanpa konteks menghasilkan prompt tanpa blok referensi', () {
    final prompt = builder.buildPrompt('q', const []);
    expect(prompt, isNot(contains('Referensi:')));
  });

  test('system prompt memaksa hanya menjawab dari referensi', () {
    expect(kRagSystemPrompt, contains('HANYA'));
  });

  test('query kosong → ArgumentError', () {
    expect(() => builder.buildPrompt('  ', const []), throwsArgumentError);
  });
}
