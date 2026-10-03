import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/network/utils/bandwidth_throttler.dart';

void main() {
  test('pass-through saat max null', () async {
    final source = Stream<List<int>>.fromIterable([
      [1, 2],
      [3, 4],
    ]);
    final chunks = await const BandwidthThrottler()
        .throttle(source)
        .expand((e) => e)
        .toList();
    expect(chunks, [1, 2, 3, 4]);
  });

  test('chunk pertama dikirim tanpa jeda (time-to-first-byte)', () async {
    // 100 B pada 100 B/s = 1 detik jika chunk pertama ikut ditunda.
    // Chunk pertama harus langsung keluar supaya tidak ada stall di awal.
    final stopwatch = Stopwatch()..start();
    final out = <int>[];
    await for (final chunk in const BandwidthThrottler(maxBytesPerSec: 100)
        .throttle(Stream.fromIterable([List<int>.filled(100, 7)]))) {
      out.addAll(chunk);
    }
    stopwatch.stop();
    expect(out.length, 100);
    expect(stopwatch.elapsedMilliseconds, lessThan(300));
  });

  test('laju rata-rata tetap dibatasi pada chunk subsequent', () async {
    // 4 chunk x 50 B = 200 B pada 100 B/s → total ~2 detik (chunk pertama
    // gratis, sisanya di-pacing oleh budget kumulatif).
    final stopwatch = Stopwatch()..start();
    final out = <int>[];
    await for (final chunk in const BandwidthThrottler(maxBytesPerSec: 100)
        .throttle(Stream.fromIterable([
          List<int>.filled(50, 1),
          List<int>.filled(50, 2),
          List<int>.filled(50, 3),
          List<int>.filled(50, 4),
        ]))) {
      out.addAll(chunk);
    }
    stopwatch.stop();
    expect(out.length, 200);
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(1400));
  });

  test('tidak kehilangan byte maupun urutan', () async {
    final throttler = BandwidthThrottler(maxBytesPerSec: 50);
    final out = await throttler
        .throttle(Stream.fromIterable([
          List.filled(20, 1),
          List.filled(20, 2),
          List.filled(20, 3),
        ]))
        .expand((e) => e)
        .toList();
    expect(
      out,
      List<int>.filled(20, 1) +
          List<int>.filled(20, 2) +
          List<int>.filled(20, 3),
    );
  });
}