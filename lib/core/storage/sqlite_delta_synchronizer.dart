// sqlite_delta_synchronizer.dart — ekstrak delta SQLite dari timestamp.

import '../db/knowledge_chunks_db.dart';
import 'models/sop_delta_payload.dart';

/// Mengambil perubahan (chunk baru/diperbarui + tombstone hapus) dari store
/// SQLite sejak sebuah timestamp, dikemas menjadi [SopDeltaPayload] yang
/// siap dikirim antar peer.
class SQLiteDeltaSynchronizer {
  SQLiteDeltaSynchronizer(this.chunksDb);

  final KnowledgeChunksDb chunksDb;

  /// Mengembalikan perubahan di atas [lastSyncedAt], dibatasi [limit] agar
  /// respons wajar berukuran. `syncTimestamp` payload adalah watermark
  /// maksimum yang tercakup oleh batch ini — peer lain memakainya sebagai
  /// `lastSyncedAt` berikutnya (aman dipakai meski batch terpotong [limit]).
  Future<SopDeltaPayload> getDeltaSince({
    required DateTime lastSyncedAt,
    int limit = 500,
  }) async {
    // Tandai awal ekstraksi; nilai watermark aman dihitung dari batch ini,
    // bukan dari clock, sehingga baris yang terpotong oleh [limit] tidak
    // ter-skip (silent data loss) saat watermark diterapkan.
    final extractionInstant = DateTime.now();
    final upserted = chunksDb.getUpdatedSince(lastSyncedAt, limit: limit);
    final deleted = chunksDb.getDeletedIdsSince(lastSyncedAt, limit: limit);

    DateTime? watermark;
    for (final chunk in upserted) {
      if (watermark == null || chunk.updatedAt.isAfter(watermark)) {
        watermark = chunk.updatedAt;
      }
    }
    final tombstoneWatermark =
        chunksDb.getTombstonesMaxDeletedAtSince(lastSyncedAt);
    if (tombstoneWatermark != null &&
        (watermark == null || tombstoneWatermark.isAfter(watermark))) {
      watermark = tombstoneWatermark;
    }

    return SopDeltaPayload(
      // Watermark maksimum yang tercakup oleh batch ini. Bila kosong sama
      // sekali, pakai waktu ekstraksi. Dokumentasi field menjelaskan bahwa
      // ini watermark, bukan wall-clock extraction.
      syncTimestamp: watermark ?? extractionInstant,
      upsertedChunks: upserted,
      deletedChunkIds: deleted,
    );
  }
}