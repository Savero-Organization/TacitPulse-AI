import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_vec.dart';

/// Dimensi vektor embedding untuk knowledge chunks.
///
/// Skema vec0 butuh dimensi tetap saat CREATE. 384 dipakai sebagai default
/// (embedder ringan on-device seperti MiniLM / bge-small); ganti di sini bila
/// model embedding lain dipakai — cukup ubah konstanta ini.
const int kEmbeddingDimensions = 384;

/// Nama tabel vektor knowledge chunks.
const String kKnowledgeChunksTableName = 'knowledge_chunks';

/// Skema tabel `knowledge_chunks` (virtual table `vec0` dari sqlite-vec).
///
/// Kolom `embedding` adalah kolom vektor pencarian KNN (vec0) dengan metrik
/// `distance_metric=cosine`, sehingga kolom `distance` hasil query KNN berisi
/// jarak cosine similarity (bukan L2). Kolom metadata diawali `+` (konvensi
/// sqlite-vec) dan menyimpan atribut chunk sumber:
/// `id` (ID), `document_name` (nama dokumen), `page` (nomor halaman),
/// `chunk_text` (teks chunk), serta bounding box relatif `x`, `y`, `w`, `h`
/// pada halaman dokumen (0..1).
const String kKnowledgeChunksSchema = '''
CREATE VIRTUAL TABLE IF NOT EXISTS $kKnowledgeChunksTableName USING vec0(
  embedding float[$kEmbeddingDimensions] distance_metric=cosine,
  +id TEXT,
  +document_name TEXT,
  +page INTEGER,
  +chunk_text TEXT,
  +x double,
  +y double,
  +w double,
  +h double,
  +updated_at INTEGER
);
''';

/// Tabel tombstone untuk penghapusan chunk (dipakai delta synchronizer).
const String kKnowledgeChunksTombstoneSchema = '''
CREATE TABLE IF NOT EXISTS knowledge_chunk_tombstones(
  id TEXT,
  deleted_at INTEGER
);
''';

/// Indeks pada tombstone agar query Delta "deleted after T" tetap cepat.
const String kKnowledgeChunksTombstoneIndex = '''
CREATE INDEX IF NOT EXISTS idx_tombstones_deleted_at
ON knowledge_chunk_tombstones(deleted_at);
''';

/// Initialisasi database SQLite lokal untuk knowledge store vektor.
///
/// Membuka (membuat bila belum ada) database di direktori dokumen aplikasi
/// (atau [path] bila di-override untuk test), memasang ekstensi sqlite-vec,
/// lalu mengeksekusi skema [kKnowledgeChunksSchema] dan menyetel journal
/// mode WAL. Mengembalikan handle
/// [Database] yang siap dipakai; pemanggil bertanggung jawab menutupnya.
/// Bila eksekusi skema gagal, handle ditutup otomatis dan exception
/// diteruskan (tidak ada handle yang menggantung).
Future<Database> initializeKnowledgeChunksDatabase({String? path}) async {
  final dbPath = path ??
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'knowledge_chunks.db',
      );
  // openDatabaseWithVec menangani registrasi ekstensi sqlite-vec
  // (sqlite3_vec_init) sebelum koneksi dipakai.
  final db = openDatabaseWithVec(dbPath);
  try {
    db.execute(kKnowledgeChunksSchema);
    db.execute(kKnowledgeChunksTombstoneSchema);
    db.execute(kKnowledgeChunksTombstoneIndex);
    // Rows lama dari skema sebelum kolom updated_at ada butuh migrasi: coba
    // tambahkan kolomnya. Bila gagal (sqlite-vec tidak mendukung ALTER pada
    // beberapa versi), baris lama tetap tidak punya updated_at; itu aman —
    // mereka diabaikan oleh kueri delta (updated_at IS NULL).
    try {
      final cols =
          db.select("PRAGMA table_info($kKnowledgeChunksTableName)");
      final hasUpdatedAt = cols.any((r) => r['name'] == 'updated_at');
      if (!hasUpdatedAt) {
        db.execute(
          'ALTER TABLE $kKnowledgeChunksTableName ADD COLUMN updated_at INTEGER',
        );
      }
    } catch (_) {
      // Migrasi opsional; abaikan bila tidak didukung.
    }
    // Mode WAL: siap bila kelak ada koneksi/reader kedua (unlock paralelisme
    // reader-writer tanpa memblokir). Sekarang masih satu koneksi, jadi
    // murni persiapan — `synchronous=FULL` default tidak ikut berubah.
    db.execute('PRAGMA journal_mode=WAL');
    return db;
  } catch (_) {
    // Bila pembuatan skema gagal (mis. file korup), tutup handle agar fd
    // tidak bocor, lalu teruskan exception aslinya.
    db.close();
    rethrow;
  }
}