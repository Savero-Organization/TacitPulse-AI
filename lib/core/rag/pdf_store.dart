import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:sqlite3/sqlite3.dart';

import 'pdf_chunker.dart';

/// Toko vektor PDF lokal berbasis SQLite (`package:sqlite3`).
///
/// Skema ringkas (satu file DB):
/// - `pdf_docs`   : satu baris per PDF yang diimpor (menyimpan path berkas
///                  sumber agar penampil PDF GABUT-25 bisa membukanya lagi).
/// - `pdf_chunks` : satu baris per chunk: teks + halaman + bbox ternormalisasi
///                  + embedding float32.
///
/// BLOB embedding disimpan mentah (float32 little-endian, L2-normalized sesuai
/// kontrak `getEmbedding` dari GABUT-22) — skor cosine/dot product dihitung
/// belakangan di Dart atas kandidat hasil filter `doc_id`/`page`. Tidak ada
/// vector DB di sini (YAGNI).
class PdfStore {
  PdfStore(String dbPath) : db = sqlite3.open(dbPath) {
    db.execute(schema);
  }

  /// Koneksi terbuka; dipublikasikan agar langkah retrieval (cosine scan di
  /// Dart) bisa query langsung tanpa API tambahan.
  final Database db;

  static const String schema = '''
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS pdf_docs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  source_path TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pdf_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  doc_id INTEGER NOT NULL REFERENCES pdf_docs(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  page INTEGER NOT NULL,
  bbox TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB NOT NULL,
  created_at INTEGER NOT NULL
);

-- Akses per-dokumen/halaman (mis. sorot bbox saat sitasi diklik).
CREATE INDEX IF NOT EXISTS idx_pdf_chunks_doc_page ON pdf_chunks(doc_id, page);
''';

  /// Simpan satu PDF beserta seluruh chunk + embeddignya dalam satu transaksi.
  /// [embeddings] harus sepanjang [chunks] (urutan sama).
  /// Mengembalikan id dokumen.
  int saveDoc({
    required String title,
    required String sourcePath,
    required List<PdfChunk> chunks,
    required List<List<double>> embeddings,
  }) {
    if (chunks.length != embeddings.length) {
      throw ArgumentError(
        'chunks (${chunks.length}) dan embeddings (${embeddings.length}) '
        'harus sejumlah',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute('BEGIN');
    try {
      db.execute(
        'INSERT INTO pdf_docs (title, source_path, created_at) '
        'VALUES (?, ?, ?)',
        [title, sourcePath, now],
      );
      final docId = db.lastInsertRowId;
      final insert = db.prepare(
        'INSERT INTO pdf_chunks '
        '(doc_id, title, page, bbox, text, embedding, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
      );
      try {
        for (var i = 0; i < chunks.length; i++) {
          final chunk = chunks[i];
          insert.execute([
            docId,
            title,
            chunk.page,
            encodeBbox(chunk.boundingBox),
            chunk.text,
            encodeFloat32(embeddings[i]),
            now,
          ]);
        }
      } finally {
        insert.close();
      }
      db.execute('COMMIT');
      return docId;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Resolusi id sitasi / id dokumen → path PDF sumber.
  /// Mengenali `doc-<id>`, `chunk-<id>`, angka telanjang (dulu dokumen, lalu
  /// chunk), atau judul dokumen. Bernilai null bila tidak ditemukan.
  String? docPathFor(String citationIdOrDocId) {
    final raw = citationIdOrDocId.trim();
    if (raw.isEmpty) return null;

    final docIds = <int>[];
    final chunkIds = <int>[];
    if (raw.startsWith('doc-')) {
      final id = int.tryParse(raw.substring(4));
      if (id != null) docIds.add(id);
    } else if (raw.startsWith('chunk-')) {
      final id = int.tryParse(raw.substring(6));
      if (id != null) chunkIds.add(id);
    } else {
      final id = int.tryParse(raw);
      if (id != null) {
        docIds.add(id);
        chunkIds.add(id);
      }
    }

    for (final id in docIds) {
      final rows = db.select(
        'SELECT source_path FROM pdf_docs WHERE id = ? LIMIT 1',
        [id],
      );
      if (rows.isNotEmpty) return rows.first['source_path'] as String;
    }
    for (final id in chunkIds) {
      final rows = db.select(
        'SELECT d.source_path FROM pdf_chunks c '
        'JOIN pdf_docs d ON d.id = c.doc_id '
        'WHERE c.id = ? LIMIT 1',
        [id],
      );
      if (rows.isNotEmpty) return rows.first['source_path'] as String;
    }

    final byTitle = db.select(
      'SELECT source_path FROM pdf_docs WHERE title = ? LIMIT 1',
      [raw],
    );
    if (byTitle.isNotEmpty) return byTitle.first['source_path'] as String;
    return null;
  }

  void close() => db.close();
}

/// Bbox ternormalisasi (0..1) ↔ string penyimpanan `"left,top,width,height"`.
String encodeBbox(Rect box) =>
    '${box.left},${box.top},${box.width},${box.height}';

Rect decodeBbox(String value) {
  final parts = value.split(',');
  if (parts.length != 4) {
    throw FormatException('bbox tidak valid: $value');
  }
  final nums = [for (final p in parts) double.tryParse(p.trim())];
  if (nums.any((n) => n == null)) {
    throw FormatException('bbox tidak valid: $value');
  }
  return Rect.fromLTWH(nums[0]!, nums[1]!, nums[2]!, nums[3]!);
}

/// Embedding float32 little-endian ↔ BLOB. Ukuran selalu kelipatan 4 byte.
Uint8List encodeFloat32(List<double> values) {
  final data = Float32List(values.length);
  for (var i = 0; i < values.length; i++) {
    data[i] = values[i];
  }
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

List<double> decodeFloat32(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final view = ByteData.sublistView(data);
  return [
    for (var i = 0; i + 4 <= view.lengthInBytes; i += 4)
      view.getFloat32(i, Endian.little),
  ];
}
