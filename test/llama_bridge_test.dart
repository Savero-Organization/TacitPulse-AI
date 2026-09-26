// Unit test GABUT 32/33: normalisasi L2 (kontrak getEmbedding) +
// resolver model embedding (GABUT 30) tanpa jaringan/native.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/native/llama_bridge.dart';
import 'package:tacit_pulse_ai/core/native/llm_inference.dart'
    show LLMInferenceException;
import 'package:tacit_pulse_ai/core/utils/model_loader.dart';

import 'model_manager_test.dart' show buildGgufBytes;

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
