// Unit test GABUT 32/33: normalisasi L2 (kontrak getEmbedding) +
// resolver model embedding (GABUT 30) tanpa jaringan/native.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/native/llama_bridge.dart';
import 'package:tacit_pulse_ai/core/native/llm_inference.dart'
    show LLMInferenceException;
import 'package:tacit_pulse_ai/core/utils/model_loader.dart';

import 'model_manager_test.dart' show buildGgufBytes;

/// Penanda di teks request yang membuat worker palsu mati mendadak lewat
/// `Isolate.kill` — meniru OOM native (proses mati tanpa unwind, jadi hanya
/// exit-listener yang melaporkan).
const String _kCrashByKill = 'CRASH_BY_KILL';

/// Penanda yang membuat worker palsu melempar uncaught error dari dalam
/// listener — memicu error-listener ([errorString, stackString]).
const String _kCrashByThrow = 'CRASH_BY_THROW';

/// Worker isolate palsu yang bicara protokol yang sama dengan worker asli,
/// tapi tanpa native: balas `init` langsung, balas embedding dengan [3, 4]
/// (→ L2 [0.6, 0.8]), dan mati mendadak kalau teksnya mengandung penanda
/// crash. Dipasang lewat `setEmbeddingWorkerMainForTest`.
void _fakeEmbeddingWorker(List<Object?> args) {
  // args: [modelPath, mainPort] — sama dengan _embedWorkerMain.
  final mainPort = args[1] as SendPort;
  final requests = ReceivePort();
  mainPort.send({'type': 'init', 'ok': true, 'port': requests.sendPort});

  requests.listen((Object? msg) {
    if (msg is! Map) return;
    final reply = msg['reply'];
    if (reply is! SendPort) return;

    switch (msg['cmd']) {
      case 'embed':
        final text = msg['text'] as String? ?? '';
        if (text.contains(_kCrashByKill)) {
          // OOM native: tidak ada balasan dan tidak ada unwind.
          Isolate.current.kill(priority: Isolate.immediate);
        } else if (text.contains(_kCrashByThrow)) {
          // Uncaught error: lempar di luar try worker asli, supaya benar-benar
          // sampai ke error-listener.
          throw StateError('simulasi native crash');
        } else {
          reply.send({
            'type': 'embedding',
            'vector': [3.0, 4.0],
          });
        }
      case 'shutdown':
        reply.send({'type': 'shutdown-ok'});
        requests.close();
      default:
        reply.send({
          'type': 'error',
          'message': 'cmd tidak dikenal: ${msg['cmd']}',
        });
    }
  });
}

