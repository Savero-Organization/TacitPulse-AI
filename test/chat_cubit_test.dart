import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/models/chat_message.dart';
import 'package:tacit_pulse_ai/core/native/llm_inference.dart';
import 'package:tacit_pulse_ai/core/db/knowledge_chunks_db.dart';
import 'package:tacit_pulse_ai/core/rag/prompts.dart';
import 'package:tacit_pulse_ai/core/rag/rag_retriever_service.dart';
import 'package:tacit_pulse_ai/core/services/translation_service.dart';
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

  /// Path terakhir yang diteruskan ke `reloadModel` (verifikasi reload worker
  /// isolate memakai path eksplisit dari picker).
  String? lastReloadedPath;

  /// Hasil yang dikembalikan `reloadModel` (default = ready).
  bool? reloadResult;

  @override
  Future<bool> reloadModel(String modelPath) async {
    lastReloadedPath = modelPath;
    return reloadResult ?? ready;
  }

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


/// Retriever palsu: hanya menjawab seolah menemukan dokumen kompresor untuk
/// query yang mengandung 'kompresor'; selain itu kosong (prompt umum).
RagRetrieverService fakeRag() {
  RetrievedChunk? current;
  return RagRetrieverService(
    embedder: (q) async {
      current = q.toLowerCase().contains('kompresor')
          ? RetrievedChunk(
              record: KnowledgeChunkRecord(
                id: 'c-1',
                documentName: 'SOP PM-KOM-014: Cold Start Kompresor Screw',
                page: 3,
                chunkText: 'Tekanan oli 3,5 bar saat cold start.',
                x: 0.06,
                y: 0.28,
                w: 0.72,
                h: 0.16,
                embedding: <double>[],
                distance: 0.0,
              ),
              similarity: 1.0,
            )
          : null;
      return const <double>[1, 0];
    },
    search: (v, {k = 0}) =>
        current == null ? <KnowledgeChunkRecord>[] : [current!.record],
  );
}

