import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Satu baris teks hasil ekstraksi PDF + bbox ternormalisasi (0..1)
/// relatif terhadap halamannya. Konvensi sama dengan `KnowledgeChunk` /
/// `SourceCitation.boundingBox`: kiri-atas halaman = (0,0), satuan poin PDF
/// sudah dibagi dengan ukuran halaman.
class PdfTextLine {
  const PdfTextLine({
    required this.page,
    required this.text,
    required this.boundingBox,
  });

  /// Indeks halaman, 0-based.
  final int page;
  final String text;

  /// Bounding box relatif (0..1) pada halaman.
  final Rect boundingBox;
}

/// Hasil chunking: teks ~250-500 token yang selalu berada pada SATU halaman
/// + bbox gabungan (union) semua baris di dalamnya — asosiasi
/// teks ↔ halaman ↔ koordinat tidak pernah diputus.
class PdfChunk {
  const PdfChunk({
    required this.page,
    required this.text,
    required this.boundingBox,
    required this.tokenCount,
  });

  final int page;
  final String text;

  /// Union bbox seluruh baris dalam chunk (relatif 0..1, lihat [PdfTextLine]).
  final Rect boundingBox;

  /// Perkiraan jumlah token (lihat [estimateTokens]).
  final int tokenCount;
}

/// Ekstraksi teks + koordinat dari PDF secara lokal (syncfusion, pure Dart,
/// tanpa jaringan dan tanpa library native tambahan).
///
/// Menghasilkan per-baris (bukan per-paragraf): batas baris berasal langsung
/// dari glyph metrics parser PDF. Batasan yang diketahui:
/// - PDF hasil scan (tanpa lapisan teks) menghasilkan daftar kosong — perlu OCR
///   (di luar scope).
/// - PDF dua kolom diekstrak sesuai urutan konten, bukan urutan baca.
List<PdfTextLine> parsePdfLines(List<int> bytes) {
  final document = PdfDocument(inputBytes: bytes);
  try {
    final lines = <PdfTextLine>[];
    for (final line in PdfTextExtractor(document).extractTextLines()) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      final size = document.pages[line.pageIndex].size;
      lines.add(
        PdfTextLine(
          page: line.pageIndex,
          text: text,
          boundingBox: _normalize(line.bounds, size),
        ),
      );
    }
    return lines;
  } finally {
    document.dispose();
  }
}

/// Pemotong chunk teks: akumulasi baris sampai mendekati [maxTokens],
/// tidak pernah melewati batas halaman, dan tidak pernah membelah baris.
class PdfChunker {
  const PdfChunker({this.minTokens = 250, this.maxTokens = 500});

  /// Target bawah. Chunk bisa lebih kecil dari ini hanya bila halaman berakhir.
  final int minTokens;

  /// Target atas (batas keras, kecuali satu baris yang memang lebih panjang).
  final int maxTokens;

  List<PdfChunk> chunk(List<PdfTextLine> lines) {
    final result = <PdfChunk>[];
    var buffer = <PdfTextLine>[];
    var tokens = 0;

    void flush() {
      if (buffer.isEmpty) return;
      result.add(_build(buffer, tokens));
      buffer = <PdfTextLine>[];
      tokens = 0;
    }

    for (final line in lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      final lineTokens = estimateTokens(text);

      // Pindah halaman selalu memutus chunk (page + bbox harus konsisten).
      final pageBreak = buffer.isNotEmpty && line.page != buffer.first.page;
      // Capai maxTokens, tapi jangan memotong terlalu dini sebelum minTokens.
      final sizeBreak =
          buffer.isNotEmpty &&
          tokens + lineTokens > maxTokens &&
          tokens >= minTokens;
      if (pageBreak || sizeBreak) flush();

      buffer.add(line);
      tokens += lineTokens;

      // Baris tunggal yang sangat panjang TIDAK dipecah: asosiasi koordinat
      // baris dijaga, chunk-nya saja yang melebihi maxTokens.
      if (tokens >= maxTokens) flush();
    }
    flush();
    return result;
  }

  PdfChunk _build(List<PdfTextLine> buffer, int tokens) {
    var box = buffer.first.boundingBox;
    for (final line in buffer.skip(1)) {
      box = box.expandToInclude(line.boundingBox);
    }
    return PdfChunk(
      page: buffer.first.page,
      text: buffer.map((line) => line.text).join('\n'),
      boundingBox: box,
      tokenCount: tokens,
    );
  }
}

/// Perkiraan token murah tanpa tokenizer: ±4 karakter per token (heuristik
/// lazim untuk teks EN/ID). Cukup untuk menjaga rentang chunk 250-500.
int estimateTokens(String text) =>
    text.isEmpty ? 0 : (text.length / 4).ceil();

Rect _normalize(Rect bounds, Size pageSize) {
  if (pageSize.width <= 0 || pageSize.height <= 0) return Rect.zero;
  double unit(double value, double total) {
    final v = value / total;
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
  }

  return Rect.fromLTRB(
    unit(bounds.left, pageSize.width),
    unit(bounds.top, pageSize.height),
    unit(bounds.right, pageSize.width),
    unit(bounds.bottom, pageSize.height),
  );
}
