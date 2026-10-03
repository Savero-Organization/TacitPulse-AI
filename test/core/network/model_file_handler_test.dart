import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:tacit_pulse_ai/core/network/handlers/model_file_handler.dart';

void main() {
  late Directory tempDir;
  late List<int> fileBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('p2p_models_');
    fileBytes = List<int>.generate(100, (i) => i + 1);
    File('${tempDir.path}/model.gguf').writeAsBytesSync(fileBytes);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ByteRange byteRangeOf(String? header, int total) {
    final result = parseHttpRange(header, total);
    expect(result, isA<ByteRange>());
    return result as ByteRange;
  }

  group('parseHttpRange', () {
    test('tanpa header → FullContent', () {
      expect(parseHttpRange(null, 100), isA<FullContent>());
    });

    test('bytes=0- → start 0 sampai akhir', () {
      final r = byteRangeOf('bytes=0-', 100);
      expect(r.start, 0);
      expect(r.end, isNull);
    });

    test('bytes=2-5 → start 2 end exclusive 6', () {
      final r = byteRangeOf('bytes=2-5', 100);
      expect(r.start, 2);
      expect(r.end, 6);
    });

    test('bytes=-10 → 10 byte terakhir', () {
      final r = byteRangeOf('bytes=-10', 100);
      expect(r.start, 90);
      expect(r.end, isNull);
    });

    test('suffix lebih besar dari file → seluruh file', () {
      final r = byteRangeOf('bytes=-500', 100);
      expect(r.start, 0);
      expect(r.end, isNull);
    });

    test('unit token case-insensitive', () {
      final r = byteRangeOf('BYTES=0-9', 100);
      expect(r.start, 0);
      expect(r.end, 10);
    });

    test('start di luar file → UnsatisfiableRange (416)', () {
      expect(parseHttpRange('bytes=200-', 100), isA<UnsatisfiableRange>());
      expect(parseHttpRange('bytes=100-', 100), isA<UnsatisfiableRange>());
    });

    test('header rusak diabaikan, bukan 416', () {
      expect(parseHttpRange('bytes=abc-def', 100), isA<IgnoredRange>());
      expect(parseHttpRange('bytes=', 100), isA<IgnoredRange>());
      expect(parseHttpRange('items=0-5', 100), isA<IgnoredRange>());
      expect(parseHttpRange('bytes=0-1, 4-5', 100), isA<IgnoredRange>());
      expect(parseHttpRange('bytes=5-1', 100), isA<IgnoredRange>());
      expect(parseHttpRange('bytes=-0', 100), isA<IgnoredRange>());
      expect(parseHttpRange('bytes=nope', 100), isA<IgnoredRange>());
    });

    test('end melimpaui ukuran file di-clamp, tanpa overflow', () {
      final r = byteRangeOf('bytes=0-9223372036854775807', 100);
      expect(r.start, 0);
      expect(r.end, 100);
    });
  });

  group('ModelFileHandler', () {
    test('full GET tanpa Range → 200 dengan body penuh', () async {
      final handler = ModelFileHandler(tempDir.path);
      final req = Request('GET', Uri.parse('http://x/models/model.gguf'));
      final res = await handler.handle(req, 'model.gguf');
      expect(res.statusCode, 200);
      expect(res.headers['accept-ranges'], 'bytes');
      expect(res.headers['content-length'], '100');
      final body = await res.read().expand((c) => c).toList();
      expect(body, fileBytes);
    });

    test('Range bytes=0- → 206 dengan header tertentu', () async {
      final handler = ModelFileHandler(tempDir.path);
      final req = Request('GET', Uri.parse('http://x/models/model.gguf'),
          headers: {'range': 'bytes=0-'});
      final res = await handler.handle(req, 'model.gguf');
      expect(res.statusCode, 206);
      expect(res.headers['accept-ranges'], 'bytes');
      expect(res.headers['content-range'], 'bytes 0-99/100');
      expect(res.headers['content-length'], '100');
    });

    test('Range bounded → 206 hanya menyajikan chunk', () async {
      final handler = ModelFileHandler(tempDir.path);
      final req = Request('GET', Uri.parse('http://x/models/model.gguf'),
          headers: {'range': 'bytes=10-19'});
      final res = await handler.handle(req, 'model.gguf');
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], 'bytes 10-19/100');
      expect(res.headers['content-length'], '10');
      final body = await res.read().expand((c) => c).toList();
      expect(body, fileBytes.sublist(10, 20));
    });

    test('Range end melebihi file → 206 di-clamp ke ukuran file', () async {
      final handler = ModelFileHandler(tempDir.path);
      final req = Request('GET', Uri.parse('http://x/models/model.gguf'),
          headers: {'range': 'bytes=90-9999999999999999999'});
      final res = await handler.handle(req, 'model.gguf');
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], 'bytes 90-99/100');
      expect(res.headers['content-length'], '10');
    });

    test('Range valid tapi di luar file → 416', () async {
      final handler = ModelFileHandler(tempDir.path);
      final req = Request('GET', Uri.parse('http://x/models/model.gguf'),
          headers: {'range': 'bytes=999-'});
      final res = await handler.handle(req, 'model.gguf');
      expect(res.statusCode, 416);
      expect(res.headers['content-range'], 'bytes */100');
    });

    test('Range rusak → 200 dengan body penuh (header diabaikan)', () async {
      final handler = ModelFileHandler(tempDir.path);
      for (final header in ['bytes=abc-def', 'bytes=', 'items=0-5', 'bytes=0-1,4-5']) {
        final req = Request('GET', Uri.parse('http://x/models/model.gguf'),
            headers: {'range': header});
        final res = await handler.handle(req, 'model.gguf');
        expect(res.statusCode, 200, reason: 'header: $header');
        expect(res.headers['content-length'], '100');
        final body = await res.read().expand((c) => c).toList();
        expect(body, fileBytes, reason: 'header: $header');
      }
    });

    test('directory traversal → 403 Forbidden', () async {
      final handler = ModelFileHandler(tempDir.path);
      for (final bad in ['../../etc/passwd', '..\\..\\x', '/etc/passwd']) {
        final req = Request('GET', Uri.parse('http://x/models/$bad'));
        final res = await handler.handle(req, bad);
        expect(res.statusCode, 403, reason: 'filename: $bad');
      }
    });

    test('direktori di dalam modelsDir ditolak sebagai file', () async {
      Directory('${tempDir.path}/subdir').createSync();
      final handler = ModelFileHandler(tempDir.path);
      final res = await handler.handle(
          Request('GET', Uri.parse('http://x/models/subdir')), 'subdir');
      expect(res.statusCode, 404);
    });

    test('callback koneksi: start/end seimbang dan byte terhitung', () async {
      var active = 0;
      var maxActive = 0;
      var served = 0;
      final handler = ModelFileHandler(
        tempDir.path,
        onBytesServed: (n) => served += n,
        onConnectionStart: () {
          active++;
          if (active > maxActive) maxActive = active;
        },
        onConnectionEnd: () => active--,
      );
      final req = Request('GET', Uri.parse('http://x/models/model.gguf'));
      final res = await handler.handle(req, 'model.gguf');
      await res.read().expand((c) => c).toList();
      expect(maxActive, 1);
      expect(active, 0);
      expect(served, 100);
    });
  });
}