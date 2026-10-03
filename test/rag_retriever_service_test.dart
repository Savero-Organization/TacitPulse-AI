import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_db.dart';
import 'package:tacit_pulse_ai/core/rag/rag_retriever_service.dart';

KnowledgeChunkRecord _rec(String id, {double? distance}) {
  return KnowledgeChunkRecord(
    id: id,
    documentName: 'SOP-$id.pdf',
    page: 2,
    chunkText: 'isi chunk $id',
    x: 0.1,
    y: 0.2,
    w: 0.5,
    h: 0.3,
    embedding: const [],
    distance: distance,
  );
}

void main() {
  test('retrieve mengembalikan similarity 1 - distance, topK di lewat', () async {
    int? seenK;
    final svc = RagRetrieverService(
      search: (v, {int k = 10}) {
        seenK = k;
        return [_rec('a', distance: 0.1), _rec('b', distance: 0.4)];
      },
      embedder: (_) async => List<double>.filled(384, 1.0),
    );
    final out = await svc.retrieve('ganti oli');
    expect(seenK, 3);
    expect(out.length, 2);
    expect(out.first.similarity, closeTo(0.9, 1e-9));
    expect(out.last.similarity, closeTo(0.6, 1e-9));
  });

  test('topK configurable dan minScore menyaring', () async {
    final svc = RagRetrieverService(
      search: (_, {int k = 10}) =>
          [_rec('a', distance: 0.1), _rec('b', distance: 0.85)],
      embedder: (_) async => List<double>.filled(384, 1.0),
    );
    final out = await svc.retrieve('q', topK: 2, minScore: 0.5);
    expect(out.map((c) => c.record.id), ['a']);
  });

  test('record tanpa distance dianggap paling tidak mirip (similarity 0)', () async {
    final svc = RagRetrieverService(
      search: (_, {int k = 10}) => [_rec('a')],
      embedder: (_) async => List<double>.filled(384, 1.0),
    );
    final out = await svc.retrieve('q');
    expect(out.single.similarity, 0.0);
  });

  test('query kosong → ArgumentError; topK nol → ArgumentError', () async {
    final svc = RagRetrieverService(
      search: (_, {int k = 10}) => const [],
      embedder: (_) async => <double>[],
    );
    await expectLater(svc.retrieve('   '), throwsArgumentError);
    await expectLater(svc.retrieve('q', topK: 0), throwsArgumentError);
  });
}
