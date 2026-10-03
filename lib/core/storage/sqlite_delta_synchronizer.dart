// sqlite_delta_synchronizer.dart — ekstrak delta SQLite dari timestamp.

import '../db/knowledge_chunks_db.dart';
import 'models/sop_delta_payload.dart';

/// Mengambil perubahan (chunk baru/diperbarui + tombstone hapus) dari store
/// SQLite sejak sebuah timestamp, dikemas menjadi [SopDeltaPayload] yang
/// siap dikirim antar peer.
class SQLiteDeltaSynchronizer {
  SQLiteDeltaSynchronizer(this.chunksDb);

  final KnowledgeChunksDb chunksDb;

  /// Mengembalikan semua perubahan setelah [lastSyncedAt], dibatasi [limit]
  /// untuk ukuran respons yang wajar. [syncTimestamp] di payload adalah
  /// waktu server; peer lain memakainya sebagai watermark berikutnya.
  Future<SopDeltaPayload> getDeltaSince({
    required DateTime lastSyncedAt,
    int limit = 500,
  }) async {
    final upserted = chunksDb.getUpdatedSince(lastSyncedAt, limit: limit);
    final deleted = chunksDb.getDeletedIdsSince(lastSyncedAt, limit: limit);
    return SopDeltaPayload(
      syncTimestamp: DateTime.now(),
      upsertedChunks: upserted,
      deletedChunkIds: deleted,
    );
  }
}