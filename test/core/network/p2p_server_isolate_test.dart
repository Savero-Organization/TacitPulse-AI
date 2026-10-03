import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tacit_pulse_ai/core/network/p2p_server_service.dart';

void main() {
  late Directory tempDir;
  late List<int> fileBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('p2p_server_');
    // Konten deterministik agar bisa di-compare setelah resume.
    fileBytes = List<int>.generate(1024, (i) => (i * 7) % 251);
    File('${tempDir.path}/model.gguf').writeAsBytesSync(fileBytes);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('health endpoint + startup isolate + clean shutdown', () async {
    final service = P2pServerServiceImpl();
    await service.start(modelsDirPath: tempDir.path, port: 0);
    final port = service.serverPort!;
    expect(port, greaterThan(0));

    final client = http.Client();
    final health = await client.get(Uri.parse('http://127.0.0.1:$port/health'));
    expect(health.statusCode, 200);
    expect(health.body, contains('"status":"ok"'));
    expect(health.body, contains('"version"'));

    final models = await client.get(Uri.parse('http://127.0.0.1:$port/models'));
    expect(models.statusCode, 200);
    expect(models.body, contains('model.gguf'));
    client.close();

    // Koneksi terputus tanpa leak: stop mengembalikan stats isRunning false.
    final stats = <bool>[];
    final sub = service.statsStream.listen((s) => stats.add(s.isRunning));
    await service.stop();
    await sub.cancel();
    expect(stats.isNotEmpty, isTrue);
    expect(stats.every((s) => s == false), isTrue);
    expect(service.serverPort, isNull);
  });

  test('resumable download: chunk 1 + chunk 2 = file asli', () async {
    final service = P2pServerServiceImpl();
    await service.start(modelsDirPath: tempDir.path, port: 0);
    final port = service.serverPort!;

    final client = http.Client();
    final half = fileBytes.length ~/ 2;

    final first = await http.get(Uri.parse('http://127.0.0.1:$port/models/model.gguf'),
        headers: {'range': 'bytes=0-${half - 1}'});
    expect(first.statusCode, 206);
    expect(first.headers['content-range'], 'bytes 0-${half - 1}/${fileBytes.length}');

    final second = await http.get(Uri.parse('http://127.0.0.1:$port/models/model.gguf'),
        headers: {'range': 'bytes=$half-'});
    expect(second.statusCode, 206);
    expect(second.bodyBytes.length, fileBytes.length - half);

    final combined = first.bodyBytes + second.bodyBytes;
    expect(combined, fileBytes);

    client.close();
    await service.stop();
  });

  test('stats stream memancarkan metrik sederhana (non-failing)', () async {
    final service = P2pServerServiceImpl();
    final updates = <int>[];
    final sub = service.statsStream.listen((s) => updates.add(s.totalBytesServed));
    await service.start(modelsDirPath: tempDir.path, port: 0);
    final port = service.serverPort!;
    final client = http.Client();
    await client.get(Uri.parse('http://127.0.0.1:$port/health'));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    client.close();
    await service.stop();
    await sub.cancel();
    // minimal satu update stats diterima (bisa berisi isRunning true/false)
    expect(updates, isNotEmpty);
  });
}
