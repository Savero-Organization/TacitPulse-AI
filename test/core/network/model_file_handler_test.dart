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

  group('parseHttpRange', () {
    test('null header → null', () {
      expect(parseHttpRange(null, 100), isNull);
    });

    test('bytes=0- → start 0, sampai akhir', () {
      final r = parseHttpRange('bytes=0-', 100);
      expect(r?.start, 0);
      expect(r?.end, null);
    });

    test('bytes=2-5 → start 2 endExclusive 6', () {
      final r = parseHttpRange('bytes=2-5', 100);
      expect(r?.start, 2);
      expect(r?.end, 6);
    });

    test('bytes=-10 → suffix 10 byte terakhir', () {
      final r = parseHttpRange('bytes=-10', 100);
      expect(r?.start, 90);
      expect(r?.end, null);
    });

    test('invalid range → null', () {
      expect(parseHttpRange('bytes=abc-', 100), isNull);
      expect(parseHttpRange('bytes=50-99,100-', 100), isNull);
      expect(parseHttpRange('bytes=99-', 100)!.start, 99);
      expect(parseHttpRange('bytes=200-', 100), isNull);
    });
  });

  group('ModelFileHandler', () {
    test('full GET tanpa Range → 200 dengan full body', () async {
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

    test('Range bounded → 206 hanya menyediakan chunk', () async {
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

    test('Range invalid/melebihi → 416', () async {
      final handler = ModelFileHandler(tempDir.path);
      final req = Request('GET', Uri.parse('http://x/models/model.gguf'),
          headers: {'range': 'bytes=999-'});
      final res = await handler.handle(req, 'model.gguf');
      expect(res.statusCode, 416);
      expect(res.headers['content-range'], 'bytes */100');
    });

    test('directory traversal → 403 Forbidden', () async {
      final handler = ModelFileHandler(tempDir.path);
      for (final bad in ['../../etc/passwd', '..\\..\\x', '/etc/passwd']) {
        final req = Request('GET', Uri.parse('http://x/models/$bad'));
        final res = await handler.handle(req, bad);
        expect(res.statusCode, 403);
      }
    });
  });
}
