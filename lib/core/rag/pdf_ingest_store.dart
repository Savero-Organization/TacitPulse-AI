import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pdf_chunker.dart';
import 'pdf_store.dart';

/// Kontrak embedder (lihat kontrak GABUT-22: `getEmbedding`, L2-normalized,
/// 384 dim). Sengaja berupa typedef agar lapisan ini TIDAK mengimpor bridge
/// native GABUT-22 secara langsung — PR #5 bisa diuji dengan mock tanpa
/// menunggu `lib/core/native/llama_bridge.dart` ada.
typedef PdfEmbedder = Future<List<double>> Function(String text);

/// Pembuat store. Disuntikkan agar unit test bisa memakai SQLite temp tanpa
/// `path_provider` (platform channel tidak tersedia di unit test).
typedef PdfStoreFactory = Future<PdfStore> Function();

PdfEmbedder? _embedder;
PdfStoreFactory? _storeFactoryOverride;

/// Pasang embedder produksi. WAJIB dipanggil oleh composition root sebelum
/// [ingestPdf] dipakai, contoh:
/// ```dart
/// import 'core/native/llama_bridge.dart';
/// installEmbedder(getEmbedding); // GABUT-22, sudah L2-normalized
/// ```
///
/// TODO(GABUT-22): tambahkan baris di atas pada composition root saat branch
/// embedding merge. Sebelum dipanggil, [ingestPdf] melempar [StateError]
/// dengan pesan yang jelas (bukan gagal diam-diam).
void installEmbedder(PdfEmbedder embedder) => _embedder = embedder;

/// Suntik store temp untuk test (mis. SQLite di `Directory.systemTemp`).
@visibleForTesting
void debugSetStoreFactory(PdfStoreFactory? factory) {
  _storeFactoryOverride = factory;
  _storeFuture = null;
}

/// Kembalikan seluruh override ke kondisi produksi. Juga membuang store yang
/// di-cache agar tidak ada koneksi ke file temp yang sudah dihapus test.
@visibleForTesting
void debugResetRagOverrides() {
  _embedder = null;
  _storeFactoryOverride = null;
  _storeFuture = null;
}

Future<List<double>> _embed(String text) {
  final embedder = _embedder;
  if (embedder == null) {
    throw StateError(
      'Embedder belum dipasang — panggil installEmbedder(getEmbedding) dari '
      'composition root (lihat pdf_ingest_store.dart).',
    );
  }
  return embedder(text);
}

Future<PdfStore>? _storeFuture;

Future<PdfStore> _createStore() async {
  final dir = await getApplicationDocumentsDirectory();
  return PdfStore(p.join(dir.path, 'tacit_pulse_vectors.db'));
}

/// Buka store singleton. Bila pembukaan gagal (DB korup / permission / path
/// tidak tersedia), cache dibuang supaya panggilan berikutnya bisa mencoba
/// ulang — bukan mewarisi Future gagal yang sama sampai app di-restart.
Future<PdfStore> _openStore() async {
  _storeFuture ??= (_storeFactoryOverride ?? _createStore)();
  try {
    return await _storeFuture!;
  } catch (_) {
    _storeFuture = null;
    rethrow;
  }
}

/// Pipeline ingesti PDF: Parse PDF → chunk 250-500 token → embedding → SQLite.
///
/// [filePath] disimpan sebagai path sumber dokumen agar penampil PDF
/// (GABUT-25) bisa membukanya kembali lewat [docPathForCitation].
/// Mengembalikan jumlah chunk yang tersimpan; 0 bila PDF tidak punya lapisan
/// teks (hasil scan) atau kosong. Ekstraksi & embedding berjalan lokal
/// (tanpa jaringan).
Future<int> ingestPdf(String filePath, {String? title}) async {
  final file = File(filePath);
  if (!await file.exists()) {
    throw FileSystemException('Berkas PDF tidak ditemukan', filePath);
  }
  final bytes = await file.readAsBytes();
  final chunks = const PdfChunker().chunk(parsePdfLines(bytes));

  if (chunks.isEmpty) return 0;

  final embeddings = <List<double>>[];
  for (final chunk in chunks) {
    embeddings.add(await _embed(chunk.text));
  }

  final store = await _openStore();
  return store.saveDoc(
    title: title ?? p.basename(filePath),
    sourcePath: filePath,
    chunks: chunks,
    embeddings: embeddings,
  );
}

/// Path PDF sumber untuk sebuah id sitasi (`chunk-*`), id dokumen (`doc-*`
/// atau angka), atau judul dokumen. Null bila tidak ditemukan.
Future<String?> docPathForCitation(String citationIdOrDocId) async =>
    (await _openStore()).docPathFor(citationIdOrDocId);
