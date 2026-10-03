// sop_delta_payload.dart — muatan delta sinkronisasi SOP antar peer.

import '../../db/knowledge_chunks_db.dart';

/// Muatan delta yang dikirim antar peer lewat endpoint HTTP P2P.
///
/// Ia hanya membawa perubahan sejak sinkronisasi terakhir: chunk yang
/// diperbarui ([upsertedChunks]) dan ID chunk yang dihapus
/// ([deletedChunkIds]). JSON dipakai sebagai format transport.
class SopDeltaPayload {
  const SopDeltaPayload({
    required this.syncTimestamp,
    required this.upsertedChunks,
    required this.deletedChunkIds,
  });

  /// Waktu penarikan delta; peer lain akan memakai nilai ini sebagai
  /// `lastSyncedAt` pada sinkronisasi berikutnya.
  final DateTime syncTimestamp;

  /// Chunk baru atau diperbarui sejak snapshot terakhir.
  final List<KnowledgeChunkRecord> upsertedChunks;

  /// ID chunk yang dihapus (tombstone) sejak snapshot terakhir.
  final List<String> deletedChunkIds;

  Map<String, dynamic> toJson() => {
        'syncTimestamp': syncTimestamp.toIso8601String(),
        'upsertedChunks':
            upsertedChunks.map((chunk) => chunk.toJson()).toList(),
        'deletedChunkIds': deletedChunkIds,
      };

  factory SopDeltaPayload.fromJson(Map<String, dynamic> json) {
    return SopDeltaPayload(
      syncTimestamp: DateTime.parse(json['syncTimestamp'] as String),
      upsertedChunks: (json['upsertedChunks'] as List)
          .map((e) =>
              KnowledgeChunkRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      deletedChunkIds: (json['deletedChunkIds'] as List).cast<String>(),
    );
  }
}