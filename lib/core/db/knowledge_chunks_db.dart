import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'knowledge_chunks_store.dart';

/// Satu baris tabel `knowledge_chunks` (skema di [kKnowledgeChunksSchema]).
class KnowledgeChunkRecord {
  const KnowledgeChunkRecord({
    required this.id,
    required this.documentName,
    required this.page,
    required this.chunkText,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.embedding,
    this.distance,
  });

  final String id;
  final String documentName;
  final int page;
  final String chunkText;

  /// Bounding box relatif (0..1) pada halaman dokumen.
  final double x;
  final double y;
  final double w;
  final double h;

  /// Vektor embedding chunk (panjang [kEmbeddingDimensions]).
  final List<double> embedding;

  /// Jarak cosine (0 = identik, makin kecil makin mirip).
  /// Hanya terisi pada hasil [KnowledgeChunksDb.search] (query KNN).
  final double? distance;
}

/// Helper SQLite untuk operasi CRUD chunk + pencarian kemiripan
/// (KNN / cosine similarity) di atas tabel vektor `knowledge_chunks`.
class KnowledgeChunksDb {
  KnowledgeChunksDb(this._db);

  /// Koneksi SQLite (dari `initializeKnowledgeChunksDatabase` atau
  /// `openDatabaseWithVec`) — skema vec0 sudah terpasang.
  final Database _db;

  static const String _columns =
      'id, document_name, page, chunk_text, x, y, w, h, embedding';

  /// Membuka database dokumen aplikasi (membuat bila belum ada), memasang
  /// sqlite-vec + skema, lalu mengembalikan helper siap pakai.
  static Future<KnowledgeChunksDb> open({String? path}) async {
    final db = await initializeKnowledgeChunksDatabase(path: path);
    return KnowledgeChunksDb(db);
  }

  /// Menutup koneksi database. Helper tidak boleh dipakai lagi setelah ini.
  void close() => _db.dispose();

  // ---- CRUD --------------------------------------------------------------

  /// Menyisipkan satu chunk baru (embedding di-encode ke blob float32
  /// via `vec_f32(?)`, format yang dibutuhkan kolom vektor vec0).
  void insert(KnowledgeChunkRecord chunk) {
    _db.execute(
      'INSERT INTO $kKnowledgeChunksTableName '
      '(embedding, id, document_name, page, chunk_text, x, y, w, h) '
      'VALUES (vec_f32(?), ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        _encodeVector(chunk.embedding),
        chunk.id,
        chunk.documentName,
        chunk.page,
        chunk.chunkText,
        chunk.x,
        chunk.y,
        chunk.w,
        chunk.h,
      ],
    );
  }

  /// Mengambil satu chunk berdasarkan ID, atau `null` bila tidak ada.
  KnowledgeChunkRecord? getById(String id) {
    final rows = _db.select(
      'SELECT $_columns FROM $kKnowledgeChunksTableName WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _toRecord(rows.single);
  }

  /// Mengambil semua chunk, urut berdasarkan urutan insert (rowid).
  List<KnowledgeChunkRecord> list() {
    return _db
        .select('SELECT $_columns FROM $kKnowledgeChunksTableName '
            'ORDER BY rowid')
        .map(_toRecord)
        .toList();
  }

  /// Memperbarui seluruh kolom chunk (dikenali lewat `id`).
  void update(KnowledgeChunkRecord chunk) {
    _db.execute(
      'UPDATE $kKnowledgeChunksTableName '
      'SET embedding = vec_f32(?), document_name = ?, page = ?, '
      'chunk_text = ?, x = ?, y = ?, w = ?, h = ? '
      'WHERE id = ?',
      [
        _encodeVector(chunk.embedding),
        chunk.documentName,
        chunk.page,
        chunk.chunkText,
        chunk.x,
        chunk.y,
        chunk.w,
        chunk.h,
        chunk.id,
      ],
    );
  }

  /// Menghapus satu chunk berdasarkan ID.
  void delete(String id) {
    _db.execute(
      'DELETE FROM $kKnowledgeChunksTableName WHERE id = ?',
      [id],
    );
  }

  // ---- Pencarian kemiripan ------------------------------------------------

  /// KNN search (cosine similarity) — mengembalikan [k] chunk paling mirip
  /// dengan [queryEmbedding], terurut dari jarak cosine terkecil.
  ///
  /// Skema tabel memakai `distance_metric=cosine`, sehingga `distance` yang
  /// dikembalikan adalah jarak cosine (1 - cosine similarity).
  List<KnowledgeChunkRecord> search(
    List<double> queryEmbedding, {
    int k = 10,
  }) {
    return _db
        .select(
          'SELECT $_columns, distance '
          'FROM $kKnowledgeChunksTableName '
          'WHERE embedding MATCH vec_f32(?) AND k = ? '
          'ORDER BY distance',
          [_encodeVector(queryEmbedding), k],
        )
        .map(_toRecord)
        .toList();
  }

  // ---- Konversi vektor -----------------------------------------------------

  /// `List<double>` → blob float32 LE (1536 byte utk 384 dimensi),
  /// parameter yang diterima `vec_f32()` untuk kolom vektor vec0.
  static Uint8List _encodeVector(List<double> vector) {
    if (vector.length != kEmbeddingDimensions) {
      throw ArgumentError.value(
        vector.length,
        'vector',
        'Dimensi embedding harus $kEmbeddingDimensions '
        '(sesuai skema), bukan ${vector.length}.',
      );
    }
    return Float32List.fromList(vector).buffer.asUint8List();
  }

  /// Blob hasil `SELECT embedding` → `List<double>`.
  static List<double> _decodeVector(Uint8List blob) {
    final data = ByteData.sublistView(Uint8List.fromList(blob));
    return Float32List.view(
      data.buffer,
      data.offsetInBytes,
      data.lengthInBytes ~/ 4,
    ).toList();
  }

  static KnowledgeChunkRecord _toRecord(Row row) {
    final distance = row['distance'];
    return KnowledgeChunkRecord(
      id: row['id'] as String,
      documentName: row['document_name'] as String,
      page: row['page'] as int,
      chunkText: row['chunk_text'] as String,
      x: (row['x'] as num).toDouble(),
      y: (row['y'] as num).toDouble(),
      w: (row['w'] as num).toDouble(),
      h: (row['h'] as num).toDouble(),
      embedding: _decodeVector(row['embedding'] as Uint8List),
      distance: distance == null ? null : (distance as num).toDouble(),
    );
  }
}