ChatCubit makeCubit(LLMInference llm) => ChatCubit(llm: llm, rag: fakeRag());

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
    final cubit = makeCubit(fake);

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

    final cubit = makeCubit(fake);
    cubit.startStreaming('hai');

    await pumpEventQueue();

    final assistant = assistantMessage(cubit);
    expect(assistant.isStreaming, isFalse);
    expect(assistant.text, 'Alarm AA-221 reset');
    expect(assistant.text, isNot(contains('⚠️')));

    await cubit.close();
  });

  test('model not ready -> pesan status eksplisit (bukan streaming tiruan)', () async {
    final cubit = makeCubit(FakeLLM(ready: false));
    cubit.startStreaming('tes');

    expect(cubit.state.status, ChatStatus.idle);
    final assistant = assistantMessage(cubit);
    expect(assistant.isStreaming, isFalse);
    expect(assistant.text, contains('Model LLM belum dimuat'));

    await cubit.close();
  });

  test('stopStreaming -> generasi berhenti, pesan tetap utuh tanpa warning',
      () async {
    final controller = StreamController<String>(sync: true);
    final fake = FakeLLM()..pieces = controller.stream;
    final cubit = makeCubit(fake);

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
    final cubit = makeCubit(FakeLLM(ready: true));
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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

      cubit.startStreaming('Apakah aman?');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, contains(kXmlThinkingEndToken));
      expect(answerContent(assistant.text), 'Ini jawaban akhir.');

      await cubit.close();
    });
  });

  group('streaming full-buffer sanitization', () {
    test('fragmented ChatML tokens dipotong sebagai satu kesatuan', () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          'Hasil analisis: ok.',
          ' <|',
          'im',
          '_end|>',
        ]);
      final cubit = makeCubit(fake);

      cubit.startStreaming('cek');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, 'Hasil analisis: ok.');
      expect(assistant.text, isNot(contains('<|im')));
      expect(assistant.text, isNot(contains('_end')));

      await cubit.close();
    });

    test('empty model output tetap fallback', () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['<|im_start|>assistant\n<|im_end|>']);
      final cubit = makeCubit(fake);

      cubit.startStreaming('test');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text.trim(), isNotEmpty);
      expect(assistant.text,
          contains('⚠️ Model tidak menghasilkan jawaban.'));

      await cubit.close();
    });

    test('streaming <think> menyimpan reasoning & answer terpisah', () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          '<think>cek log sensor</think>Jawaban final',
        ]);
      final cubit = makeCubit(fake);

      cubit.startStreaming('cek');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(thinkingContent(assistant.text), 'cek log sensor');
      expect(answerContent(assistant.text), 'Jawaban final');

      await cubit.close();
    });
  });

  group('special token sanitasi per-piece', () {
    test('multi-line completion response dipertahankan saat stripping', () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['Jawaban\nmultiline\nyang bersih\n<|im_start|>\n']);
      final cubit = makeCubit(fake);

      cubit.startStreaming('q');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, 'Jawaban\nmultiline\nyang bersih');

      await cubit.close();
    });

    test('token ChatML utuh & parsial di potongan stream tidak bocor ke UI',
        () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable([
          'Cek ',
          '<|im_start|>checksum asli jangan bocor<|im_end|>',
          '<|im_end',
          ' lanjut',
        ]);
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

      cubit.startStreaming('q');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      // Stream yang hanya berisi token kontrol selesai sebagai fallback
      // empty-response, bukan mengeluarkan jejak token mentah.
      expect(assistant.text,
          contains('⚠️ Model tidak menghasilkan jawaban.'));
      expect(cubit.state.status, ChatStatus.idle);

      await cubit.close();
    });

    test('tail <|im_end|> pada jawaban selesai terhapus', () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['Jawaban ringkas.', '<|im_end|>']);
      final cubit = makeCubit(fake);

      cubit.startStreaming('cek');
      await pumpEventQueue();

      expect(assistantMessage(cubit).text, 'Jawaban ringkas.');
      await cubit.close();
    });

    test('tail parsial <|im pada piece akhir terhapus dari UI', () async {
      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['Jawaban ringkas.', '<|im']);
      final cubit = makeCubit(fake);

      cubit.startStreaming('cek');
      await pumpEventQueue();

      expect(assistantMessage(cubit).text, 'Jawaban ringkas.');
      await cubit.close();
    });
  });

  group('intent routing & prompt conditioning', () {
    test('fast path salam -> tanpa citation, prompt umum, contextDocs kosong',
        () async {
      final fake = FakeLLM()..pieces = Stream.fromIterable(['Halo!']);
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

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
      final cubit = makeCubit(fake);

      cubit.startStreaming('tes');
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(thinkingContent(assistant.text), isNotNull);
      expect(assistant.text, contains('mikir dulu'));
      expect(answerContent(assistant.text), 'Jawaban.');

      await cubit.close();
    });
  });

  group('loadCustomModel (worker isolate reload)', () {
    test('path diteruskan ke LLMInference.reloadModel + state ter-emit',
        () async {
      final fake = FakeLLM();
      final cubit = makeCubit(fake);

      final ok = await cubit.loadCustomModel(
        '/home/savero/AI/models/Qwen3.5-0.8B-Q4_K_M.gguf',
      );

      expect(ok, isTrue);
      expect(fake.lastReloadedPath, contains('Qwen3.5-0.8B-Q4_K_M.gguf'));
      expect(cubit.state.isModelLoaded, isTrue);
      expect(cubit.state.status, ChatStatus.idle);

      await cubit.close();
    });

    test('reload gagal → isModelLoaded false, tidak crash', () async {
      final fake = FakeLLM()..reloadResult = false;
      final cubit = makeCubit(fake);

      final ok = await cubit.loadCustomModel('/models/broken.gguf');

      expect(ok, isFalse);
      expect(cubit.state.isModelLoaded, isFalse);

      await cubit.close();
    });
  });

  group('two-way translation ID -> EN -> ID', () {
    test('prompt diterjemahkan → jawaban EN dikembalikan ke ID', () async {
      // Model aktif LFM2 (bukan Tier 1) + NMT offline aktif untuk ID->EN.
      final nmt = _RecordingNmt(
        translations: {
          'ganti solenoid pompa': 'replace the pump solenoid',
        },
        reverse: {'Replace the pump solenoid.': 'Ganti solenoid pompa.'},
      );
      TranslationService.instance
        ..tier1DirectModelActive = false
        ..webTierEnabled = false
        ..localNmtProvider = nmt;
      TranslationService.instance.clearCache();

      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['Replace', ' the pump solenoid.']);
      final cubit = makeCubit(fake);

      cubit.startStreaming('ganti solenoid pompa');
      // pumps: preparePrompt (async) + stream + back-translate.
      await pumpEventQueue();
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      expect(assistant.text, 'Ganti solenoid pompa.');
      expect(assistant.text, isNot(contains('Replace')));
      expect(assistant.isStreaming, isFalse);

      TranslationService.instance.localNmtProvider = MarianNmtProvider();
      await cubit.close();
    });

    test('prompt TIDAK diterjemahkan (Tier 1) → jawaban tidak di-back-translate',
        () async {
      TranslationService.instance
        ..tier1DirectModelActive = true
        ..webTierEnabled = false
        ..localNmtProvider = _RecordingNmt(translations: const {});
      TranslationService.instance.clearCache();

      final fake = FakeLLM()
        ..pieces = Stream.fromIterable(['Replace', ' the pump solenoid.']);
      final cubit = makeCubit(fake);

      cubit.startStreaming('ganti solenoid pompa');
      await pumpEventQueue();
      await pumpEventQueue();

      final assistant = assistantMessage(cubit);
      // Model Tier 1 menjawab langsung dalam bahasa user — teks apa adanya.
      expect(assistant.text, 'Replace the pump solenoid.');

      TranslationService.instance
        ..tier1DirectModelActive = false
        ..localNmtProvider = MarianNmtProvider();
      await cubit.close();
    });
  });
}

/// NMT offline palsu: mencatat panggilan + menyediakan tabel hasil terjemahan
/// (kunci exact) untuk menguji cascade dua arah.
class _RecordingNmt implements LocalNmtProvider {
  _RecordingNmt({required this.translations, this.reverse = const {}});

  final Map<String, String> translations;
  final Map<String, String> reverse;

  @override
  Future<bool> isAvailable(String sourceLang, String targetLang) async => true;

  @override
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final table = sourceLang == 'id' ? translations : reverse;
    return table[text] ?? text;
  }
}
