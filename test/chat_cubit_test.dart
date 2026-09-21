import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/models/chat_message.dart';
import 'package:tacit_pulse_ai/core/native/llm_inference.dart';
import 'package:tacit_pulse_ai/features/chat/cubit/chat_cubit.dart';

/// Fake `LLMInference` tanpa native: test mengontrol persis apa yang
/// `generateStream` hasilkan (potongan teks / error).
class FakeLLM implements LLMInference {
  FakeLLM({this.ready = true});

  final bool ready;

  /// Kalau di-set, generateStream meng-emit error ini.
  LLMInferenceException? errorToThrow;

  /// Kalau di-set (dan errorToThrow null), yield potongan dari stream ini.
  Stream<String>? pieces;

  @override
  bool get isReady => ready;

  @override
  bool get isModelOnDisk => ready;

  @override
  String? get startupError => null;

  @override
  String? get modelPath => null;

  @override
  Future<bool> initialize({String? modelFile}) async => ready;

  @override
  Future<String?> generate(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    String? systemPrompt,
  }) async =>
      null;

  @override
  Stream<String> generateStream(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    String? systemPrompt,
  }) {
    final error = errorToThrow;
    if (error != null) return Stream<String>.error(error);
    return pieces ?? const Stream<String>.empty();
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  // Pesan yang menyimulasikan detail native (path file, info internal).
  const kNativeDetail =
      'native:/data/app/models/qwen3.5-0.8b-q4_k_m.gguf: KV cache full '
      '(increase context size)';

  ChatMessage assistantMessage(ChatCubit cubit) =>
      cubit.state.messages.lastWhere((m) => m.role == ChatRole.assistant);

  test('native error during streaming -> state cleaned up, generic message shown',
      () async {
    final fake = FakeLLM()..errorToThrow = LLMInferenceException(kNativeDetail);
    final cubit = ChatCubit(llm: fake);

    cubit.startStreaming('Cara reset alarm AA-221 kompresor?');
    // Status streaming diaktifkan saat memulai.
    expect(cubit.state.status, ChatStatus.streaming);

    await pumpEventQueue();

    expect(cubit.state.status, ChatStatus.idle);
    final assistant = assistantMessage(cubit);
    expect(assistant.isStreaming, isFalse);
    // Pesan user-friendly generik muncul…
    expect(assistant.text, contains('⚠️ Gagal memproses'));
    // …tapi detail native TIDAK bocor ke UI.
    expect(assistant.text, isNot(contains(kNativeDetail)));

    await cubit.close();
  });

  test('normal completion -> text streamed, no warning appended', () async {
    final fake = FakeLLM()
      ..pieces = Stream.fromIterable(['Alarm', ' ', 'AA-221', ' ', 'reset']);

    final cubit = ChatCubit(llm: fake);
    cubit.startStreaming('hai');

    await pumpEventQueue();

    final assistant = assistantMessage(cubit);
    expect(assistant.isStreaming, isFalse);
    expect(assistant.text, 'Alarm AA-221 reset');
    expect(assistant.text, isNot(contains('⚠️')));

    await cubit.close();
  });

  test('model not ready -> mock fallback runs without error note', () async {
    final cubit = ChatCubit(llm: FakeLLM(ready: false));
    cubit.startStreaming('tes');

    // Mock berjalan lewat Timer.periodic (tidak selesai di pumpEventQueue) —
    // yang dijamin: status streaming ter-set dan belum ada warning apapun.
    expect(cubit.state.status, ChatStatus.streaming);
    final assistant = assistantMessage(cubit);
    expect(assistant.isStreaming, isTrue);
    expect(assistant.text, isNot(contains('⚠️')));

    await cubit.close(); // membatalkan timer mock
  });
}