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
  ///
  /// Melempar [ArgumentError] bila `id` kosong atau koordinat bbox di luar
  /// rentang 0..1, dan [StateError] bila `id` sudah dipakai chunk lain
  /// (tabel tidak punya UNIQUE, jadi dicek dulu — selain itu `getById`
  /// akan gagal saat ada duplikat).
  void insert(KnowledgeChunkRecord chunk) {
    _validateId(chunk.id, 'chunk.id');
    _validateBounds(chunk.x, 'chunk.x');
    _validateBounds(chunk.y, 'chunk.y');
    _validateBounds(chunk.w, 'chunk.w');
    _validateBounds(chunk.h, 'chunk.h');
    final duplicate = _db.select(
      'SELECT 1 FROM $kKnowledgeChunksTableName WHERE id = ?',
      [chunk.id],
    );
    if (duplicate.isNotEmpty) {
      throw StateError(
        'ID chunk "${chunk.id}" sudah ada; hapus atau update dulu.',
      );
    }
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
  ///
  /// Melempar [ArgumentError] bila `id` kosong.
  KnowledgeChunkRecord? getById(String id) {
    _validateId(id, 'id');
    final rows = _db.select(
      'SELECT $_columns FROM $kKnowledgeChunksTableName WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _toRecord(rows.single);
  }

  /// Mengambil semua chunk, urut berdasarkan urutan insert (rowid).
  ///
  /// Peringatan: memuat seluruh tabel ke memori sekaligus. Untuk korpus
  /// besar (mis. deployment client dengan banyak dokumen), pertimbangkan
  /// pagination (limit/offset) sebelum dipakai di loop/UI.
  List<KnowledgeChunkRecord> list() {
    return _db
        .select('SELECT $_columns FROM $kKnowledgeChunksTableName '
            'ORDER BY rowid')
        .map(_toRecord)
        .toList();
  }

  /// Memperbarui seluruh kolom chunk (dikenali lewat `id`).
  ///
  /// Melempar [ArgumentError] bila `id` kosong atau koordinat bbox di luar
  /// rentang 0..1, dan [StateError] bila tidak ada chunk dengan `id`
  /// tersebut — agar edit yang tidak mendarat tidak gagal diam-diam (silent
  /// data loss).
  void update(KnowledgeChunkRecord chunk) {
    _validateId(chunk.id, 'chunk.id');
    _validateBounds(chunk.x, 'chunk.x');
    _validateBounds(chunk.y, 'chunk.y');
    _validateBounds(chunk.w, 'chunk.w');
    _validateBounds(chunk.h, 'chunk.h');
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
    if (_db.updatedRows == 0) {
      throw StateError(
        'Tidak ada chunk dengan id "${chunk.id}" untuk diupdate.',
      );
    }
  }

  /// Menghapus satu chunk berdasarkan ID.
  ///
  /// Mengembalikan `true` bila ada baris yang terhapus, `false` bila `id`
  /// tidak ditemukan — ID tak dikenal tidak dianggap error agar penghapusan
  /// tetap idempotent (aman dipanggil berulang pada loop reindex/retry).
  /// Melempar [ArgumentError] bila `id` kosong.
  bool delete(String id) {
    _validateId(id, 'id');
    _db.execute(
      'DELETE FROM $kKnowledgeChunksTableName WHERE id = ?',
      [id],
    );
    return _db.updatedRows > 0;
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

  // ---- Validasi ------------------------------------------------------------

  static void _validateId(String id, String name) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, name, 'ID tidak boleh kosong.');
    }
  }

  /// Validasi koordinat bounding box relatif halaman (kontrak skema 0..1,
  /// lihat [kKnowledgeChunksSchema]).
  ///
  /// Bentuk negasi dipakai agar NaN ikut tertolak — NaN lolos dari
  /// perbandingan `<` atau `>` biasa padahal jelas di luar rentang.
  static void _validateBounds(double value, String name) {
    if (!(value >= 0.0 && value <= 1.0)) {
      throw ArgumentError.value(
        value,
        name,
        'Nilai harus dalam rentang 0..1 (relatif halaman).',
      );
    }
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

  /// Blob hasil `SELECT embedding` → `List<double>` ([kEmbeddingDimensions]
  /// dimensi).
  ///
  /// Melempar [StateError] bila ukuran blob tidak persis
  /// `kEmbeddingDimensions * 4` byte — tanda data korup, ada byte sisa
  /// (padding), atau tabel dibuat dengan dimensi skema yang berbeda.
  static List<double> _decodeVector(Uint8List blob) {
    if (blob.length != kEmbeddingDimensions * 4) {
      throw StateError(
        'Blob embedding tidak sesuai skema: ${blob.length} byte, '
        'harus ${kEmbeddingDimensions * 4} byte '
        '($kEmbeddingDimensions dimensi) — data korup atau tabel dibuat '
        'dengan dimensi berbeda.',
      );
    }
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