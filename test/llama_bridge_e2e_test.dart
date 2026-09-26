// E2E ter-gate env untuk GABUT 32/33: menjalankan getEmbedding sungguhan
// (native lib + model GGUF) di host Linux.
//
// Cara menjalankan (otomatis skip bila env tidak di-set):
//   TACIT_EMBED_MODEL_ROOT=/path/ke/root \
//   LD_LIBRARY_PATH=/path/ke/bundle/lib \
//   flutter test test/llama_bridge_e2e_test.dart
//
// Di root tersebut harus ada: models/multilingual-e5-small.gguf

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/native/llama_bridge.dart';
import 'package:tacit_pulse_ai/core/utils/model_loader.dart';

void main() {
  final modelRoot = Platform.environment['TACIT_EMBED_MODEL_ROOT'];
  final skipReason = modelRoot == null
      ? 'set TACIT_EMBED_MODEL_ROOT (+ LD_LIBRARY_PATH libtacit_llama.so)'
      : false;

  test('getEmbedding: 384 dim, L2-norm 1, deterministik', () async {
    ModelPaths.dataRootOverride = () async => Directory(modelRoot!);
    addTearDown(() => ModelPaths.dataRootOverride = null);

    final a = await getEmbedding('query: inspeksi mesin press hidrolik');
    expect(a, hasLength(384));
    expect(a.every((v) => v.isFinite), isTrue);
    final norm = a.fold<double>(0, (acc, v) => acc + v * v);
    expect(norm, closeTo(1.0, 1e-5));

    // Deterministik: teks sama → vektor identik.
    final b = await getEmbedding('query: inspeksi mesin press hidrolik');
    for (var i = 0; i < a.length; i++) {
      expect(b[i], closeTo(a[i], 1e-5));
    }

    // Cosine: teks mirip > teks berbeda.
    final c = await getEmbedding('query: servis mesin press hidrolik');
    final d = await getEmbedding('query: resep kue cokelat');
    double dot(List<double> x, List<double> y) {
      var s = 0.0;
      for (var i = 0; i < x.length; i++) {
        s += x[i] * y[i];
      }
      return s;
    }
    expect(dot(a, c), greaterThan(dot(a, d)));
  }, skip: skipReason);
}
