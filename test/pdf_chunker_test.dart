import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tacit_pulse_ai/core/rag/pdf_chunker.dart';

List<PdfTextLine> _lines(int page, int count, {String pad = 'ab'}) => [
  for (var i = 0; i < count; i++)
    PdfTextLine(
      page: page,
      text: pad * 100, // 200 karakter ≈ 50 token (heuristik 4 char/token)
      boundingBox: Rect.fromLTWH(0.1, 0.01 * i, 0.5, 0.008),
    ),
];

void main() {
  group('PdfChunker', () {
    test('bbox chunk adalah union barisnya dan tidak melewati halaman', () {
      final lines = [..._lines(0, 20), ..._lines(1, 3)];
      final chunks = const PdfChunker().chunk(lines);

      expect(chunks, hasLength(3));
      expect(chunks[0].page, 0);
      expect(chunks[1].page, 0);
      expect(chunks[2].page, 1, reason: 'chunk tidak boleh lintas halaman');
      expect(chunks[0].tokenCount, 500);
      expect(chunks[2].tokenCount, 150, reason: 'sisa halaman di bawah min');

      // Union bbox = gabungan bbox seluruh baris di dalam chunk.
      var expected = lines.first.boundingBox;
      for (final line in lines.take(10)) {
        expected = expected.expandToInclude(line.boundingBox);
      }
      expect(chunks[0].boundingBox, expected);

      // Teks chunk memuat barisnya utuh dan berurutan.
      expect(chunks[0].text.split('\n'), hasLength(10));
      expect(chunks[0].text, contains(lines.first.text));
      expect(chunks[0].text, contains(lines[9].text));

      // Semua bbox tetap ternormalisasi 0..1.
      for (final chunk in chunks) {
        expect(chunk.boundingBox.left, inInclusiveRange(0, 1));
        expect(chunk.boundingBox.top, inInclusiveRange(0, 1));
        expect(chunk.boundingBox.right, inInclusiveRange(0, 1));
        expect(chunk.boundingBox.bottom, inInclusiveRange(0, 1));
      }
    });

    test('baris sangat panjang tidak dipecah (asosiasi koordinat dijaga)', () {
      final long = PdfTextLine(
        page: 0,
        text: 'x' * 4000, // ≈ 1000 token, melebihi maxTokens
        boundingBox: const Rect.fromLTWH(0.2, 0.3, 0.4, 0.02),
      );
      final chunks = const PdfChunker().chunk([long]);

      expect(chunks, hasLength(1));
      expect(chunks.single.text, long.text);
      expect(chunks.single.page, long.page);
      expect(chunks.single.boundingBox, long.boundingBox);
      expect(chunks.single.tokenCount, greaterThan(500));
    });
  });

  test('parsePdfLines menghasilkan page + bbox ternormalisasi 0..1', () async {
    final doc = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    doc.pages.add().graphics.drawString(
      'ATAS pressure switch',
      font,
      bounds: const Rect.fromLTWH(72, 100, 300, 20),
    );
    doc.pages.add().graphics.drawString(
      'BAWAH tekanan oli',
      font,
      bounds: const Rect.fromLTWH(72, 600, 300, 20),
    );
    final lines = parsePdfLines(await doc.save());
    doc.dispose();

    expect(lines, hasLength(2));
    expect(lines.map((l) => l.page).toSet(), {0, 1});
    expect(lines.map((l) => l.text), containsAll(['ATAS pressure switch']));

    for (final line in lines) {
      expect(line.boundingBox.left, inInclusiveRange(0, 1));
      expect(line.boundingBox.top, inInclusiveRange(0, 1));
      expect(line.boundingBox.right, inInclusiveRange(0, 1));
      expect(line.boundingBox.bottom, inInclusiveRange(0, 1));
    }

    // Halaman 0 berisi teks di atas; pastikan sumbu-Y top-left (bukan cermin).
    final atas = lines.firstWhere((l) => l.page == 0).boundingBox;
    expect(atas.top, lessThan(0.5), reason: 'y=100pt harus di paruh atas');
  });

  test('estimateTokens memakai heuristik ±4 karakter per token', () {
    expect(estimateTokens(''), 0);
    expect(estimateTokens('abcd'), 1);
    expect(estimateTokens('a' * 400), 100);
  });
}
