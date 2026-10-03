// sop_vector_merger.dart — merge LWW antara chunk vektor SOP remote & lokal.

import '../db/knowledge_chunks_db.dart';
import 'models/sop_delta_payload.dart';

/// Ringkasan hasil sebuah merge.
class SopMergeResult {
  const SopMergeResult({
    required this.inserted,
    required this.updated,
    required this.skipped,
    this.deleted = 0,
  });

  /// Chunk baru yang dimasukkan (tidak ada lokal sebelumnya).
  final int inserted;

  /// Chunk lokal yang diperbarui karena versi remote lebih baru (LWW).
  final int updated;

  /// Chunk remote yang diabaikan karena versi lokal lebih baru / setara.
  final int skipped;

  /// Baris lokal yang dihapus karena masuk tombstone dari peer.
  final int deleted;

  @override
  String toString() =>
      'SopMergeResult(inserted: $inserted, updated: $updated, skipped: $skipped, deleted: $deleted)';
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
    final counts = _Counts.zero();
    _withImmediateTransaction(() {
      _mergeChunks(remoteChunks, counts);
    });
    return SopMergeResult(
      inserted: counts.inserted,
      updated: counts.updated,
      skipped: counts.skipped,
      deleted: counts.deleted,
    );
  }

  /// Menggabungkan satu batch [SopDeltaPayload]: chunk upsert via LWW lalu
  /// penghapusan via tombstone. Keduanya terjadi dalam satu transaksi
  /// `BEGIN IMMEDIATE` sehingga peer lain tidak bisa menulis di sela merge
  /// (menghindari SQLITE_BUSY dari DEF-FRAMED/DEFERRED) dan seluruh perubahan
  /// di-rollback bila ada kegagalan.
  SopMergeResult mergePayload(SopDeltaPayload payload) {
    final counts = _Counts.zero();
    _withImmediateTransaction(() {
      _mergeChunks(payload.upsertedChunks, counts);
      for (final id in payload.deletedChunkIds) {
        if (chunksDb.delete(id)) {
          counts.deleted++;
        }
      }
    });
    return SopMergeResult(
      inserted: counts.inserted,
      updated: counts.updated,
      skipped: counts.skipped,
      deleted: counts.deleted,
    );
  }

  /// Menjalankan [body] dalam `BEGIN IMMEDIATE` + `COMMIT`; pada exception
  /// di-ROLLBACK (upaya di-nest try bila ROLLBACK sendiri gagal) lalu lempar
  /// ulang agar pemanggil tahu merge gagal total.
  void _withImmediateTransaction(void Function() body) {
    final db = chunksDb.db;
    db.execute('BEGIN IMMEDIATE');
    try {
      body();
      db.execute('COMMIT');
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {
        // Sudah tidak dalam transaksi (mis. ROLLBACK sebelumnya sukses) —
        // biarkan saja, lempar ulang error asli di bawah.
      }
      rethrow;
    }
  }

  void _mergeChunks(List<KnowledgeChunkRecord> remoteChunks, _Counts c) {
    for (final remote in remoteChunks) {
      final local = chunksDb.getById(remote.id);
      if (local == null) {
        chunksDb.insert(remote);
        c.inserted++;
      } else if (remote.updatedAt.isAfter(local.updatedAt)) {
        chunksDb.update(remote);
        c.updated++;
      } else {
        c.skipped++;
      }
    }
  }
}

class _Counts {
  _Counts(this.inserted, this.updated, this.skipped, this.deleted);
  factory _Counts.zero() => _Counts(0, 0, 0, 0);
  int inserted;
  int updated;
  int skipped;
  int deleted;
}