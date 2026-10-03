// Unit test GABUT 46: WhisperBridge lifecycle + kontrak transkripsi tanpa
// native — worker isolate palsu yang bicara protokol sama seperti worker asli.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/native/whisper_bridge.dart';

/// Worker isolate palsu: balas init langsung, balas transcribe dengan satu
/// segmen, dan shutdown-ok. Dipasang lewat setWorkerMainForTest.
void _fakeWhisperWorker(List<Object?> args) {
  final mainPort = args[1] as SendPort;
  final requests = ReceivePort();
  mainPort.send({'type': 'init', 'ok': true, 'port': requests.sendPort});

  requests.listen((Object? msg) {
    if (msg is! Map) return;
    final reply = msg['reply'];
    if (reply is! SendPort) return;
    switch (msg['cmd']) {
      case 'transcribe':
        final language = msg['language'] as String? ?? 'id';
        reply.send({
          'type': 'result',
          'segments': [
            {'text': 'pump bearing overheat', 't0': 0, 't1': 150},
            {'text': 'ganti pelumas ($language)', 't0': 150, 't1': 300},
          ],
        });
      case 'shutdown':
        reply.send({'type': 'shutdown-ok'});
        requests.close();
      default:
        reply.send({'type': 'error', 'message': 'cmd tidak dikenal'});
    }
  });
}

/// Worker palsu yang gagal init (native tidak bisa load model).
void _failingInitWorker(List<Object?> args) {
  final mainPort = args[1] as SendPort;
  mainPort.send({
    'type': 'init',
    'ok': false,
    'error': 'failed to load whisper model',
  });
}

void main() {
  late Directory tempRoot;
  late File modelFile;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('tacit_whisper_');
    modelFile = File('${tempRoot.path}/ggml-base.bin')..writeAsBytesSync([0]);
    WhisperBridge.setWorkerMainForTest(_fakeWhisperWorker);
  });

  tearDown(() {
    WhisperBridge.setWorkerMainForTest(null);
    tempRoot.deleteSync(recursive: true);
  });

  group('validasi input', () {
    test('init dengan path tidak ada → FileSystemException', () async {
      final bridge = WhisperBridge();
      expect(
        () => bridge.init('${tempRoot.path}/tidak_ada.bin'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('transcribe sebelum init → StateError', () async {
      final bridge = WhisperBridge();
      await expectLater(
        bridge.transcribe([0.1, 0.2]),
        throwsStateError,
      );
    });

    test('transcribe dengan pcm kosong → ArgumentError', () async {
      final bridge = WhisperBridge();
      await bridge.init(modelFile.path);
      await expectLater(bridge.transcribe([]), throwsArgumentError);
      await bridge.dispose();
    });

    test('init kedua tanpa dispose → StateError', () async {
      final bridge = WhisperBridge();
      await bridge.init(modelFile.path);
      await expectLater(bridge.init(modelFile.path), throwsStateError);
      await bridge.dispose();
    });
  });

  group('dengan worker palsu', () {
    test('transcribe menggabungkan segmen menjadi satu teks', () async {
      final bridge = WhisperBridge();
      await bridge.init(modelFile.path);
      final text = await bridge.transcribe([0.0, 0.1, -0.1]);
      expect(text, 'pump bearing overheat ganti pelumas (id)');
      await bridge.dispose();
    });

    test('transcribeSegments mengembalikan daftar segmen ber-timestamp',
        () async {
      final bridge = WhisperBridge();
      await bridge.init(modelFile.path);
      final segments = await bridge.transcribeSegments(
        [0.0, 0.1, -0.1],
        language: 'en',
      );
      expect(segments.length, 2);
      expect(segments.first.text, 'pump bearing overheat');
      expect(segments.first.t0, 0);
      expect(segments.first.t1, 150);
      expect(segments.last.text, 'ganti pelumas (en)');
      await bridge.dispose();
    });

    test('init gagal dari worker → WhisperException', () async {
      WhisperBridge.setWorkerMainForTest(_failingInitWorker);
      final bridge = WhisperBridge();
      await expectLater(
        bridge.init(modelFile.path),
        throwsA(isA<WhisperException>()),
      );
    });

    test('dispose aman dipanggil berulang tanpa error', () async {
      final bridge = WhisperBridge();
      await bridge.init(modelFile.path);
      await bridge.dispose();
      await bridge.dispose();
    });
  });
}