void main() {
  group('l2Normalize (GABUT 33)', () {
    test('menghasilkan vektor dengan norm = 1', () {
      final out = l2Normalize([3.0, 4.0]);
      expect(out[0], closeTo(0.6, 1e-12));
      expect(out[1], closeTo(0.8, 1e-12));
      final norm = out.fold<double>(0, (a, v) => a + v * v);
      expect(norm, closeTo(1.0, 1e-12));
    });

    test('vektor nol tetap nol (tanpa NaN/Infinity)', () {
      final out = l2Normalize([0.0, 0.0, 0.0]);
      expect(out, [0.0, 0.0, 0.0]);
      expect(out.every((v) => v.isFinite), isTrue);
    });

    test('idempoten: normalisasi dua kali = sekali', () {
      final once = l2Normalize([0.1, -0.7, 2.5]);
      final twice = l2Normalize(once);
      for (var i = 0; i < once.length; i++) {
        expect(twice[i], closeTo(once[i], 1e-12));
      }
    });

    test('vektor sudah dinormalisasi tidak berubah', () {
      final out = l2Normalize([1.0, 0.0]);
      expect(out, [1.0, 0.0]);
    });
  });

  group('getEmbedding validasi input', () {
    test('teks kosong (\'\') → ArgumentError', () async {
      await expectLater(getEmbedding(''), throwsArgumentError);
    });

    test('whitespace-only → ArgumentError (sebelum dispatch ke worker)',
        () async {
      await expectLater(getEmbedding('   \t\n  '), throwsArgumentError);
      await expectLater(getEmbedding(' '), throwsArgumentError);
    });
  });

  group('getEmbedding init worker gagal', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('tacit_emb_init_fail');
      ModelPaths.dataRootOverride = () async => tempRoot;
      setEmbeddingTimeouts(init: const Duration(seconds: 10));
    });

    tearDown(() {
      ModelPaths.dataRootOverride = null;
      setEmbeddingTimeouts(
        init: const Duration(seconds: 60),
        request: const Duration(seconds: 30),
      );
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('GGUF rusak → LLMInferenceException, tidak hang', () async {
      final dir = Directory('${tempRoot.path}/models')
        ..createSync(recursive: true);
      File('${dir.path}/${ModelManager.embeddingModelName}')
          .writeAsStringSync('bukan gguf — byte sampah');

      final watch = Stopwatch()..start();
      await expectLater(
        getEmbedding('halo dunia').timeout(const Duration(seconds: 20)),
        throwsA(isA<LLMInferenceException>()),
      );
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
    });
  });

  // Regression test lifecycle worker PR #4 memakai worker isolate PALSU
  // (setEmbeddingWorkerMainForTest): jalur "init sukses lalu crash" mustahil
  // dijalankan tanpa libtacit_llama.so + model GGUF asli, padahal di situlah
  // bug aslinya berada.
  group('getEmbedding lifecycle worker (worker palsu)', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('tacit_emb_fake');
      ModelPaths.dataRootOverride = () async => tempRoot;
      // Model hanya perlu ADA — worker palsu tidak pernah membacanya.
      final dir = Directory('${tempRoot.path}/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.embeddingModelName}')
          .writeAsBytesSync(buildGgufBytes(architecture: 'bert', name: 'e5'));
      setEmbeddingWorkerMainForTest(_fakeEmbeddingWorker);
      setEmbeddingTimeouts(init: const Duration(seconds: 10));
    });

    tearDown(() async {
      await resetEmbeddingWorkerForTest();
      setEmbeddingWorkerMainForTest(null);
      ModelPaths.dataRootOverride = null;
      setEmbeddingTimeouts(
        init: const Duration(seconds: 60),
        request: const Duration(seconds: 30),
      );
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('handshake init sukses → embedding pertama dari worker palsu', () async {
      // [3, 4] di-normalisasi jadi [0.6, 0.8]; nilai ini hanya bisa datang dari
      // worker palsu, jadi membuktikan _requests terisi port worker yang hidup.
      final out = await getEmbedding('teks biasa')
          .timeout(const Duration(seconds: 10));
      expect(out, hasLength(2));
      expect(out[0], closeTo(0.6, 1e-12));
      expect(out[1], closeTo(0.8, 1e-12));
    });

    test('crash native saat embed → gagal cepat lalu respawn worker baru', () async {
      await getEmbedding('teks biasa').timeout(const Duration(seconds: 10));

      // OOM native = proses dibunuh tanpa unwind, jadi hanya exit-listener yang
      // bicara. Tanpa fix, call ini sendiri menggantung sampai requestTimeout.
      final crashWatch = Stopwatch()..start();
      await expectLater(
        getEmbedding('$_kCrashByKill teks')
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<LLMInferenceException>()),
      );
      crashWatch.stop();
      expect(
        crashWatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'request yang sedang jalan harus gagal cepat saat worker mati',
      );

      // Ini inti regression test-nya. Tanpa fix, _requests masih menunjuk
      // SendPort worker yang sudah dibunuh → call ini terkirim ke port mati dan
      // menggantung sampai requestTimeout (30 detik), bukan mengembalikan
      // embedding dari worker baru.
      final out = await getEmbedding('teks setelah crash')
          .timeout(const Duration(seconds: 10));
      expect(out[0], closeTo(0.6, 1e-12));
    });

    test(
      'uncaught error di worker saat embed → gagal cepat lalu respawn',
      () async {
        await getEmbedding('teks biasa').timeout(const Duration(seconds: 10));

        final crashWatch = Stopwatch()..start();
        await expectLater(
          getEmbedding('$_kCrashByThrow teks')
              .timeout(const Duration(seconds: 10)),
          throwsA(isA<LLMInferenceException>()),
        );
        crashWatch.stop();
        expect(crashWatch.elapsed, lessThan(const Duration(seconds: 5)));

        final out = await getEmbedding('teks setelah error')
            .timeout(const Duration(seconds: 10));
        expect(out[1], closeTo(0.8, 1e-12));
      },
    );

    test('shutdown eksplisit menutup worker hidup tanpa menggantung', () async {
      await getEmbedding('teks biasa').timeout(const Duration(seconds: 10));

      // Worker hidup harus ditutup lewat handshake shutdown-ok (worker palsu
      // membalas seperti worker asli), bukan menunggu timeout ack lalu kill.
      final watch = Stopwatch()..start();
      await resetEmbeddingWorkerForTest().timeout(const Duration(seconds: 10));
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));

      // Setelah shutdown, panggilan berikutnya harus spawn worker baru.
      final out = await getEmbedding('teks setelah shutdown')
          .timeout(const Duration(seconds: 10));
      expect(out[0], closeTo(0.6, 1e-12));
    });
  });

  // Regression test untuk jalur init GAGAL (environment unit test tidak punya
  // libtacit_llama.so): worker yang gagal lalu keluar wajib tetap melaporkan
  // sebab aslinya dan tidak menyisakan state yang membuat panggilan berikutnya
  // memakai SendPort worker mati.
  group('getEmbedding lifecycle worker (init gagal)', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('tacit_emb_lifecycle');
      ModelPaths.dataRootOverride = () async => tempRoot;
      setEmbeddingTimeouts(init: const Duration(seconds: 10));
      final dir = Directory('${tempRoot.path}/models')
        ..createSync(recursive: true);
      File('${dir.path}/${ModelManager.embeddingModelName}')
          .writeAsStringSync('bukan gguf — byte sampah');
    });

    tearDown(() {
      ModelPaths.dataRootOverride = null;
      setEmbeddingTimeouts(
        init: const Duration(seconds: 60),
        request: const Duration(seconds: 30),
      );
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('sebab kegagalan init ter-surfase, bukan exit generik', () async {
      // Worker yang gagal lalu return mengirim pesan init ok:false DAN memicu
      // exit listener. Kalau yang dilaporkan justru exit, penyebab sebenarnya
      // (library native gagal dibuka) hilang — persis yang membuat kegagalan
      // sulit didiagnosis di device.
      await expectLater(
        getEmbedding('halo dunia').timeout(const Duration(seconds: 20)),
        throwsA(
          isA<LLMInferenceException>().having(
            (LLMInferenceException e) => e.message,
            'message',
            contains('Gagal membuka library native'),
          ),
        ),
      );
    });

    test('panggilan berikutnya tidak reuse worker yang sudah keluar', () async {
      // Dua call berturut-turut: keduanya wajib gagal cepat. Kalau state
      // _requests/_isolate menggantung pada worker yang sudah keluar, call kedua
      // akan mengirim ke SendPort mati lalu menggantung sampai requestTimeout
      // penuh, bukan melempar error.
      final watch = Stopwatch()..start();
      for (var attempt = 1; attempt <= 2; attempt++) {
        await expectLater(
          getEmbedding('halo dunia $attempt')
              .timeout(const Duration(seconds: 20)),
          throwsA(isA<LLMInferenceException>()),
          reason: 'call #$attempt harus gagal, bukan memakai worker mati',
        );
      }
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
    });

    test('panggilan paralel berbagi satu init, semuanya gagal cepat', () async {
      // _starting dipakai bersama oleh pemanggil yang datang bersamaan. Tidak
      // boleh menggantung, dan tidak boleh melempar error tak terduga — mis.
      // error dari Completer yang sudah ditinggalkan saat initTimeout menyala.
      await expectLater(
        Future.wait([
          getEmbedding('satu').timeout(const Duration(seconds: 20)),
          getEmbedding('dua').timeout(const Duration(seconds: 20)),
          getEmbedding('tiga').timeout(const Duration(seconds: 20)),
        ]),
        throwsA(isA<LLMInferenceException>()),
      );
    });

    test('validasi input tetap fast-fail setelah init gagal', () async {
      // State worker yang kotor tidak boleh membuat jalur validasi (yang
      // sengaja tidak menyentuh worker sama sekali) ikut menunggu.
      await expectLater(
        getEmbedding('halo dunia'),
        throwsA(isA<LLMInferenceException>()),
      );
      await expectLater(getEmbedding(''), throwsArgumentError);
      await expectLater(getEmbedding('  '), throwsArgumentError);
    });
  });

  group('ensureEmbeddingModelReady (GABUT 30)', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('tacit_emb_test');
      ModelPaths.dataRootOverride = () async => tempRoot;
    });

    tearDown(() {
      ModelPaths.dataRootOverride = null;
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('nama file model embedding = kontrak lintas-branch', () {
      expect(ModelManager.embeddingModelName, 'multilingual-e5-small.gguf');
      expect(ModelManager.embeddingModelDownloadUrl, contains('huggingface.co'));
    });

    test('false bila model belum ada', () async {
      expect(await ModelManager.ensureEmbeddingModelReady(), isFalse);
    });

    test('true bila file GGUF ada di <root>/models/', () async {
      final dir = Directory('${tempRoot.path}/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.embeddingModelName}')
          .writeAsBytesSync(buildGgufBytes(architecture: 'bert', name: 'e5'));
      expect(await ModelManager.ensureEmbeddingModelReady(), isTrue);
    });

    test('false bila file ada tapi bukan GGUF', () async {
      final dir = Directory('${tempRoot.path}/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.embeddingModelName}')
          .writeAsStringSync('bukan gguf');
      expect(await ModelManager.ensureEmbeddingModelReady(), isFalse);
    });
  });
}
