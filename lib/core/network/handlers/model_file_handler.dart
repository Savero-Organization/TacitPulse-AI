// model_file_handler.dart — handler untuk GET /models/<filename>.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../utils/bandwidth_throttler.dart';

/// Hasil interpretasi header `Range`.
///
/// Suatu header `Range` bisa bermakna empat hal berbeda, dan semuanya harus
/// ditangani berbeda menurut RFC 9110 §14.2:
/// * tidak ada header sama sekali → kirim seluruh representasi (`200`);
/// * header ada tapi tidak bisa diparse / unit-nya bukan `bytes` — header
///   **diabaikan**, kirim seluruh representasi (`200`);
/// * header valid secara sintaks tapi berada di luar ukuran file — `416`;
/// * header valid dan dapat dilayani — `206`.
sealed class RangeResult {
  const RangeResult();
}

/// Tidak ada header `Range`; kirim seluruh isi file (`200`).
final class FullContent extends RangeResult {
  const FullContent();
}

/// Header `Range` ada tapi tidak dapat diparse (unit lain, multi-range,
/// angka bukan integer). Menurut RFC 9110 header ini harus diabaikan dan
/// seluruh representasi dikirim dengan status `200`.
final class IgnoredRange extends RangeResult {
  const IgnoredRange();
}

/// Header `Range` valid secara sintaks namun tidak dapat dipenuhi karena
/// berada di luar ukuran file. Wajib dijawab `416`.
final class UnsatisfiableRange extends RangeResult {
  const UnsatisfiableRange();
}

/// Rentang byte yang dapat dilayani: `[start, end)`, dengan [end] exclusive
/// dan `null` berarti sampai akhir file.
final class ByteRange extends RangeResult {
  const ByteRange(this.start, this.end);

  final int start;
  final int? end;
}

/// Parse header `Range` HTTP terhadap ukuran file [totalSize] byte.
RangeResult parseHttpRange(String? header, int totalSize) {
  if (header == null) return const FullContent();

  // Unit token bersifat case-insensitive (RFC 9110 §14.1).
  final trimmed = header.trim();
  if (!trimmed.toLowerCase().startsWith('bytes=')) return const IgnoredRange();

  final value = trimmed.substring('bytes='.length).trim();
  // Multi-range butuh respons multipart/byteranges yang tidak kita dukung;
  // server tidak wajib memenuhi sebagian dari range yang diminta.
  if (value.isEmpty || value.contains(',')) return const IgnoredRange();

  final dash = value.indexOf('-');
  if (dash < 0) return const IgnoredRange();

  final startPart = value.substring(0, dash).trim();
  final endPart = value.substring(dash + 1).trim();

  if (startPart.isEmpty) {
    // bytes=-N : N byte terakhir (suffix form).
    final suffix = int.tryParse(endPart);
    if (suffix == null || suffix <= 0) return const IgnoredRange();
    //_suffix lebih besar dari file berarti seluruh file dikirim.
    final start = suffix >= totalSize ? 0 : totalSize - suffix;
    return ByteRange(start, null);
  }

  final start = int.tryParse(startPart);
  if (start == null || start < 0) return const IgnoredRange();

  final end = endPart.isEmpty ? null : int.tryParse(endPart);
  if (end != null && end < start) return const IgnoredRange();

  //.Start di luar file: sintaks valid tetapi tidak dapat dipenuhi.
  if (start >= totalSize) return const UnsatisfiableRange();

  if (end == null) return ByteRange(start, null);

  // Clamp sebelum +1 supaya tidak overflow pada end == 2^63-1.
  final maxEnd = totalSize - 1;
  final boundedEnd = end > maxEnd ? maxEnd : end;
  return ByteRange(start, boundedEnd + 1);
}

/// Handler file model dengan dukungan Range & throttling.
class ModelFileHandler {
  ModelFileHandler(
    this.modelsDirPath, {
    this.maxRateBytesPerSec,
    this.onBytesServed,
    this.onConnectionStart,
    this.onConnectionEnd,
  });

