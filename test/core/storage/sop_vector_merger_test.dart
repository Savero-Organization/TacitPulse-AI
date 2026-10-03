import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_db.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_store.dart';
import 'package:tacit_pulse_ai/core/db/sqlite_vec.dart';
import 'package:tacit_pulse_ai/core/storage/sop_vector_merger.dart';

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
  required List<double> embedding,
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
    embedding: embedding,
    updatedAt: updatedAt,
  );
}

/// Bytes float32 LE yang dipakai sebagai kolom embedding (format blob vec0).
Uint8List _vectorBytes(List<double> v) =>
    Float32List.fromList(v).buffer.asUint8List();

List<double> _uniform(double value) =>
    List<double>.filled(kEmbeddingDimensions, value);

/// Versi float32-rounded dari vektor — nilai yang actually tersimpan di BLOB.
List<double> _f(List<double> v) => Float32List.fromList(v).toList();

void main() {
  final vec0Path = _resolveVec0Library();
  final skip = vec0Path == null ? 'libvec0.so tidak ada' : false;

  late Database db;
  late KnowledgeChunksDb chunks;
  late SopVectorMerger merger;

  setUp(() {
    db = openDatabaseWithVec(':memory:', vecLibraryPath: vec0Path);
    db.execute(kKnowledgeChunksSchema);
    db.execute(kKnowledgeChunksTombstoneSchema);
    db.execute(kKnowledgeChunksTombstoneIndex);
    chunks = KnowledgeChunksDb(db);
    merger = SopVectorMerger(chunks);
  });

  tearDown(() => db.close());

  test('LWW: remote baru menimpa lokal, remote lama di-skip', skip: skip,
      () {
    final t0 = DateTime.utc(2026, 1, 1, 12);
    final t1 = t0.add(const Duration(hours: 1));
    final t2 = t0.add(const Duration(hours: 2));

    chunks.insert(_chunk('u', updatedAt: t0, embedding: _uniform(0.1)));
    chunks.insert(_chunk('s', updatedAt: t2, embedding: _uniform(0.2)));

    // Remote: 'u' lebih baru (t1 > t0) → update; 's' lebih lama (t0 < t2)
    // → skip; 'n' belum ada → insert.
    final result = merger.merge([
      _chunk('u', updatedAt: t1, embedding: _uniform(0.9)),
      _chunk('s', updatedAt: t0, embedding: _uniform(0.7)),
      _chunk('n', updatedAt: t1, embedding: _uniform(0.5)),
    ]);

    expect(result.inserted, 1);
    expect(result.updated, 1);
    expect(result.skipped, 1);

    final u = chunks.getById('u')!;
    expect(u.updatedAt.millisecondsSinceEpoch, t1.millisecondsSinceEpoch);
    expect(u.embedding, _f(_uniform(0.9)));

    final s = chunks.getById('s')!;
    expect(s.updatedAt.millisecondsSinceEpoch, t2.millisecondsSinceEpoch); // tetap versi baru lokal
    expect(s.embedding, _f(_uniform(0.2)));

    expect(chunks.getById('n'), isNotNull);
  });

  test('timestamp sama: lokal dipertahankan (bukan strict greater)', skip: skip,
      () {
    final t0 = DateTime.utc(2026, 1, 1, 12);
    chunks.insert(_chunk('tie', updatedAt: t0, embedding: _uniform(0.3)));

    final result = merger.merge([
      _chunk('tie', updatedAt: t0, embedding: _uniform(0.8)),
    ]);
    expect(result.skipped, 1);
    expect(chunks.getById('tie')!.embedding, _f(_uniform(0.3)));
  });

  test('embedding BLOB identik sebelum & sesudah merge', skip: skip, () {
    final t0 = DateTime.utc(2026, 1, 1, 12);
    final localEmb = _uniform(0.11);
    chunks.insert(_chunk('keep', updatedAt: t0, embedding: localEmb));

    // Tombol byte sebelum merge (harus tetap sama setelah merge chunk lain).
    final beforeBlob = (db.select(
      'SELECT embedding FROM knowledge_chunks WHERE id = ?',
      ['keep'],
    )).first['embedding'] as Uint8List;

    merger.merge([
      _chunk('other', updatedAt: t0, embedding: _uniform(0.4)),
    ]);

    final afterBlob = (db.select(
      'SELECT embedding FROM knowledge_chunks WHERE id = ?',
      ['keep'],
    )).first['embedding'] as Uint8List;

    expect(afterBlob, beforeBlob);
    expect(beforeBlob, _vectorBytes(localEmb));
  });

  test('rollback bila satu chunk gagal validasi (atomik)', skip: skip, () {
    final t0 = DateTime.utc(2026, 1, 1, 12);

    // Chunk kedua melempar ArgumentError (x negatif) setelah chunk pertama
    // sukses insert — seluruh transaksi harus dibatalkan.
    expect(
      () => merger.merge([
        _chunk('ok', updatedAt: t0, embedding: _uniform(0.1)),
        KnowledgeChunkRecord(
          id: 'bad',
          documentName: 'SOP-bad.pdf',
          page: 1,
          chunkText: 'x',
          x: -0.5, // di luar rentang → ArgumentError saat insert
          y: 0.2,
          w: 0.5,
          h: 0.3,
          embedding: _uniform(0.1),
          updatedAt: t0,
        ),
      ]),
      throwsA(isA<ArgumentError>()),
    );

    // 'ok' tidak boleh tersisa di DB (transaksi rollback).
    expect(chunks.getById('ok'), isNull);
    expect(chunks.getById('bad'), isNull);
  });
}