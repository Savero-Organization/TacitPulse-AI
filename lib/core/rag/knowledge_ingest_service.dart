// knowledge_ingest_service.dart — ingest dokumen Case 1 (bundled zip) ke
// index vektor `knowledge_chunks` (vec0) — satu-satunya sumber retrieval untuk
// chat (menggantikan korpus demo in-memory).
//
// Pipeline: zip di-asset -> unzip sekali ke documents -> per file:
//   PDF  -> PdfChunker (page-aware, bbox) -> chunk
//   xlsx/pptx/docx/png -> NativeExtractionLayer (ML Kit/XML) -> chunk
// Tiap chunk di-embed via [getEmbedding] (multilingual-e5-small, 384-dim) lalu
// di-`insert` ke KnowledgeChunksDb. Path sumber disimpan di tabel
// `document_sources` supaya citation bisa ditrack balik ke file + highlight.

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/knowledge_chunks_db.dart';
import '../native/llama_bridge.dart' show getEmbedding;
import '../utils/extraction.dart';
import '../utils/model_loader.dart';
import 'pdf_chunker.dart';

const String kKnowledgeBaseAsset =
    'assets/knowledge/case1_manufacturing_knowledge_hub.zip';

/// Flag SharedPreferences: index sudah di-seed untuk dataset versi ini.
const String kKnowledgeSeededV1Key = 'knowledge_base_seeded_v1';

/// Tabel pemetaan `document_name` (title chunk) -> path file sumber.
const String kDocumentSourcesTable = 'document_sources';

typedef Embedder = Future<List<double>> Function(String text);

class KnowledgeIngestService {
  KnowledgeIngestService({this.embedder});

  final Embedder? embedder;

  Future<List<double>> _embed(String text) async {
    if (embedder != null) return embedder!(text);
    return getEmbedding(text);
  }

