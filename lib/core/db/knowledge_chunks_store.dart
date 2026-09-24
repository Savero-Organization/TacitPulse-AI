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
/// Kolom `embedding` adalah kolom vektor pencarian KNN (vec0). Kolom metadata
/// diawali `+` (konvensi sqlite-vec) dan menyimpan atribut chunk sumber:
/// `id` (ID), `document_name` (nama dokumen), `page` (nomor halaman),
/// `chunk_text` (teks chunk), serta bounding box relatif `x`, `y`, `w`, `h`
/// pada halaman dokumen (0..1).
const String kKnowledgeChunksSchema = '''
CREATE VIRTUAL TABLE IF NOT EXISTS $kKnowledgeChunksTableName USING vec0(
  embedding float[$kEmbeddingDimensions],
  +id TEXT,
  +document_name TEXT,
  +page INTEGER,
  +chunk_text TEXT,
  +x double,
  +y double,
  +w double,
  +h double
);
''';

/// Initialisasi database SQLite lokal untuk knowledge store vektor.
///
/// Membuka (membuat bila belum ada) database di direktori dokumen aplikasi
/// (atau [path] bila di-override untuk test), memasang ekstensi sqlite-vec,
/// lalu mengeksekusi skema [kKnowledgeChunksSchema]. Mengembalikan handle
/// [Database] yang siap dipakai; pemanggil bertanggung jawab menutupnya.
Future<Database> initializeKnowledgeChunksDatabase({String? path}) async {
  final dbPath = path ??
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'knowledge_chunks.db',
      );
  // openDatabaseWithVec menangani registrasi ekstensi sqlite-vec
  // (sqlite3_vec_init) sebelum koneksi dipakai.
  final db = openDatabaseWithVec(dbPath);
  db.execute(kKnowledgeChunksSchema);
  return db;
}