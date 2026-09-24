// Test ModelDownloadService — unduhan model global "latar belakang":
//   - lifecycle fase (idle → downloading → completed/failed)
//   - pause kooperatif (checkpoint per chunk) → paused + byte tersimpan
//   - resume dari byte tersimpan: mengirim header `Range: bytes=N-` & 206
//   - cancel murni → idle + pending dibersihkan
//   - gagal jaringan → failed + pending dipertahankan (retry via resume)
//   - restorePending setelah app di-kill → status paused dipulihkan dari
//     SharedPreferences + ukuran `.tmp` di cache.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacit_pulse_ai/core/downloads/model_download_service.dart';
import 'package:tacit_pulse_ai/core/utils/model_loader.dart';

/// Byte header GGUF minimal yang valid (magic "GGUF" + metadata
/// `general.architecture` & `general.name`) — dipakai agar lintasan validasi
/// GGUF di ModelManager juga berhasil.
Uint8List buildGgufBytes() {
  final b = BytesBuilder(copy: false);
  Uint8List le32(int v) {
    final d = ByteData(4);
    d.setUint32(0, v, Endian.little);
    return d.buffer.asUint8List();
  }

  Uint8List le64(int v) {
    final d = ByteData(8);
    d.setUint64(0, v, Endian.little);
    return d.buffer.asUint8List();
  }

  void str(String s) {
    final bytes = utf8.encode(s);
    b.add(le64(bytes.length));
    b.add(bytes);
  }

  void kv(String key, String value) {
    str(key);
    b.add(le32(8));
    str(value);
  }

  b.add([0x47, 0x47, 0x55, 0x46]);
  b.add(le32(3));
  b.add(le64(0));
  b.add(le64(2));
  kv('general.architecture', 'qwen2');
  kv('general.name', 'Qwen2-0.8B-Instruct');
  return b.toBytes();
}

/// Klien HTTP fiktif yang menyediakan serangkaian respons secara berurutan
/// (per indeks request), dan mencatat header `Range` tiap request — untuk
/// menguji resume `wget -c` tanpa jaringan nyata.
class _FakeStreamingClient extends http.BaseClient {
  _FakeStreamingClient(this._sendFactory);

  final http.StreamedResponse Function(int index, http.BaseRequest request)
      _sendFactory;
  final List<String?> ranges = [];
  int _count = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    ranges.add(request.headers['range']);
    return _sendFactory(_count++, request);
  }
}

