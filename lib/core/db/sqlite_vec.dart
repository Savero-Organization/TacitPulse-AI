import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:sqlite3/sqlite3.dart';
import 'package:vec0_native/vec0_native.dart' show vec0Entrypoint;

/// Nama shared library sqlite-vec per platform dari build CMake aplikasi,
/// atau `null` bila platform memakai code asset (native assets).
///
/// - Android & Linux: `libvec0.so` (externalNativeBuild CMake di Android,
///   linux/CMakeLists.txt) dari amalgamasi yang di-vendor di
///   `android/app/src/main/cpp/vec0/`.
/// - Windows: `vec0.dll` dari windows/CMakeLists.txt, terpasang satu
///   direktori dengan executable.
/// - macOS & iOS: tidak ada library terpisah — vec0 di-bundle sebagai code
///   asset oleh paket `vec0_native` dan di-resolve VM otomatis.
String? _vec0LibraryName() {
  if (Platform.isAndroid || Platform.isLinux) return 'libvec0.so';
  if (Platform.isWindows) return 'vec0.dll';
  return null;
}

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
/// Di macOS/iOS tidak ada library yang di-load manual: trampoline `@Native`
/// milik `vec0_native` me-load code asset sekaligus mengembalikan alamat
/// `sqlite3_vec_init` sebagai pointer mentah.
///
/// Aman dipanggil berulang kali; registrasi hanya terjadi sekali.
///
/// [libraryPath] dapat di-override untuk keperluan test/verifikasi
/// (mis. path absolut ke libvec0.so yang di-build manual).
void ensureSqliteVecLoaded({String? libraryPath}) {
  if (_vecExtensionLoaded) return;

  final path = libraryPath ?? _vec0LibraryName();
  if (path != null) {
    final library = DynamicLibrary.open(path);
    sqlite3.ensureExtensionLoaded(
      SqliteExtension.inLibrary(library, 'sqlite3_vec_init'),
    );
  } else {
    sqlite3.ensureExtensionLoaded(SqliteExtension(vec0Entrypoint()));
  }
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
