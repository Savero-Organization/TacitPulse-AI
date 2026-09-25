import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/rag/pdf_chunker.dart';
import 'package:tacit_pulse_ai/core/rag/pdf_store.dart';

void main() {
  late Directory dir;
  late PdfStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tpai_pdf_store');
    store = PdfStore('${dir.path}/vectors.db');
  });

  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  test('embedding float32 round-trip lewat SQLite', () {
    const embedding = [0.25, -0.5, 1.0, 0.0, 0.125];
    final chunk = PdfChunk(
      page: 3,
      text: 'tekanan oli 3,5 bar',
      boundingBox: const Rect.fromLTWH(0.1, 0.2, 0.3, 0.05),
      tokenCount: 12,
    );

    final docId = store.saveDoc(
      title: 'SOP PM-KOM-014',
      sourcePath: '/data/pm-kom-014.pdf',
      chunks: [chunk],
      embeddings: const [embedding],
    );
    expect(docId, greaterThan(0));

    final rows = store.db.select(
      'SELECT doc_id, title, page, bbox, text, embedding, created_at '
      'FROM pdf_chunks',
    );
    expect(rows, hasLength(1));
    expect(rows.first['doc_id'], docId);
    expect(rows.first['title'], 'SOP PM-KOM-014');
    expect(rows.first['page'], 3);
    expect(rows.first['text'], 'tekanan oli 3,5 bar');
    expect(rows.first['created_at'], isA<int>());

    final blob = rows.first['embedding'] as List<int>;
    expect(blob, isA<Uint8List>());
    expect(blob.length, embedding.length * 4, reason: 'float32 = 4 byte');

    final decoded = decodeFloat32(blob);
    expect(decoded, hasLength(embedding.length));
    for (var i = 0; i < embedding.length; i++) {
      expect(decoded[i], closeTo(embedding[i], 1e-6));
    }

    expect(decodeBbox(rows.first['bbox'] as String), chunk.boundingBox);
  });

  test('docPathForCitation-style lookup: id dokumen, chunk, dan judul', () {
    final docId = store.saveDoc(
      title: 'Manual Atlas Copco GA75',
      sourcePath: '/data/ga75.pdf',
      chunks: [
        PdfChunk(
          page: 14,
          text: 'Pressure 3.0 - 4.0 bar',
          boundingBox: const Rect.fromLTWH(0.08, 0.32, 0.6, 0.2),
          tokenCount: 8,
        ),
      ],
      embeddings: const [
        [1.0, 0.0],
      ],
    );
    final chunkId =
        (store.db.select('SELECT id FROM pdf_chunks').first['id'] as int);

    expect(store.docPathFor('doc-$docId'), '/data/ga75.pdf');
    expect(store.docPathFor('$docId'), '/data/ga75.pdf');
    expect(store.docPathFor('chunk-$chunkId'), '/data/ga75.pdf');
    expect(store.docPathFor('$chunkId'), '/data/ga75.pdf');
    expect(store.docPathFor('Manual Atlas Copco GA75'), '/data/ga75.pdf');
    expect(store.docPathFor('tidak-ada'), isNull);
  });

  test('saveDoc menolak jumlah embedding yang tidak cocok', () {
    expect(
      () => store.saveDoc(
        title: 'x',
        sourcePath: '/x.pdf',
        chunks: [
          const PdfChunk(
            page: 0,
            text: 'y',
            boundingBox: Rect.fromLTWH(0, 0, 1, 1),
            tokenCount: 1,
          ),
        ],
        embeddings: const [],
      ),
      throwsArgumentError,
    );
  });
}
