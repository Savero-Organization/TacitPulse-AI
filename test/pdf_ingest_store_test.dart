import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tacit_pulse_ai/core/rag/pdf_ingest_store.dart';
import 'package:tacit_pulse_ai/core/rag/pdf_store.dart';

Future<List<double>> _mockEmbedding(String text) async =>
    List<double>.generate(384, (i) => (i + text.length) / 384);

Future<String> _writeTextPdf(Directory dir, String name) async {
  final doc = PdfDocument();
  final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
  doc.pages.add().graphics.drawString(
    'tekanan oli 3,5 bar pada kompresor',
    font,
    bounds: const Rect.fromLTWH(72, 100, 400, 20),
  );
  final bytes = await doc.save();
  doc.dispose();
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(bytes);
  return file.path;
}

Future<String> _writeTextlessPdf(Directory dir, String name) async {
  final doc = PdfDocument();
  doc.pages.add(); // halaman kosong tanpa lapisan teks (simulasi scan)
  final bytes = await doc.save();
  doc.dispose();
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(bytes);
  return file.path;
}

void main() {
  late Directory dir;
  late PdfStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tpai_pdf_ingest');
    store = PdfStore(p.join(dir.path, 'vectors.db'));
  });

  tearDown(() {
    debugResetRagOverrides();
    store.close();
    dir.deleteSync(recursive: true);
  });

  test('ingestPdf berkas tidak ada → FileSystemException', () async {
    await expectLater(
      ingestPdf(p.join(dir.path, 'hilang.pdf')),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          'Berkas PDF tidak ditemukan',
        ),
      ),
    );
  });

  test('ingestPdf bytes korup → FormatException terbungkus', () async {
    final file = File(p.join(dir.path, 'korup.pdf'));
    await file.writeAsBytes('bukan pdf sama sekali'.codeUnits);

    await expectLater(
      ingestPdf(file.path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Gagal mengekstrak teks PDF'),
        ),
      ),
    );
  });

  test('ingestPdf PDF tanpa lapisan teks → 0, store tidak dibuka', () async {
    final path = await _writeTextlessPdf(dir, 'scan.pdf');
    var storeOpened = false;
    debugSetStoreFactory(() async {
      storeOpened = true;
      return store;
    });

    expect(await ingestPdf(path), 0);
    expect(storeOpened, isFalse);
    expect(store.db.select('SELECT * FROM pdf_docs'), isEmpty);
  });

  test('ingestPdf embedder belum dipasang → StateError yang jelas', () async {
    final path = await _writeTextPdf(dir, 'sop.pdf');

    await expectLater(
      ingestPdf(path),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('installEmbedder'),
        ),
      ),
    );
  });

  test('ingestPdf jalur sukses menyimpan doc + chunk + embedding', () async {
    final path = await _writeTextPdf(dir, 'sop.pdf');
    installEmbedder(_mockEmbedding);
    debugSetStoreFactory(() async => store);

    final chunkCount = await ingestPdf(path);

    expect(chunkCount, greaterThan(0));
    final docs = store.db.select('SELECT id, title, source_path FROM pdf_docs');
    expect(docs, hasLength(1));
    expect(docs.first['title'], 'sop.pdf');
    expect(docs.first['source_path'], path);

    final chunks = store.db.select(
      'SELECT doc_id, page, bbox, embedding FROM pdf_chunks',
    );
    expect(chunks, hasLength(chunkCount));
    for (var i = 0; i < chunks.length; i++) {
      expect(chunks[i]['doc_id'], docs.first['id']);
      expect(chunks[i]['page'], 0);
      final embedding = decodeFloat32(chunks[i]['embedding'] as List<int>);
      expect(embedding, hasLength(384));
    }
  });

  test('ingestPdf title eksplisit dipakai untuk pdf_docs', () async {
    final path = await _writeTextPdf(dir, 'sop.pdf');
    installEmbedder(_mockEmbedding);
    debugSetStoreFactory(() async => store);

    await ingestPdf(path, title: 'SOP Kompresor');

    final docs = store.db.select('SELECT title FROM pdf_docs');
    expect(docs.single['title'], 'SOP Kompresor');
  });

  test('_openStore gagal sekali → panggilan berikutnya retry (D1)', () async {
    final path = await _writeTextPdf(dir, 'sop.pdf');
    installEmbedder(_mockEmbedding);

    var attempts = 0;
    debugSetStoreFactory(() async {
      attempts++;
      if (attempts == 1) {
        throw const FileSystemException('disk tidak bisa dibuka');
      }
      return store;
    });

    await expectLater(
      ingestPdf(path),
      throwsA(isA<FileSystemException>()),
    );
    expect(attempts, 1);

    // Future gagal tidak boleh di-cache: panggilan kedua harus mencoba lagi.
    final chunkCount = await ingestPdf(path);
    expect(chunkCount, greaterThan(0));
    expect(attempts, 2);
    expect(store.db.select('SELECT id FROM pdf_docs'), hasLength(1));
  });
}
