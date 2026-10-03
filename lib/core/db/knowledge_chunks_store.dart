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
    migrateKnowledgeChunksTable(db);
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

/// Migrasi skema lama `knowledge_chunks` (tanpa kolom `updated_at`) ke skema
/// baru.
///
/// sqlite-vec menolak `ALTER TABLE` pada tabel virtual `vec0`, jadi kolom
/// baru tidak bisa ditambahkan langsung. Yang ditempuh: membuat tabel vec0
/// baru berisi skema lengkap (dengan `updated_at`), menyalin seluruh baris
/// lama (backfill `updated_at = 0` sehingga baris tersebut diperlakukan
/// sebagai "terakhir disinkronkan sebelum era kolom"), menghapus tabel
/// lama, lalu rename tabel baru ke nama asli. Semua dalam satu transaksi —
/// gagal di mana pun, seluruh perubahan di-ROLLBACK dan exception diteruskan
/// (gagal cepat, tidak ada perbedaan diam-diam antara skema dan kueri).
void migrateKnowledgeChunksTable(Database db) {
  // Probe: bila `updated_at` sudah ada (fresh install atau sudah dimigrasi),
  // tidak ada yang perlu dilakukan.
  try {
    db.select('SELECT updated_at FROM $kKnowledgeChunksTableName LIMIT 1');
    return;
  } catch (_) {
    // Kolom belum ada → lanjutkan migrasi.
  }

  db.execute('BEGIN');
  try {
    db.execute('''
CREATE VIRTUAL TABLE ${kKnowledgeChunksTableName}__new USING vec0(
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
''');
    db.execute(
      'INSERT INTO ${kKnowledgeChunksTableName}__new '
      '(embedding, id, document_name, page, chunk_text, x, y, w, h, updated_at) '
      'SELECT embedding, id, document_name, page, chunk_text, x, y, w, h, 0 '
      'FROM $kKnowledgeChunksTableName',
    );
    db.execute('DROP TABLE $kKnowledgeChunksTableName');
    db.execute(
      'ALTER TABLE ${kKnowledgeChunksTableName}__new RENAME TO $kKnowledgeChunksTableName',
    );
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}