void main() {
  late Directory tempDir;
  late String docsPath;
  late String cachePath;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('model_download_service_test');
    docsPath = '${tempDir.path}/docs';
    cachePath = '${tempDir.path}/download_cache';
    Directory(cachePath).createSync(recursive: true);
    ModelPaths.dataRootOverride = () async => Directory(docsPath);
    ModelManager.downloadCacheOverride = () async => Directory(cachePath);
  });

  tearDown(() {
    ModelPaths.dataRootOverride = null;
    ModelManager.downloadCacheOverride = null;
    tempDir.deleteSync(recursive: true);
  });

  test('unduhan selesai → completed + pending dibersihkan', () async {
    final full = buildGgufBytes();
    final client = MockClient.streaming((request, _) async {
      return http.StreamedResponse(
        Stream.fromIterable([full]),
        200,
        headers: {'content-length': '${full.length}'},
      );
    });

    final service = ModelDownloadService.create();
    await service.startDownload(
      url: 'https://example.com/model.gguf',
      fileName: 'model.gguf',
      client: client,
    );

    final p = service.progress;
    expect(p.phase, DownloadPhase.completed);
    expect(p.resultPath, '$docsPath/models/model.gguf');
    expect(p.bytesDownloaded, full.length);
    expect(p.totalBytes, full.length);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ModelDownloadService.pendingFileKey), isNull);
    expect(prefs.getString(ModelDownloadService.pendingUrlKey), isNull);
  });

  test('startDownload saat sedang mengunduh → diabaikan (tidak dobel)', () async {
    final gate = StreamController<List<int>>();
    final client = _FakeStreamingClient((index, request) {
      return http.StreamedResponse(
        index == 0 ? gate.stream : const Stream.empty(),
        200,
        headers: {'content-length': '100'},
      );
    });

    final service = ModelDownloadService.create();
    final first = service.startDownload(
      url: 'https://example.com/model.gguf',
      fileName: 'model.gguf',
      client: client,
    );
    await pumpEventQueue();
    expect(service.isDownloading, isTrue);

    await service.startDownload(
      url: 'https://other.example/x.gguf',
      fileName: 'other.gguf',
      client: _FakeStreamingClient((_, request) => throw UnimplementedError()),
    );

    expect(client.ranges, hasLength(1));

    gate.close();
    await first;
  });

  test(
      'pause kooperatif → paused (byte tersimpan, pending ditahan); '
      'resume → Range bytes=N- & selesai', () async {
    final full = buildGgufBytes();
    final n = full.length;
    final half = n ~/ 2;

    final gate = StreamController<List<int>>();
    final client = _FakeStreamingClient((index, request) {
      if (index == 0) {
        return http.StreamedResponse(
          gate.stream,
          200,
          headers: {'content-length': '$n'},
        );
      }
      // Resume: melayani sisanya dari byte ke-N-5.
      return http.StreamedResponse(
        Stream.fromIterable([full.sublist(n - 5)]),
        206,
        headers: {
          'content-range': 'bytes ${n - 5}-${n - 1}/$n',
          'content-length': '5',
        },
      );
    });

    final service = ModelDownloadService.create();
    final future = service.startDownload(
      url: 'https://example.com/model.gguf',
      fileName: 'model.gguf',
      client: client,
    );

    await pumpEventQueue();
    gate.add(full.sublist(0, half));
    await pumpEventQueue();
    expect(service.progress.phase, DownloadPhase.downloading);
    expect(service.progress.bytesDownloaded, half);

    service.pause();
    gate.add(full.sublist(half, n - 5));
    gate.close();
    await future;

    expect(service.progress.phase, DownloadPhase.paused);
    expect(service.progress.bytesDownloaded, n - 5);
    expect(service.progress.isActive, isTrue);
    expect(File('$cachePath/model.gguf.tmp').lengthSync(), n - 5);

    // Pending ditahan (bisa restart app → restorePending).
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ModelDownloadService.pendingFileKey), 'model.gguf');

    await service.resume();

    expect(client.ranges.last, 'bytes=${n - 5}-');
    expect(service.progress.phase, DownloadPhase.completed);
    expect(service.progress.resultPath, '$docsPath/models/model.gguf');
    expect(prefs.getString(ModelDownloadService.pendingFileKey), isNull);
  });

  test('cancel murni saat mengunduh → idle + pending dibersihkan', () async {
    final gate = StreamController<List<int>>();
    final client = _FakeStreamingClient((index, request) {
      return http.StreamedResponse(
        gate.stream,
        200,
        headers: {'content-length': '100'},
      );
    });

    final service = ModelDownloadService.create();
    final future = service.startDownload(
      url: 'https://example.com/model.gguf',
      fileName: 'model.gguf',
      client: client,
    );

    await pumpEventQueue();
    gate.add([1, 2, 3]);
    await pumpEventQueue();
    expect(service.isDownloading, isTrue);

    service.cancel();
    gate.add([4, 5, 6]);
    gate.close();
    await future;

    expect(service.progress.phase, DownloadPhase.idle);
    expect(service.progress.isActive, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ModelDownloadService.pendingFileKey), isNull);
  });

  test('gagal jaringan → failed + pending dipertahankan (retry = resume)',
      () async {
    Stream<List<int>> throwStream() async* {
      throw SocketException('connection reset oleh peer');
    }

    final client = MockClient.streaming((request, _) async {
      return http.StreamedResponse(
        throwStream(),
        200,
        headers: {'content-length': '100'},
      );
    });

    final service = ModelDownloadService.create();
    await service.startDownload(
      url: 'https://example.com/model.gguf',
      fileName: 'model.gguf',
      client: client,
    );

    final p = service.progress;
    expect(p.phase, DownloadPhase.failed);
    expect(p.errorMessage, isNotNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ModelDownloadService.pendingFileKey), 'model.gguf');

    // Status bar menawarkan retry = service.resume (failed → restart/resume).
    await service.resume();
    // Tidak ada klien lagi → masih gagal, bukan state aneh.
    expect(service.progress.phase, DownloadPhase.failed);
  });

  test('restorePending memulihkan unduhan yang terhenti oleh kill app',
      () async {
    SharedPreferences.setMockInitialValues({
      ModelDownloadService.pendingFileKey: 'model.gguf',
      ModelDownloadService.pendingUrlKey: 'https://example.com/model.gguf',
    });
    File('$cachePath/model.gguf.tmp').writeAsBytesSync(List.filled(500, 7));

    final service = ModelDownloadService.create();
    await service.restorePending();

    final p = service.progress;
    expect(p.phase, DownloadPhase.paused);
    expect(p.fileName, 'model.gguf');
    expect(p.bytesDownloaded, 500);
    expect(p.isActive, isTrue);

    // Idle (tidak ada pending) → restore no-op.
    SharedPreferences.setMockInitialValues({});
    final service2 = ModelDownloadService.create();
    await service2.restorePending();
    expect(service2.progress.phase, DownloadPhase.idle);
  });

  test('fraction & copyWith', () {
    const p = DownloadProgress(
      phase: DownloadPhase.downloading,
      bytesDownloaded: 25,
      totalBytes: 100,
    );
    expect(p.fraction, 0.25);
    expect(p.isActive, true);
    final paused = p.copyWith(phase: DownloadPhase.paused);
    expect(paused.phase, DownloadPhase.paused);
    expect(paused.isActive, true);
    expect(p.phase, DownloadPhase.downloading);
  });
}