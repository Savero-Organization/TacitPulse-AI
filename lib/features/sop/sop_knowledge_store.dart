// sop_knowledge_store.dart — penyimpanan offline draft SOP final.
//
// Untuk tahap ini draft SOP disimpan sebagai baris di tabel `sop_drafts`
// (SQLite lokal, file database sama dengan knowledge_chunks). Integrasi
// embedding vektor (Knowledge Store vec0) menjadi pekerjaan lanjutan —
// kontrak simpan/baca sudah dipisah di sini agar UI tidak berubah.

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../../core/db/knowledge_chunks_store.dart'
    show initializeKnowledgeChunksDatabase;
import '../../core/sop/models/sop_draft_model.dart';

/// Abstraksi simpan agar bisa di-mock di widget test.
abstract class SopStore {
  Future<void> saveSop(SopDraftModel draft);
}

class SqliteSopStore implements SopStore {
  SqliteSopStore({this.dbPath});

  final String? dbPath;

  Future<sqlite3.Database> _open() async {
    // Samakan path default dengan initializeKnowledgeChunksDatabase supaya
    // draft SOP benar-benar hidup di knowledge store yang sama.
    final path = dbPath ??
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'knowledge_chunks.db',
        );
    return initializeKnowledgeChunksDatabase(path: path);
  }

  @override
  Future<void> saveSop(SopDraftModel draft) async {
    final db = await _open();
    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS sop_drafts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          payload TEXT NOT NULL,
          saved_at TEXT NOT NULL
        )''');
      // Upsert per judul: simpan ulang judul yang sama menggantikan baris
      // lama (menyimpan edit tanpa menduplikasi entri).
      db.execute('DELETE FROM sop_drafts WHERE title = ?', [draft.title]);
      db.execute(
        'INSERT INTO sop_drafts (title, payload, saved_at) VALUES (?, ?, ?)',
        [
          draft.title,
          jsonEncode(draft.toJson()),
          DateTime.now().toIso8601String(),
        ],
      );
    } finally {
      db.close();
    }
  }
}
