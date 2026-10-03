import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tacit_pulse_ai/core/network/models/p2p_server_config.dart';
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

    expect(service.lastStats.isRunning, isTrue);

    await service.stop();
    expect(service.lastStats.isRunning, isFalse);
    expect(service.serverPort, isNull);
    await service.dispose();
  });

  test('resumable download: chunk 1 + chunk 2 = file asli', () async {
    final service = P2pServerServiceImpl();
    await service.start(modelsDirPath: tempDir.path, port: 0);
    final port = service.serverPort!;

    final client = http.Client();
    final half = fileBytes.length ~/ 2;

    final first = await client.get(
        Uri.parse('http://127.0.0.1:$port/models/model.gguf'),
        headers: {'range': 'bytes=0-${half - 1}'});
    expect(first.statusCode, 206);
    expect(first.headers['content-range'],
        'bytes 0-${half - 1}/${fileBytes.length}');

    final second = await client.get(
        Uri.parse('http://127.0.0.1:$port/models/model.gguf'),
        headers: {'range': 'bytes=$half-'});
    expect(second.statusCode, 206);
    expect(second.bodyBytes.length, fileBytes.length - half);

    final combined = first.bodyBytes + second.bodyBytes;
    expect(combined, fileBytes);

    client.close();
    await service.stop();
    await service.dispose();
  });

  test('stats stream melaporkan byte yang benar-benar dilayani', () async {
    final service = P2pServerServiceImpl();
    final running = <bool>[];
    final totals = <int>[];
    final sub = service.statsStream.listen((s) {
      running.add(s.isRunning);
      totals.add(s.totalBytesServed);
    });
    await service.start(modelsDirPath: tempDir.path, port: 0);
    final port = service.serverPort!;

    final client = http.Client();
    await client.get(Uri.parse('http://127.0.0.1:$port/models/model.gguf'));
    await client.get(Uri.parse('http://127.0.0.1:$port/health'));
    client.close();
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    // Tick statistik dari isolate harus melaporkan server hidup & byte terkirim.
    expect(running, contains(isTrue));
    expect(totals.any((t) => t >= fileBytes.length), isTrue);

    await service.stop();
    await sub.cancel();
    expect(service.lastStats.isRunning, isFalse);
    await service.dispose();
  });

  test('throttling end-to-end membatasi laju lewat service', () async {
    // File besar supaya openRead menghasilkan banyak chunk; dengan file kecil
    // seluruh payload datang sebagai satu chunk dan tidak ada yang bisa di-pace.
    final bigFile = File('${tempDir.path}/big.bin')
      ..writeAsBytesSync(List<int>.filled(200 * 1024, 3));
    expect(bigFile.lengthSync(), 200 * 1024);

    final service = P2pServerServiceImpl();
    // 200 KB pada 64 KB/s → ~3 detik.
    await service.start(
        modelsDirPath: tempDir.path, port: 0, maxRateBytesPerSec: 64 * 1024);
    final port = service.serverPort!;

    final stopwatch = Stopwatch()..start();
    final res = await http.get(Uri.parse('http://127.0.0.1:$port/models/big.bin'));
    stopwatch.stop();
    expect(res.statusCode, 200);
    expect(res.bodyBytes.length, 200 * 1024);
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(1500));

    await service.stop();
    await service.dispose();
  });

  test('port yang sudah dipakai → start() melempar error, bukan hang', () async {
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final busyPort = blocker.port;

    final service = P2pServerServiceImpl();
    // Server bind ke anyIPv4; port yang dipakai loopback tetap konflik.
    await expectLater(
      service.start(modelsDirPath: tempDir.path, port: busyPort),
      throwsA(anyOf(isA<StateError>(), isA<SocketException>())),
    );
    expect(service.serverPort, isNull);
    await blocker.close();
    await service.dispose();
  });

  test('start ganda tidak menyisakan isolate yatim', () async {
    final service = P2pServerServiceImpl();
    await service.start(modelsDirPath: tempDir.path, port: 0);
    final firstPort = service.serverPort!;

    await service.start(modelsDirPath: tempDir.path, port: 0);
    final secondPort = service.serverPort!;

    // Port lama harus benar-benar dilepas oleh start() kedua, sehingga probe
    final probe = await HttpServer.bind(InternetAddress.anyIPv4, firstPort);
    await probe.close(force: true);

    final client = http.Client();
    final health = await client.get(
        Uri.parse('http://127.0.0.1:$secondPort/health'));
    expect(health.statusCode, 200);
    client.close();

    await service.stop();
    await service.dispose();
  });

  test('start() tanpa argumen memakai P2pServerConfig', () async {
    final service = P2pServerServiceImpl(
      config: P2pServerConfig(modelsDirPath: tempDir.path, port: 0),
    );
    await service.start();
    final port = service.serverPort!;
    final client = http.Client();
    final res = await client.get(Uri.parse('http://127.0.0.1:$port/health'));
    expect(res.statusCode, 200);
    client.close();
    await service.stop();
    await service.dispose();
  });

  test('start() tanpa config maupun argumen → ArgumentError', () async {
    final service = P2pServerServiceImpl();
    await expectLater(service.start(), throwsArgumentError);
    await service.dispose();
  });
}