  final String modelsDirPath;
  final int? maxRateBytesPerSec;

  /// Dipanggil dengan jumlah total bytes yang baru saja dipancarkan
  /// dari sebuah respons (untuk statistik server). Satu chunk dihitung
  /// per chunk stream setelah throttling.
  final void Function(int bytes)? onBytesServed;

  /// Dipanggil saat koneksi/stream respons dimulai dan saat selesai.
  final void Function()? onConnectionStart;
  final void Function()? onConnectionEnd;

  /// Kembalikan path absolut aman untuk [filename] di dalam [modelsDirPath],
  /// atau null bila request mencoba traversal di luar direktori.
  String? resolveFilePath(String filename) {
    if (filename.isEmpty) return null;
    // Tolak path traversal: nama file tidak boleh memiliki segmen.
    if (filename.contains('..') ||
        filename.contains('/') ||
        filename.contains('\\')) {
      return null;
    }
    final resolved = p.normalize(p.join(modelsDirPath, filename));
    final base = p.normalize(modelsDirPath);
    if (resolved != base && !resolved.startsWith(base + p.separator)) {
      return null;
    }
    return resolved;
  }

  Future<Response> handle(Request request, String filename) async {
    final resolved = resolveFilePath(filename);
    if (resolved == null) {
      return Response.forbidden('Forbidden: invalid filename');
    }
    final file = File(resolved);
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file) {
      return Response.notFound('Not found: $filename');
    }
    // Snapshot ukuran saat request masuk; nilai inilah yang dikontribusikan ke
    // content-length dan content-range agar konsisten dengan stream.
    final total = stat.size;
    final range = parseHttpRange(request.headers['range'], total);

    if (range is UnsatisfiableRange) {
      return Response(
        416,
        body: 'Requested Range Not Satisfiable',
        headers: {'content-range': 'bytes */$total'},
      );
    }

    // openRead(start, end) memakai end *exclusive*: openRead(10, 20) menghasilkan
    // byte 10..19 (10 byte). Karena itu end ByteRange juga exclusive.
    var dataStream = file.openRead(
      range is ByteRange ? range.start : 0,
      range is ByteRange ? range.end : null,
    );

    if (maxRateBytesPerSec != null && maxRateBytesPerSec! > 0) {
      dataStream =
          BandwidthThrottler(maxBytesPerSec: maxRateBytesPerSec)
              .throttle(dataStream);
    }

    // Bungkus stream untuk metering bytes + koneksi aktif.
    dataStream = _meterStream(
      dataStream,
      onStart: onConnectionStart,
      onByte: onBytesServed,
      onEnd: onConnectionEnd,
    );

    if (range is ByteRange) {
      final start = range.start;
      final end = range.end ?? total;
      final chunkLength = end - start;
      return Response(
        206,
        body: dataStream,
        headers: {
          'accept-ranges': 'bytes',
          'content-range': 'bytes $start-${end - 1}/$total',
          'content-length': chunkLength.toString(),
          'content-type': 'application/octet-stream',
        },
      );
    }

    // Baik [FullContent] maupun [IgnoredRange] mengirim seluruh representasi.
    return Response.ok(
      dataStream,
      headers: {
        'accept-ranges': 'bytes',
        'content-length': total.toString(),
        'content-type': 'application/octet-stream',
      },
    );
  }

  /// Bungkus stream agar callback statistik dipanggil sinkron.
  Stream<List<int>> _meterStream(
    Stream<List<int>> source, {
    void Function()? onStart,
    void Function(int)? onByte,
    void Function()? onEnd,
  }) async* {
    onStart?.call();
    try {
      await for (final chunk in source) {
        onByte?.call(chunk.length);
        yield chunk;
      }
    } finally {
      onEnd?.call();
    }
  }
}