  /// Pastikan direktori dataset di-extract + semua chunk sudah ter-index.
  /// Idempotent: hanya meng-embed bila belum pernah sukses. Mengembalikan
  /// jumlah chunk baru yang ter-insert.
  Future<int> ensureSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kKnowledgeSeededV1Key) == true) return 0;

    // Aktifkan embedding hanya bila memang perlu (index benar-benar kosong).
    final db = await KnowledgeChunksDb.open();
    try {
      db.db.execute('''
        CREATE TABLE IF NOT EXISTS $kDocumentSourcesTable (
          title TEXT PRIMARY KEY,
          source_path TEXT NOT NULL,
          media_type TEXT NOT NULL
        )''');
      // Bila user data di vec0 DB sudah ada, JANGAN re-init dari asset zip;
      // ini melindungi data user (dan menghindari ingest ulang tiap sync).
      try {
        final row = db.db.select('SELECT COUNT(*) AS c FROM knowledge_chunks').single;
        final count = (row['c'] as num?)?.toInt() ?? 0;
        if (count > 0) {
          await prefs.setBool(kKnowledgeSeededV1Key, true);
          return 0;
        }
      } catch (_) {
        // Tabel mungkin belum ada di skenario awal — lanjutkan seeding.
      }

      final rootDir = await _ensureExtracted();
      if (rootDir == null) return 0;

      await ModelManager.ensureEmbeddingModel();
      final ready = await ModelManager.ensureEmbeddingModelReady();
      if (!ready) return 0;

      var inserted = 0;
      await for (final file in _walk(rootDir)) {
        inserted += await _ingestFile(db, file);
      }
      await prefs.setBool(kKnowledgeSeededV1Key, true);
      return inserted;
    } finally {
      db.close();
    }
  }

  /// Ambil daftar dokumen yang sudah ter-ingest di knowledge store.
  ///
  /// Dipakai untuk memuat `KNOWLEDGE BASE` sidebar di Chat saat launch dan
  /// untuk menyegarkan sidebar pasca-import, tanpa bergantung pada state
  /// in-memory.
  Future<List<({String title, String sourcePath, String mediaType})>>
      listStoredDocuments() async {
    final db = await KnowledgeChunksDb.open();
    try {
      db.db.execute('''
        CREATE TABLE IF NOT EXISTS $kDocumentSourcesTable (
          title TEXT PRIMARY KEY,
          source_path TEXT NOT NULL,
          media_type TEXT NOT NULL
        )''');
      final rows = db.db.select(
        'SELECT title, source_path, media_type FROM $kDocumentSourcesTable '
        'ORDER BY rowid DESC',
      );
      return rows
          .map(
            (row) => (
              title: row['title'] as String,
              sourcePath: row['source_path'] as String,
              mediaType: row['media_type'] as String,
            ),
          )
          .toList();
    } finally {
      db.close();
    }
  }

  /// Ingest satu file dokumen ke `knowledge_chunks` + tabel `document_sources`
  /// (dipakai saat user import dokumen baru lewat file picker). Mengembalikan
  /// jumlah chunk baru.
  Future<int> ingestPath(String path) async {
    // Pastikan model embedding ada; unduh sekali bila belum (progress status
    // bar). Pada jalan pertama ini ingest tetap ditunggu agar tidak crash di
    // embedding bridge saat file masih kosong.
    final embedPath = await ModelManager.ensureEmbeddingModel();
    if (embedPath == null) {
      throw StateError(
        'Gagal mengunduh model embedding multilingual-e5-small; coba lagi.',
      );
    }
    final db = await KnowledgeChunksDb.open();
    try {
      db.db.execute('''
        CREATE TABLE IF NOT EXISTS $kDocumentSourcesTable (
          title TEXT PRIMARY KEY,
          source_path TEXT NOT NULL,
          media_type TEXT NOT NULL
        )''');
      return await _ingestFile(db, File(path));
    } finally {
      db.close();
    }
  }

  Future<Directory?> _ensureExtracted() async {
    final docs = await getApplicationDocumentsDirectory();
    final out = Directory(p.join(docs.path, 'knowledge_base'));
    if (out.existsSync() && out.listSync().isNotEmpty) return out;
    try {
      final data = await rootBundle.load(kKnowledgeBaseAsset);
      final archive = ZipDecoder().decodeBytes(data.buffer.asUint8List());
      for (final entry in archive) {
        final path = p.join(out.path, entry.name);
        if (entry.isFile) {
          File(path)
            ..createSync(recursive: true)
            ..writeAsBytesSync(entry.content as List<int>);
        } else {
          Directory(path).createSync(recursive: true);
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Stream<File> _walk(Directory root) async* {
    for (final entity in root.listSync(recursive: true)) {
      if (entity is File) yield entity;
    }
  }

  Future<int> _ingestFile(KnowledgeChunksDb db, File file) async {
    final path = file.path;
    final type = detectDocumentType(path);
    if (type == DocumentType.unknown) return 0;
    final title = p.basenameWithoutExtension(path);
    db.db.execute(
      'INSERT OR REPLACE INTO $kDocumentSourcesTable (title, source_path, media_type) VALUES (?, ?, ?)',
      [title, path, type.name],
    );

    if (type == DocumentType.pdf) {
      var count = 0;
      for (final chunk in await _pdfChunks(file)) {
        await _insertChunk(
          db,
          title,
          page: chunk.page + 1, // PdfChunk.page 0-based -> tampil 1-based
          text: chunk.text,
          x: chunk.boundingBox.left,
          y: chunk.boundingBox.top,
          w: chunk.boundingBox.width,
          h: chunk.boundingBox.height,
        );
        count++;
      }
      return count;
    }

    final text = (await const NativeExtractionLayer().extract(path)).text.trim();
    if (text.isEmpty) return 0;
    var count = 0;
    for (final piece in _splitPlainText(text)) {
      await _insertChunk(db, title, page: 1, text: piece);
      count++;
    }
    return count;
  }

  Future<List<PdfChunk>> _pdfChunks(File file) async {
    try {
      final lines = parsePdfLines(await file.readAsBytes());
      return const PdfChunker().chunk(lines);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _insertChunk(
    KnowledgeChunksDb db,
    String title, {
    required int page,
    required String text,
    double x = 0,
    double y = 0,
    double w = 1,
    double h = 1,
  }) async {
    final embedding = await _embed(text);
    db.insert(
      KnowledgeChunkRecord(
        id: '${title.hashCode}-$page-${text.hashCode}',
        documentName: title,
        page: page,
        chunkText: text,
        x: x.clamp(0, 1).toDouble(),
        y: y.clamp(0, 1).toDouble(),
        w: w.clamp(0, 1).toDouble(),
        h: h.clamp(0, 1).toDouble(),
        embedding: embedding,
      ),
    );
  }

  Iterable<String> _splitPlainText(String text) sync* {
    const maxChars = 1200;
    final buf = StringBuffer();
    for (final line in text.split('\n')) {
      if (buf.length + line.length + 1 > maxChars && buf.isNotEmpty) {
        yield buf.toString();
        buf.clear();
      }
      buf.writeln(line);
    }
    if (buf.isNotEmpty) yield buf.toString();
  }
}
