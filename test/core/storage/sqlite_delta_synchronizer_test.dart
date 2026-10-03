import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_db.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_store.dart';
import 'package:tacit_pulse_ai/core/db/sqlite_vec.dart';
import 'package:tacit_pulse_ai/core/storage/models/sop_delta_payload.dart';
import 'package:tacit_pulse_ai/core/storage/sqlite_delta_synchronizer.dart';

String? _resolveVec0Library() {
  final env = Platform.environment['VEC0_LIB_PATH'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
  const candidates = [
    'build/linux/x64/debug/bundle/lib/libvec0.so',
    'build/linux/x64/debug/libvec0.so',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

KnowledgeChunkRecord _chunk(
  String id, {
  required DateTime updatedAt,
  String text = 'konten',
}) {
  return KnowledgeChunkRecord(
    id: id,
    documentName: 'SOP-$id.pdf',
    page: 1,
    chunkText: text,
    x: 0.1,
    y: 0.2,
    w: 0.5,
    h: 0.3,
    embedding: List<double>.filled(kEmbeddingDimensions, 0.25),
    updatedAt: updatedAt,
  );
}

void main() {
  final vec0Path = _resolveVec0Library();
  final skip = vec0Path == null ? 'libvec0.so tidak ada' : false;

  late Database db;
  late KnowledgeChunksDb chunks;
  late SQLiteDeltaSynchronizer sync;

  setUp(() {
    db = openDatabaseWithVec(':memory:', vecLibraryPath: vec0Path);
    db.execute(kKnowledgeChunksSchema);
    db.execute(kKnowledgeChunksTombstoneSchema);
    db.execute(kKnowledgeChunksTombstoneIndex);
    chunks = KnowledgeChunksDb(db);
    sync = SQLiteDeltaSynchronizer(chunks);
  });

  tearDown(() => db.close());

  test('getDeltaSince hanya mengambil chunk dengan updatedAt > watermark',
      skip: skip, () async {
    final base = DateTime.utc(2026, 1, 1, 12);
    chunks.insert(_chunk('lalu', updatedAt: base.subtract(const Duration(days: 3))));
    chunks.insert(_chunk('batas', updatedAt: base));
    chunks.insert(_chunk('baru', updatedAt: base.add(const Duration(hours: 2))));

    final delta = await sync.getDeltaSince(lastSyncedAt: base);

    expect(delta.upsertedChunks.map((c) => c.id), ['baru']);
    expect(delta.upsertedChunks.first.updatedAt.millisecondsSinceEpoch,
        base.add(const Duration(hours: 2)).millisecondsSinceEpoch);
    expect(delta.deletedChunkIds, isEmpty);
    expect(delta.syncTimestamp, isA<DateTime>());
  });

  test('getDeltaSince mengembalikan tombstone untuk baris yang dihapus',
      skip: skip, () async {
    final base = DateTime.utc(2026, 1, 1, 12);
    chunks.insert(_chunk('a', updatedAt: base));
    chunks.insert(_chunk('b', updatedAt: base.add(const Duration(hours: 1))));
    expect(chunks.delete('a'), isTrue); // tombstone diarsir sekarang

    // Watermark sebelum penghapusan → 'a' harus muncul sebagai hapus.
    final delta = await sync.getDeltaSince(lastSyncedAt: base);
    expect(delta.deletedChunkIds, contains('a'));
    // 'b' juga baru (updatedAt > watermark).
    expect(delta.upsertedChunks.map((c) => c.id), ['b']);
  });

  test('getDeltaSince menghormati limit dan urutan ascending', skip: skip,
      () async {
    final base = DateTime.utc(2026, 1, 1, 12);
    for (var i = 0; i < 5; i++) {
      chunks.insert(_chunk('c$i',
          updatedAt: base.add(Duration(minutes: i))));
    }
    final delta = await sync.getDeltaSince(lastSyncedAt: base.add(const Duration(minutes: 1)), limit: 2);
    expect(delta.upsertedChunks.length, 2);
    final ids = delta.upsertedChunks.map((c) => c.id).toList();
    expect(ids, ['c2', 'c3']);
  });

  test('payload serialize ke JSON dan kembali (toJson/fromJson)', skip: skip,
      () async {
    final base = DateTime.utc(2026, 1, 1, 12);
    chunks.insert(_chunk('json1', updatedAt: base.add(const Duration(minutes: 5))));
    chunks.insert(_chunk('json2', updatedAt: base.add(const Duration(minutes: 10))));
    chunks.delete('json1');

    final delta = await sync.getDeltaSince(lastSyncedAt: base);
    final json = delta.toJson();
    final decoded = SopDeltaPayload.fromJson(json);

    expect(decoded.deletedChunkIds, contains('json1'));
    expect(decoded.upsertedChunks.map((c) => c.id), contains('json2'));
    // Embedding & bbox bertahan setelah round-trip JSON.
    final restored =
        decoded.upsertedChunks.firstWhere((c) => c.id == 'json2');
    expect(restored.embedding,
        List<double>.filled(kEmbeddingDimensions, 0.25));
    expect(restored.x, 0.1);
    expect(restored.updatedAt.millisecondsSinceEpoch,
        base.add(const Duration(minutes: 10)).millisecondsSinceEpoch);
  });

  test('migrasi: tabel lama tanpa updated_at dikonversi, data utuh',
      skip: skip, () {
    // Buat ulang knowledge_chunks versi skema lama (tanpa updated_at).
    db.execute('DROP TABLE $kKnowledgeChunksTableName');
    db.execute('''CREATE VIRTUAL TABLE $kKnowledgeChunksTableName USING vec0(
  embedding float[$kEmbeddingDimensions] distance_metric=cosine,
  +id TEXT, +document_name TEXT, +page INTEGER, +chunk_text TEXT,
  +x double, +y double, +w double, +h double
);''');
    final blob = Float32List.fromList(
        List<double>.filled(kEmbeddingDimensions, 0.31)).buffer.asUint8List();
    db.execute(
      'INSERT INTO $kKnowledgeChunksTableName '
      '(embedding, id, document_name, page, chunk_text, x, y, w, h) '
      "VALUES (vec_f32(?), 'legacy1', 'SOP-legacy', 3, 'isi lama', 0.1, 0.2, 0.5, 0.3)",
      [blob],
    );

    // Migrasi atomik: backfill updated_at=0, tambahkan kolom, rename.
    migrateKnowledgeChunksTable(db);

    final rows = db.select(
      'SELECT id, page, updated_at FROM $kKnowledgeChunksTableName',
    );
    expect(rows.length, 1);
    expect(rows.first['id'], 'legacy1');
    expect(rows.first['updated_at'], 0);

    chunks.insert(KnowledgeChunkRecord(
      id: 'new1',
      documentName: 'SOP-new.pdf',
      page: 1,
      chunkText: 'baru',
      x: 0.1,
      y: 0.2,
      w: 0.5,
      h: 0.3,
      embedding: List<double>.filled(kEmbeddingDimensions, 0.12),
    ));
    expect(chunks.getById('new1'), isNotNull);
    expect(chunks.getById('legacy1'), isNotNull);
  });
}
