#include "sqlite-vec.h"

/*
 * Trampoline untuk Dart: mengembalikan alamat sqlite3_vec_init yang ada di
 * dalam code asset ini, agar bisa didaftarkan sebagai sqlite auto-extension
 * lewat SqliteExtension(Pointer<Void>) tanpa perlu handle DynamicLibrary
 * (Dart tidak punya API untuk membuka native asset secara langsung).
 *
 * Dipakai hanya di macOS/iOS; Android/Linux/Windows membuka libvec0.so /
 * vec0.dll lewat DynamicLibrary.open.
 */
void *vec0_entry(void) {
  return (void *)sqlite3_vec_init;
}
