// E2E ter-gate env: reload worker isolate llama.cpp dengan model GGUF sungguhan
// (native lib + model nyata) di host Linux.
//
// Cara menjalankan (otomatis skip bila env tidak di-set):
//   TACIT_RELOAD_MODEL_A=/path/ke/LFM2.5-350M-Q4_K_M.gguf \
//   TACIT_RELOAD_MODEL_B=/path/ke/Qwen3.5-0.8B-Q4_K_M.gguf \
//   LD_LIBRARY_PATH=/path/ke/bundle/lib \
//   flutter test test/llm_reload_e2e_test.dart
//
// Menguji:
//   1. initialize() memuat model A.
//   2. reloadModel(path B) mematikan worker lama & memuat model B.
//   3. Family GGUF terdeteksi benar (LFM2 vs Qwen) → tier translation berubah.
//   4. Model B benar-benar bisa generate (token stream tidak kosong).
//   5. reloadModel(path tidak ada) → false tanpa merusak state.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacit_pulse_ai/core/native/llm_inference.dart';
import 'package:tacit_pulse_ai/core/utils/gguf_validator.dart';
import 'package:tacit_pulse_ai/core/utils/model_loader.dart';

void main() {
  // SharedPreferences (dipakai ModelManager) butuh binding Flutter.
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final modelA = Platform.environment['TACIT_RELOAD_MODEL_A'];
  final modelB = Platform.environment['TACIT_RELOAD_MODEL_B'];
  final modelRootOverride = Platform.environment['TACIT_MODEL_ROOT'];
  final skipReason = (modelA == null || modelB == null)
      ? 'set TACIT_RELOAD_MODEL_A + TACIT_RELOAD_MODEL_B '
          '(+ LD_LIBRARY_PATH libtacit_llama.so)'
      : false;

  // Model ada di direktori user, bukan app storage → override root data agar
  // resolusi path tidak butuh plugin path_provider.
  ModelPaths.dataRootOverride = () async =>
      Directory(modelRootOverride ?? '/tmp/tacit-reload-no-models');

  test('reload worker isolate model A -> B, family ikut berubah', () async {
    final llm = LLMInference.instance;
    addTearDown(() async {
      await llm.dispose();
      ModelManager.activeModelFileName = null;
      ModelManager.activeModelFamily = null;
      ModelPaths.dataRootOverride = null;
    });

    // 1 — muat model A.
    expect(await llm.initialize(modelFile: modelA), isTrue,
        reason: 'initialize model A: ${llm.startupError}');
    expect(llm.isReady, isTrue);
    final familyA = ModelManager.activeModelFamily;
    expect(familyA, ModelFamily.lfm2);

    final piecesA = await llm.generateStream('test', maxTokens: 8).toList();
    expect(piecesA.join(), isNotEmpty);

    // 2 + 3 — reload ke model B (Qwen).
    expect(await llm.reloadModel(modelB!), isTrue,
        reason: 'reload model B: ${llm.startupError}');
    expect(llm.isReady, isTrue);
    expect(ModelManager.activeModelFamily, ModelFamily.qwen);
    expect(ModelManager.activeModelFileName, modelB);

    // 4 — model B bisa generate (worker baru benar-benar hidup).
    final piecesB = await llm.generateStream('test', maxTokens: 8).toList();
    expect(piecesB.join(), isNotEmpty);

    // 5 — path tidak ada ditolak tanpa state rusak.
    expect(await llm.reloadModel('/tmp/does-not-exist.gguf'), isFalse);
    expect(llm.startupError, isNotNull);
  }, skip: skipReason);
}