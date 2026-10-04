// document_source_resolver.dart — mapping `document_name` (title) tabel
// `knowledge_chunks` -> path file sumber (dari tabel `document_sources`),
// supaya SourceCitation bisa dibuka di viewer PDF.

import 'dart:io';

import '../db/knowledge_chunks_db.dart';
import 'knowledge_ingest_service.dart' show kDocumentSourcesTable;

class DocumentSourceResolver {
  DocumentSourceResolver({this.dbPath});

  final String? dbPath;

  /// Mengembalikan path file untuk [title], atau `null` bila tidak ada /
  /// file sudah tidak ada di disk.
  Future<String?> sourcePathForTitle(String title) async {
    final db = await KnowledgeChunksDb.open(path: dbPath);
    try {
      final rows = db.db.select(
        'SELECT source_path FROM $kDocumentSourcesTable WHERE title = ? LIMIT 1',
        [title],
      );
      if (rows.isEmpty) return null;
      final sourcePath = rows.first['source_path'] as String;
      try {
        return File(sourcePath).existsSync() ? sourcePath : null;
      } catch (_) {
        return null;
      }
    } finally {
      db.close();
    }
  }
}
