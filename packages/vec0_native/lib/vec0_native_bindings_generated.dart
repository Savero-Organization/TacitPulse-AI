// Binding tangan (satu fungsi) untuk trampoline di src/vec0_entry.c —
// tidak pakai ffigen karena tidak ada header C yang di-generate.
import 'dart:ffi' as ffi;

/// Mengembalikan alamat `sqlite3_vec_init` dari code asset yang dibangun
/// oleh `hook/build.dart`.
///
/// Pemanggilan pertama memaksa VM me-load code asset paket ini; VM
/// me-resolve `@Native` terhadap asset tersebut secara otomatis, jadi tidak
/// ada logika dlopen per-platform di sini.
@ffi.Native<ffi.Pointer<ffi.Void> Function()>(symbol: 'vec0_entry')
external ffi.Pointer<ffi.Void> vec0Entrypoint();
