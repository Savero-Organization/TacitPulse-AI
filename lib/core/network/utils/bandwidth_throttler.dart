// bandwidth_throttler.dart — pembatas laju stream byte.

/// Membagi payload stream menjadi throttled stream: setiap chunk ditunda
/// secukupnya agar total bytes yang dipancarkan per detik tidak melebihi
/// [maxBytesPerSec]. null = pass-through.
class BandwidthThrottler {
  const BandwidthThrottler({this.maxBytesPerSec});

  /// Batas laju dalam bytes/detik; null / 0 berarti tanpa batas.
  final int? maxBytesPerSec;

  /// Mengembalikan stream baru yang memancarkan chunk dari [source]
  /// dengan rate terbatas. Semua byte dijamin tetap muncul dengan urutan.
  Stream<List<int>> throttle(Stream<List<int>> source) async* {
    final max = maxBytesPerSec;
    if (max == null || max <= 0) {
      yield* source;
      return;
    }
    // Chunk pertama dikirim tanpa jeda supaya time-to-first-byte tidak
    // tertahan oleh rate limit; ritme rata-rata tetap dijaga karena delay
    // dihitung dari total kumulatif (bukan per chunk).
    var sent = 0;
    var started = false;
    final start = DateTime.now();
    await for (final chunk in source) {
      sent += chunk.length;
      if (started) {
        final elapsedSeconds =
            DateTime.now().difference(start).inMilliseconds / 1000.0;
        final expectedSeconds = sent / max;
        if (expectedSeconds > elapsedSeconds) {
          await Future<void>.delayed(Duration(
            milliseconds: ((expectedSeconds - elapsedSeconds) * 1000).round(),
          ));
        }
      } else {
        started = true;
      }
      yield chunk;
    }
  }
}
