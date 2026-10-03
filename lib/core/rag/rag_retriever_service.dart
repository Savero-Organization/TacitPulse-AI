// rag_retriever_service.dart — GABUT-37: retrieval top-K berbasis embedding
// terhadap tabel vektor `knowledge_chunks` (sqlite-vec).
//
// Alur: pertanyaan user → vektor embedding (via getEmbedding native) →
// query KNN cosine di SQLite → daftar chunk terdekat beserta skor
// kemiripan. Dimaksudkan sebagai satu-satunya pintu retrieval RAG
// (menggantikan scanning in-memory di IntentRouter bila perlu).

import 'dart:math' as math;

import '../db/knowledge_chunks_db.dart';
import '../native/llama_bridge.dart' show getEmbedding;

/// Hasil retrieval: satu record chunk + skor kemiripan cosine ([-1, 1]).
class RetrievedChunk {
  const RetrievedChunk({required this.record, required this.similarity});

  final KnowledgeChunkRecord record;

  /// 1 - jarak cosine dari query; rentang [-1, 1] (1 = identik, -1 = berlawanan arah).
  final double similarity;
}

/// Fungsi embedding teks → vektor (umumnya [getEmbedding] dari native
/// bridge). Di-inject supaya test tidak butuh model asli.
typedef QueryEmbedder = Future<List<double>> Function(String query);

/// Fungsi sinkron cari KNN dari tabel vektor — default [KnowledgeChunksDb.search].
/// Di-inject di test supaya tidak butuh ekstensi vec0 native.
typedef ChunkSearch = List<KnowledgeChunkRecord> Function(
  List<double> queryEmbedding, {
  int k,
});

/// Retriever top-K cosine di atas tabel vec0 `knowledge_chunks`.
class RagRetrieverService {
  RagRetrieverService({
    KnowledgeChunksDb? db,
    ChunkSearch? search,
    QueryEmbedder? embedder,
  })  : _search = search ?? (db ?? _missingDb()).search,
        _embed = embedder ?? getEmbedding;

  final ChunkSearch _search;
  final QueryEmbedder _embed;

  static KnowledgeChunksDb _missingDb() =>
      throw ArgumentError('butuh salah satu: db atau search');

  /// Kembalikan [topK] chunk paling relevan untuk [query].
  ///
  /// [topK] default 3 (GABUT-37) dan bisa di-override per panggilan.
  /// [minScore] opsional: buang hasil dengan kemiripan di bawah ambang
  /// (di bawah it hallucination risk naik karena konteks tidak relevan).
  Future<List<RetrievedChunk>> retrieve(
    String query, {
    int topK = 3,
    double minScore = 0.0,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(query, 'query', 'kosong');
    }
    if (topK <= 0) {
      throw ArgumentError.value(topK, 'topK', 'harus > 0');
    }
    final vector = await _embed(trimmed);
    // Over-fetch supaya filter minScore tidak membuang kuota topK —
    // mis. topK=3 dan 2 hasil top-3 di bawah ambang, tetap bisa mengisi
    // kuota dari kandidat berikutnya sebelum di-trim.
    final fetchK = math.max(topK * 3, 10);
    final rows = _search(vector, k: fetchK);
    return rows
        .map((r) => RetrievedChunk(
              record: r,
              similarity: 1.0 - (r.distance ?? 1.0),
            ))
        .where((c) => c.similarity >= minScore)
        .take(topK)
        .toList(growable: false);
  }
}
