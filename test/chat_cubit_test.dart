import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/models/chat_message.dart';
import 'package:tacit_pulse_ai/core/native/llm_inference.dart';
import 'package:tacit_pulse_ai/core/rag/intent_router.dart';
import 'package:tacit_pulse_ai/core/utils/thinking_utils.dart';
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

  /// Prompt terakhir yang dikirim ke `generateStream` (untuk verifikasi
  /// sanitasi riwayat / composition context).
  String? lastPrompt;

  /// systemPrompt / contextDocs terakhir yang diterima `generateStream`
  /// (verifikasi prompt conditioning hasil intent routing).
  String? lastSystemPrompt;
  String? lastContextDocs;

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
    String? contextDocs = '',
  }) async =>
      null;

  @override
  Stream<String> generateStream(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    String? systemPrompt,
    String? contextDocs = '',
  }) {
    final error = errorToThrow;
    if (error != null) return Stream<String>.error(error);
    lastPrompt = prompt;
    lastSystemPrompt = systemPrompt;
    lastContextDocs = contextDocs;
    return pieces ?? const Stream<String>.empty();
  }

  @override
  void stopGeneration() {}

  @override
  Future<void> resetContext() async {}

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

  test('stopStreaming -> generasi berhenti, pesan tetap utuh tanpa warning',
      () async {
    final controller = StreamController<String>(sync: true);
    final fake = FakeLLM()..pieces = controller.stream;
    final cubit = ChatCubit(llm: fake);

    cubit.startStreaming('tes stop');
    expect(cubit.state.status, ChatStatus.streaming);

    controller.add('Sebagian jawaban ');
    await pumpEventQueue();
    final partial = assistantMessage(cubit).text;
    expect(partial, contains('Sebagian jawaban'));

    cubit.stopStreaming();
    await pumpEventQueue();
    controller.close();

    expect(cubit.state.status, ChatStatus.idle);
    final assistant = assistantMessage(cubit);
    expect(assistant.isStreaming, isFalse);
    expect(assistant.text, partial);
    expect(assistant.text, isNot(contains('⚠️')));

    await cubit.close();
  });

  test('stopStreaming di saat idle adalah no-op (tidak crash)', () {
    final cubit = ChatCubit(llm: FakeLLM(ready: true));
    final before = cubit.state;
    cubit.stopStreaming();
    expect(cubit.state.status, before.status);
  });

  group('stripThinkingFromHistory', () {
    test('membuang blok  berpikir dan menyisakan jawaban final', () {
      const raw = '  mencari data historis...  ';
      expect(stripThinkingFromHistory(raw), isNot(contains('thinking')));
      expect(stripThinkingFromHistory(raw), isNot(contains('response')));
    });

    test('membuang blok format XML <thinking>...</thinking>', () {
      const raw = '$kXmlThinkingStartToken rahasia pemikiran$kXmlThinkingEndToken '
          'Jawaban final.';
      expect(stripThinkingFromHistory(raw), 'Jawaban final.');
      expect(stripThinkingFromHistory(raw), isNot(contains('rahasia')));
    });

    test('teks tanpa blok berpikir tidak berubah', () {
      const clean =
          'Buka valve pelan-pelan sampai tekanan stabil di 3,5 bar.';
      expect(stripThinkingFromHistory(clean), clean);
    });
  });

  group('context history sanitization', () {
    test('jawaban asisten lama tetap utuh, blok berpikir DIBUANG dari prompt',
        () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          'Oke $kThinkingStartToken bandingkan dua opsi dulu',
          ' ada risiko overheat',
          kThinkingEndToken,
          '\nPilih Opsi A karena lebih aman.',
        ]);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('Bandingkan opsi A dan B?');
      await pumpEventQueue();

      final first = assistantMessage(cubit);
      expect(thinkingContent(first.text), isNotNull);
      expect(first.text, contains(' bandingkan dua opsi dulu'));

      // Turn kedua — prompt context harus bebas blok berpikir turn pertama.
      fake.pieces = Stream.fromIterable(['Jawaban turn kedua.']);
      cubit.startStreaming('Pertanyaan kedua?');
      await pumpEventQueue();

      final prompt = fake.lastPrompt ?? '';
      expect(prompt, contains('Pilih Opsi A karena lebih aman.'));
      expect(prompt, isNot(contains(' thinking')));
      expect(prompt, isNot(contains('bandingkan dua opsi')));
      expect(prompt, contains('<|im_start|>user\nPertanyaan kedua?<|im_end|>'));

      await cubit.close();
    });
  });

  group('thinking loop guardrails', () {
    test('budget: konten berpikir > batas memicu injeksi  response',
        () async {
      // Satu potong streaming > 1500 karakter di dalam  thinking.
      final longThink =
          'Pertimbangan $kThinkingStartToken cek log sensor dulu'
          '${'x' * 1600}';
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([longThink, 'Ini jawaban akhir.']);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('Apakah aman melanjutkan mesin?');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, contains(kThinkingEndToken));
      expect(answerContent(assistant.text), 'Ini jawaban akhir.');

      await cubit.close();
    });

    test('repetisi: substring 20 karakter berulang >3x memicu injeksi',
        () async {
      final repeated = 'yoloyoloyoloyoloyolo' * 5; // window 20 muncul 5x
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          'Hmm $kThinkingStartToken $repeated',
          'Jawaban ringkas.',
        ]);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('tes loop');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, contains(' response'));
      expect(answerContent(assistant.text), 'Jawaban ringkas.');

      await cubit.close();
    });

    test('stream selesai saat masih di dalam  thinking -> tag ditutup paksa',
        () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['Masih $kThinkingStartToken belum kelar mikir...']);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('tes');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(isInsideThinkingBlock(assistant.text), isFalse);
      expect(assistant.text, contains(' response'));

      await cubit.close();
    });

    test('blok XML <thinking> dipantau & dijawab tanpa inject literal',
        () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          '$kXmlThinkingStartToken bandingkan dulu',
          ' lalu cek SOP',
          kXmlThinkingEndToken,
          '\nJawaban final.',
        ]);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('q');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(thinkingContent(assistant.text), 'bandingkan dulu lalu cek SOP');
      expect(answerContent(assistant.text), 'Jawaban final.');
      expect(assistant.text, isNot(contains(' response')));

      await cubit.close();
    });

    test('budget blok XML -> injeksi </thinking> (format cocok)', () async {
      final longThink =
          'Pertimbangan $kXmlThinkingStartToken cek log sensor dulu'
          '${'x' * 1600}';
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([longThink, 'Ini jawaban akhir.']);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('Apakah aman?');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, contains(kXmlThinkingEndToken));
      expect(answerContent(assistant.text), 'Ini jawaban akhir.');

      await cubit.close();
    });
  });

  group('special token sanitasi per-piece', () {
    test('token ChatML utuh & parsial di potongan stream tidak bocor ke UI',
        () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          'Cek ',
          '<|im_start|>checksum asli jangan bocor<|im_end|>',
          '<|im_end',
          ' lanjut',
        ]);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('cek');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, 'Cek checksum asli jangan bocor lanjut');
      expect(assistant.text, isNot(contains('<|')));
      expect(assistant.text, isNot(contains('</s')));

      await cubit.close();
    });

    test('potongan berisi token parsial saja tidak meninggalkan jejak',
        () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['<|im_end', '<|im_start']);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('q');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, isEmpty);
      expect(cubit.state.status, ChatStatus.idle);

      await cubit.close();
    });
  });

  group('intent routing & prompt conditioning', () {
    test('fast path salam -> tanpa citation, prompt umum, contextDocs kosong',
        () async {
      final fake = FakeLLM()..pieces = Stream.fromIterable(['Halo!']);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('hai, terima kasih');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.citations, isEmpty);
      expect(fake.lastSystemPrompt, kGeneralSystemPrompt);
      expect(fake.lastContextDocs, isEmpty);

      await cubit.close();
    });

    test('pertanyaan RAG -> citation dari korpus + prompt operasional',
        () async {
      final fake = FakeLLM()..pieces = Stream.fromIterable(['Tekanan 3,5 bar.']);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming(
        'Berapa tekanan oli yang benar saat cold start kompresor screw?',
      );
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.citations, isNotEmpty);
      expect(fake.lastSystemPrompt, kOperationalSystemPrompt);
      expect(fake.lastContextDocs, contains('SOP PM-KOM-014: Cold Start'));

      await cubit.close();
    });

    test('tidak ada kecocokan korpus -> context dikosongkan (prompt umum)',
        () async {
      final fake = FakeLLM()..pieces = Stream.fromIterable(['Ok.']);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('Ceritakan tentang pemeliharaan mesin?');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.citations, isEmpty);
      expect(fake.lastSystemPrompt, kGeneralSystemPrompt);
      expect(fake.lastContextDocs, isEmpty);

      await cubit.close();
    });
  });

  group('empty thinking block cleanup', () {
    test('blok reasoning kosong lintas piece dibuang dari teks final',
        () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          'Halo  thinking',
          '  response',
          ' Jawaban akhir.',
        ]);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('hai');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, isNot(contains('thinking')));
      expect(assistant.text, isNot(contains('response')));
      expect(assistant.text, contains('Jawaban akhir.'));

      await cubit.close();
    });

    test('blok berpikir berisi konten TIDAK dihapus', () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          'Prolog  thinking mikir dulu  response Jawaban.',
        ]);
      final cubit = ChatCubit(llm: fake);

      cubit.startStreaming('tes');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(thinkingContent(assistant.text), isNotNull);
      expect(assistant.text, contains('mikir dulu'));
      expect(answerContent(assistant.text), 'Jawaban.');

      await cubit.close();
    });
  });
}