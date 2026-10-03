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

  test('throttling menambahkan delay tapi tidak kehilangan byte', () async {
    final bytes = List<int>.filled(100, 7);
    final throttler = BandwidthThrottler(maxBytesPerSec: 200);
    final stopwatch = Stopwatch()..start();
    final out = await throttler
        .throttle(Stream.fromIterable([bytes]))
        .expand((e) => e)
        .toList();
    stopwatch.stop();
    expect(out.length, 100);
    // 100 bytes pada 200 B/s theoretically ~0.5s.
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(450));
  });

  test('tidak melempar lebih dari rate * elapsed detik (verifiek byte masih ada)',
      () async {
    final throttler = BandwidthThrottler(maxBytesPerSec: 50);
    final out = await throttler
        .throttle(Stream.fromIterable([
          List.filled(20, 1),
          List.filled(20, 2),
          List.filled(20, 3),
        ]))
        .expand((e) => e)
        .toList();
    expect(out, List<int>.filled(20, 1) + List<int>.filled(20, 2) + List<int>.filled(20, 3));
  });
}
