import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_db.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_store.dart';
import 'package:tacit_pulse_ai/core/db/sqlite_vec.dart';

/// Jumlah baris chunk untuk corpus benchmark.
const int kRowCount = 1000;

/// Jumlah query yang diukur untuk statistik latency.
const int kQueryCount = 100;

/// Query pemanasan (JIT) yang tidak dihitung statistik.
const int kWarmupCount = 20;

/// Batas rata-rata latency per query (ms) agar tetap menangkap regresi
/// parah (mis. encode JSON seluruh korpus per query) tanpa flaky di CI.
const double kAvgQueryMsLimit = 50.0;

void main() {
  final vec0Path = _resolveVec0Library();
  final skipReason = vec0Path == null
      ? 'libvec0.so tidak ditemukan — jalankan `flutter build linux --debug` '
          'atau set env VEC0_LIB_PATH ke path libvec0.so.'
      : false;

  test(
    'kecepatan pencarian KNN cosine 384-dim di SQLite '
    '(N=$kRowCount, avg < $kAvgQueryMsLimit ms/query)',
    skip: skipReason,
    () {
      expect(
        kEmbeddingDimensions,
        384,
        reason: 'Test ini memverifikasi pencarian vektor 384-dimensi.',
      );

      final db = openDatabaseWithVec(':memory:', vecLibraryPath: vec0Path);
      addTearDown(db.dispose);
      db.execute(kKnowledgeChunksSchema);
      final store = KnowledgeChunksDb(db);

      // Korpus deterministik (seed tetap) supaya hasil reproducible.
      final random = Random(42);
      List<double> randomVector() => List<double>.generate(
            kEmbeddingDimensions,
            (_) => random.nextDouble() * 2 - 1,
          );

      // Isi corpus dalam satu transaksi.
      final insertWatch = Stopwatch()..start();
      db.execute('BEGIN');
      for (var i = 0; i < kRowCount; i++) {
        store.insert(
          KnowledgeChunkRecord(
            id: 'chunk-$i',
            documentName: 'SOP DEMO-${1 + i % 5}',
            page: 1 + i % 20,
            chunkText: 'Chunk konten dummy ke-$i',
            x: 0.0,
            y: 0.0,
            w: 1.0,
            h: 1.0,
            embedding: randomVector(),
          ),
        );
      }
      db.execute('COMMIT');
      insertWatch.stop();

      // Warmup untuk stabilisasi JIT sebelum pengukuran.
      for (var i = 0; i < kWarmupCount; i++) {
        store.search(randomVector(), k: 10);
      }

      // Ukur latency per query (k=10), sekaligus pastikan hasil non-hampa.
      final latenciesMs = <double>[];
      final queryWatch = Stopwatch();
      for (var i = 0; i < kQueryCount; i++) {
        queryWatch
          ..reset()
          ..start();
        final hits = store.search(randomVector(), k: 10);
        queryWatch.stop();
        expect(
          hits.length,
          10,
          reason: 'Pencarian harus mengembalikan tepat k hasil.',
        );
        latenciesMs.add(queryWatch.elapsedMicroseconds / 1000.0);
      }

      final sorted = [...latenciesMs]..sort();
      final avg = latenciesMs.reduce((a, b) => a + b) / kQueryCount;
      final p50 = sorted[kQueryCount ~/ 2];
      final p95 = sorted[(kQueryCount * 0.95).floor()];

      // ignore: avoid_print
      print(
        'VECTOR SPEED: corpus=$kRowCount x $kEmbeddingDimensions-dim, '
        'insert=${insertWatch.elapsedMilliseconds}ms, search k=10 -> '
        'avg=${avg.toStringAsFixed(2)}ms '
        'p50=${p50.toStringAsFixed(2)}ms p95=${p95.toStringAsFixed(2)}ms '
        '($kQueryCount queries)',
      );

      expect(
        avg,
        lessThan(kAvgQueryMsLimit),
        reason: 'KNN cosine 1000 baris 384-dim harus jauh di bawah '
            '${kAvgQueryMsLimit}ms/query.',
      );
    },
  );

  test(
    'batas parameter k pada vec0 (k=1, k > korpus, k=0, k negatif)',
    skip: skipReason,
    () {
      final db = openDatabaseWithVec(':memory:', vecLibraryPath: vec0Path);
      addTearDown(db.dispose);
      db.execute(kKnowledgeChunksSchema);
      final store = KnowledgeChunksDb(db);

      final random = Random(7);
      List<double> randomVector() => List<double>.generate(
            kEmbeddingDimensions,
            (_) => random.nextDouble() * 2 - 1,
          );

      const corpusSize = 25;
      for (var i = 0; i < corpusSize; i++) {
        store.insert(
          KnowledgeChunkRecord(
            id: 'edge-$i',
            documentName: 'SOP EDGE',
            page: 1,
            chunkText: 'Chunk edge-case ke-$i',
            x: 0.0,
            y: 0.0,
            w: 1.0,
            h: 1.0,
            embedding: randomVector(),
          ),
        );
      }

      final query = randomVector();

      // k=1: harus mengembalikan tepat 1 hasil, dan hasilnya konsisten
      // dengan tetangga terdekat dari pencarian ber-k lebih besar.
      final top1 = store.search(query, k: 1);
      expect(top1, hasLength(1), reason: 'k=1 harus mengembalikan 1 hasil.');
      final top10 = store.search(query, k: 10);
      expect(top10, hasLength(10));
      expect(
        top1.single.id,
        top10.first.id,
        reason: 'k=1 harus berupa tetangga terdekat (baris pertama k=10).',
      );
      expect(top1.single.distance, isNotNull);
      expect(
        top1.single.distance,
        moreOrLessEquals(top10.first.distance!, epsilon: 1e-9),
      );

      // k melebihi jumlah baris: mengembalikan seluruh korpus tanpa error
      // (bound dihormati sebagai min(k, jumlah_baris)).
      expect(
        store.search(query, k: corpusSize * 4),
        hasLength(corpusSize),
      );

      // k=0: kontrak vec0 yang sah — hasil kosong, bukan error.
      expect(store.search(query, k: 0), isEmpty);

      // k negatif: divalidasi oleh vec0 sendiri di layer query (bukan
      // guard Dart — sengaja tidak diduplikasi) dan gagal-loud dengan
      // pesan jelas, bukan undefined behavior. Dipatok sebagai
      // SqliteException agar perubahan kontrak ini terdeteksi bila
      // amalgamasi sqlite-vec di-upgrade.
      expect(
        () => store.search(query, k: -1),
        throwsA(isA<SqliteException>()),
        reason: 'k negatif harus ditolak vec0, bukan menghasilkan data aneh.',
      );
    },
  );

  // Validasi bbox dilempar SEBELUM SQL dijalankan, jadi test ini cukup
  // pakai koneksi polos tanpa libvec0.so maupun skema — selalu jalan
  // di mesin mana pun (hermetic), tidak ikut-skip dengan test speed.
  test('validasi bounding box menolak nilai di luar 0..1 dan NaN', () {
    final db = sqlite3.open(':memory:');
    addTearDown(db.dispose);
    final store = KnowledgeChunksDb(db);

    KnowledgeChunkRecord record({
      String id = 'bbox-1',
      double x = 0.5,
      double y = 0.5,
      double w = 0.4,
      double h = 0.4,
    }) =>
        KnowledgeChunkRecord(
          id: id,
          documentName: 'SOP DEMO',
          page: 1,
          chunkText: 'Chunk dummy',
          x: x,
          y: y,
          w: w,
          h: h,
          embedding: List.filled(kEmbeddingDimensions, 0.1),
        );

    // Di luar rentang 0..1 → ArgumentError.
    expect(
      () => store.insert(record(x: -0.1)),
      throwsA(isA<ArgumentError>()),
      reason: 'x negatif harus ditolak.',
    );
    expect(
      () => store.insert(record(y: 1.01)),
      throwsA(isA<ArgumentError>()),
      reason: 'y > 1 harus ditolak.',
    );
    expect(
      () => store.insert(record(w: -0.0001)),
      throwsA(isA<ArgumentError>()),
    );

    // NaN lolos dari perbandingan `<`/`>` biasa — harus ikut tertolak
    // (form negasi di _validateBounds).
    expect(
      () => store.insert(record(h: double.nan)),
      throwsA(isA<ArgumentError>()),
      reason: 'NaN di luar rentang 0..1 dan harus ditolak.',
    );

    // update() menulis kolom bbox yang sama → divalidasi juga.
    expect(
      () => store.update(record(id: 'lain', x: 2.0)),
      throwsA(isA<ArgumentError>()),
      reason: 'update harus menolak bbox invalid seperti insert.',
    );

    // Batas 0 dan 1 termasuk SAH: lolos validasi (gagalnya terjadi
    // kemudian di SQL karena test ini tanpa skema — bukan ArgumentError).
    expect(
      () => store.insert(record(x: 0.0, y: 1.0, w: 1.0, h: 0.0)),
      throwsA(isNot(isA<ArgumentError>())),
      reason: 'nilai batas 0..1 inklusif tidak boleh ditolak validasi.',
    );
  });
}

/// Mencari libvec0.so: prioritas env `VEC0_LIB_PATH`, lalu output
/// `flutter build linux --debug` di dalam repo. `null` jika tidak ada.
String? _resolveVec0Library() {
  final env = Platform.environment['VEC0_LIB_PATH'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) {
    return env;
  }
  const candidates = [
    'build/linux/x64/debug/bundle/lib/libvec0.so',
    'build/linux/x64/debug/libvec0.so',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}