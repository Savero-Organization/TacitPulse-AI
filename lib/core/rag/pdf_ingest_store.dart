import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Kontrak GABUT-22 (branch `feat/gabut-22-embedding`): file ini dibuat oleh
// branch tersebut dan baru ada setelah merge — lihat catatan di laporan sprint.
import '../native/llama_bridge.dart';
import 'pdf_chunker.dart';
import 'pdf_store.dart';

/// Satu-satunya jembatan ke embedder GABUT-22 (`getEmbedding` → L2-normalized).
Future<List<double>> _embed(String text) => getEmbedding(text);

Future<PdfStore>? _storeFuture;

Future<PdfStore> _openStore() =>
    _storeFuture ??= () async {
      final dir = await getApplicationDocumentsDirectory();
      return PdfStore(p.join(dir.path, 'tacit_pulse_vectors.db'));
    }();

/// Pipeline ingesti PDF: Parse PDF → chunk 250-500 token → embedding → SQLite.
///
/// [filePath] disimpan sebagai path sumber dokumen agar penampil PDF
/// (GABUT-25) bisa membukanya kembali lewat [docPathForCitation].
/// Mengembalikan jumlah chunk yang tersimpan; 0 bila PDF tidak punya lapisan
/// teks (hasil scan) atau kosong. Ekstraksi & embedding berjalan lokal
/// (tanpa jaringan).
Future<int> ingestPdf(String filePath, {String? title}) async {
  final bytes = await File(filePath).readAsBytes();
  final chunks = const PdfChunker().chunk(parsePdfLines(bytes));

  final embeddings = <List<double>>[];
  for (final chunk in chunks) {
    embeddings.add(await _embed(chunk.text));
  }

  final store = await _openStore();
  store.saveDoc(
    title: title ?? p.basename(filePath),
    sourcePath: filePath,
    chunks: chunks,
    embeddings: embeddings,
  );
  return chunks.length;
}

/// Path PDF sumber untuk sebuah id sitasi (`chunk-*`), id dokumen (`doc-*`
/// atau angka), atau judul dokumen. Null bila tidak ditemukan.
Future<String?> docPathForCitation(String citationIdOrDocId) async =>
    (await _openStore()).docPathFor(citationIdOrDocId);
