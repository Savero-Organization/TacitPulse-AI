import 'dart:ffi';

import 'package:sqlite3/sqlite3.dart';

/// Nama platform dari shared library sqlite-vec yang di-bundle (libvec0.so).
///
/// Build Android (externalNativeBuild CMake) dan Linux (linux/CMakeLists.txt)
/// menghasilkan `libvec0.so` dari amalgamasi yang di-vendor di
/// `android/app/src/main/cpp/vec0/`.
const String _vec0LibraryName = 'libvec0.so';

bool _vecExtensionLoaded = false;

/// Mendaftarkan ekstensi sqlite-vec (`vec0`) ke SQLite yang dipakai
/// `package:sqlite3` agar setiap koneksi database baru otomatis punya
/// kemampuan vector similarity search (virtual table `vec0`, fungsi
/// `vec_distance*`, dll).
///
/// Implementasi memakai `sqlite3_auto_extension`: simbol init
/// (`sqlite3_vec_init`) di-resolve dari library yang SUDAH di-load dan
/// pointer fungsinya diteruskan langsung ke SQLite — sehingga tidak bergantung
/// pada dlopen library sembarang saat runtime (aman untuk Android).
///
/// Aman dipanggil berulang kali; registrasi hanya terjadi sekali.
///
/// [libraryPath] dapat di-override untuk keperluan test/verifikasi
/// (mis. path absolut ke libvec0.so yang di-build manual).
void ensureSqliteVecLoaded({String? libraryPath}) {
  if (_vecExtensionLoaded) return;

  final library = DynamicLibrary.open(libraryPath ?? _vec0LibraryName);
  sqlite3.ensureExtensionLoaded(
    SqliteExtension.inLibrary(library, 'sqlite3_vec_init'),
  );
  _vecExtensionLoaded = true;
}

/// Membuka database SQLite lokal dengan ekstensi sqlite-vec terpasang.
///
/// Convenience: memanggil [ensureSqliteVecLoaded] lalu membuka [path].
/// URL `:memory:` didukung oleh package:sqlite3 untuk database in-memory.
Database openDatabaseWithVec(String path, {String? vecLibraryPath}) {
  ensureSqliteVecLoaded(libraryPath: vecLibraryPath);
  return sqlite3.open(path);
}