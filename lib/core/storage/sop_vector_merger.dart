// sop_vector_merger.dart — merge LWW antara chunk vektor SOP remote & lokal.

import '../db/knowledge_chunks_db.dart';

/// Ringkasan hasil sebuah merge.
class SopMergeResult {
  const SopMergeResult({
    required this.inserted,
    required this.updated,
    required this.skipped,
  });

  /// Chunk baru yang dimasukkan (tidak ada lokal sebelumnya).
  final int inserted;

  /// Chunk lokal yang diperbarui karena versi remote lebih baru (LWW).
  final int updated;

  /// Chunk remote yang diabaikan karena versi lokal lebih baru / setara.
  final int skipped;

  @override
  String toString() =>
      'SopMergeResult(inserted: $inserted, updated: $updated, skipped: $skipped)';
}

/// Menyatukan daftar chunk vektor SOP yang datang dari peer, memakai aturan
/// Last-Write-Wins berdasarkan [KnowledgeChunkRecord.updatedAt]: update
/// hanya bila remote lebih baru dari lokal; jika lokal tidak ada, masukkan.
///
/// Seluruh operasi berjalan dalam satu transaksi SQLite agar status lokal
/// tetap konsisten bila satu chunk gagal ditulis (semua atau tidak sama
/// sekali).
class SopVectorMerger {
  SopVectorMerger(this.chunksDb);

  final KnowledgeChunksDb chunksDb;

  /// Menggabungkan [remoteChunks] ke database lokal. Mengembalikan ringkasan
  /// [SopMergeResult]. Melemparkan ulang exception bila transaksi gagal
  /// (semua perubahan di-rollback).
  SopMergeResult merge(List<KnowledgeChunkRecord> remoteChunks) {
    final db = chunksDb.db;
    var inserted = 0;
    var updated = 0;
    var skipped = 0;

    db.execute('BEGIN');
    try {
      for (final remote in remoteChunks) {
        final local = chunksDb.getById(remote.id);
        if (local == null) {
          chunksDb.insert(remote);
          inserted++;
        } else if (remote.updatedAt.isAfter(local.updatedAt)) {
          // Versi remote lebih baru → timpa. updatedAt ikut diperbarui oleh
          // update() sehingga watermark lokal maju dengan benar.
          chunksDb.update(remote);
          updated++;
        } else {
          skipped++;
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return SopMergeResult(
      inserted: inserted,
      updated: updated,
      skipped: skipped,
    );
  }
}