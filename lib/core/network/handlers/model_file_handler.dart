// model_file_handler.dart — handler untuk GET /models/<filename>.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../utils/bandwidth_throttler.dart';

/// Range hasil parse: [startInclusive, endExclusiveExclusive] per konvensi
/// dart:io File.openRead(start, end) dengan end nullable.
class ParsedRange {
  const ParsedRange(this.start, this.end);
  final int start;
  final int? end; // exclusive bound; null = sampai akhir
}

/// Hasil parse Range header; null = header tidak valid/format lain.
ParsedRange? parseHttpRange(String? header, int totalSize) {
  if (header == null || !header.startsWith('bytes=')) return null;
  final value = header.substring('bytes='.length).trim();
  if (value.contains(',')) return null; // multi-range not supported
  final dash = value.indexOf('-');
  if (dash < 0) return null;
  final startPart = value.substring(0, dash).trim();
  final endPart = value.substring(dash + 1).trim();
  if (startPart.isEmpty) {
    // bytes=-N : last N bytes (RFC 7233 suffix form)
    final suffix = int.tryParse(endPart);
    if (suffix == null || suffix <= 0) return null;
    final start = (totalSize - suffix).clamp(0, totalSize);
    return ParsedRange(start, null);
  }
  final start = int.tryParse(startPart);
  if (start == null || start < 0 || start >= totalSize) return null;
  if (endPart.isEmpty) {
    return ParsedRange(start, null);
  }
  final end = int.tryParse(endPart);
  if (end == null || end < start) return null;
  final endExclusive = (end + 1).clamp(start + 1, totalSize);
  return ParsedRange(start, endExclusive);
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
    if (!file.existsSync() || !file.statSync().type.toString().contains('file')) {
      return Response.notFound('Not found: $filename');
    }
    final total = file.lengthSync();
    final range = parseHttpRange(request.headers['range'], total);

    final throttler = BandwidthThrottler(maxBytesPerSec: maxRateBytesPerSec);
    var dataStream = file.openRead(
      range?.start ?? 0,
      range?.end,
    );

    if (maxRateBytesPerSec != null && maxRateBytesPerSec! > 0) {
      dataStream = throttler.throttle(dataStream);
    }

    // Bungkus stream untuk metering bytes + koneksi aktif.
    final counted = _meterStream(
      dataStream,
      onStart: onConnectionStart,
      onByte: onBytesServed,
      onEnd: onConnectionEnd,
    );
    dataStream = counted;

    if (range == null && request.headers['range'] != null) {
      return Response(
        416,
        body: 'Requested Range Not Satisfiable',
        headers: {'content-range': 'bytes */$total'},
      );
    }

    if (range != null) {
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
