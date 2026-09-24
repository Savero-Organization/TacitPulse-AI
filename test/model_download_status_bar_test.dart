// Widget test ModelDownloadStatusBar — strip status unduhan global:
//   - idle → tidak render apa pun (SizedBox.shrink)
//   - downloading → nama file + detail progres
//   - completed → teks "Selesai"
//   - failed → pesan error

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacit_pulse_ai/core/downloads/model_download_service.dart';
import 'package:tacit_pulse_ai/core/utils/model_loader.dart';
import 'package:tacit_pulse_ai/core/widgets/model_download_status_bar.dart';

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

void main() {
  late Directory tempDir;
  late String docsPath;
  late String cachePath;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('status_bar_test');
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

  Widget wrap(ModelDownloadService service) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: ModelDownloadStatusBar(service: service),
        ),
      ),
    );
  }

  testWidgets('idle → bar tidak dirender', (tester) async {
    final service = ModelDownloadService.create();
    await tester.pumpWidget(wrap(service));
    expect(find.byType(ModelDownloadStatusBar), findsOneWidget);
    expect(find.textContaining('MB'), findsNothing);
  });

  testWidgets('downloading → nama file + progres', (tester) async {
    final release = Completer<void>();
    Stream<List<int>> pendingBody() async* {
      await release.future;
    }

    final service = ModelDownloadService.create();
    await tester.pumpWidget(wrap(service));

    // Semua kerja nyata (persist + send + mendengarkan stream) harus dimulai
    // di zona REAL (runAsync). Fase `downloading` di-emit sinkron di awal
    // startDownload; stream di-gate Completer agar unduhan tetap in-flight
    // selama asersi.
    Future<void>? started;
    await tester.runAsync(() async {
      started = service.startDownload(
        url: 'https://example.com/model.gguf',
        fileName: 'model.gguf',
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            pendingBody(),
            200,
            headers: {'content-length': '1000000'},
          );
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();

    expect(find.text('model.gguf'), findsOneWidget);
    expect(find.textContaining('MB'), findsOneWidget);

    await tester.runAsync(() async {
      release.complete();
      await started;
    });
    await tester.pump();
  });

  testWidgets('completed → teks selesai', (tester) async {
    final full = buildGgufBytes();
    final service = ModelDownloadService.create();
    await tester.pumpWidget(wrap(service));
    await tester.runAsync(() async {
      await service.startDownload(
        url: 'https://example.com/model.gguf',
        fileName: 'model.gguf',
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            Stream.fromIterable([full]),
            200,
            headers: {'content-length': '${full.length}'},
          );
        }),
      );
    });
    await tester.pump();

    expect(find.textContaining('Selesai ✓'), findsOneWidget);
  });

  testWidgets('failed → pesan error', (tester) async {
    Stream<List<int>> throwStream() async* {
      throw SocketException('connection reset');
    }

    final service = ModelDownloadService.create();
    await tester.pumpWidget(wrap(service));
    await tester.runAsync(() async {
      await service.startDownload(
        url: 'https://example.com/model.gguf',
        fileName: 'model.gguf',
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            throwStream(),
            200,
            headers: {'content-length': '100'},
          );
        }),
      );
    });
    await tester.pump();

    expect(find.textContaining('Unduh gagal'), findsOneWidget);
  });
}