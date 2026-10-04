import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/db/knowledge_chunks_db.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/citation.dart';
import '../../../core/native/llm_inference.dart';
import '../../../core/rag/prompts.dart';
import '../../../core/rag/rag_retriever_service.dart';
import '../../../core/services/translation_service.dart';
import '../../../core/utils/chatml.dart';
import '../../../core/utils/gguf_validator.dart' show ModelFamily;
import '../../../core/utils/model_loader.dart';
import '../../../core/utils/thinking_utils.dart';

enum ChatStatus { idle, streaming, recording, paused }

/// Batas karakter blok berpikir sebelum guard memaksa model menutup
/// ` response` (~384 token Qwen ≈ 1500 karakter).
const int kThinkingCharBudget = 1500;

/// Panjang substring yang diawasi guard pengulangan (spinning loop).
const int kThinkingRepeatWindow = 20;

/// Jumlah kemunculan substring sebelum dianggap loop (lebih dari 3x).
const int kThinkingRepeatLimit = 3;

/// Maksimum turn riwayat yang ikut dikirim sebagai context.
const int kMaxHistoryTurns = 12;

/// Membersihkan riwayat pesan dari blok pemikiran sebelum dikirim ke LLM,
/// supaya context tidak terpolusi oleh chain-of-thought. Mendukung format
/// literal Qwen (` thinking ... response`) maupun XML (`<thinking>...`).
String stripThinkingFromHistory(String messageContent) {
  final thinkRegex = RegExp(
    r' thinking.*? response|<thinking>.*?</thinking>|<think>.*?</think>',
    dotAll: true,
  );
  return messageContent.replaceAll(thinkRegex, '').trim();
}

/// Merakit body percakapan (format chat Qwen) dari riwayat + pertanyaan baru.
/// Blok berpikir pada jawaban asisten lama SELALU dibuang via
/// [stripThinkingFromHistory] — hanya jawaban final yang masuk context window.
String buildChatContextBody(String question, List<ChatMessage> history) {
  final recent = history.length > kMaxHistoryTurns
      ? history.sublist(history.length - kMaxHistoryTurns)
      : history;
  final buf = StringBuffer();
  for (final m in recent) {
    if (m.isStreaming) continue;
    final content = stripChatMlTokens((m.role == ChatRole.assistant
            ? stripThinkingFromHistory(m.text)
            : m.text)
        .trim());
    if (content.isEmpty) continue;
    buf.write('<|im_start|>${m.role == ChatRole.user ? 'user' : 'assistant'}\n'
        '$content<|im_end|>\n');
  }
  buf.write('<|im_start|>user\n${stripChatMlTokens(question.trim())}<|im_end|>\n');
  return buf.toString();
}

class ChatState {
  const ChatState({
    this.messages = const [],
    this.status = ChatStatus.idle,
    this.isModelLoaded = true,
    this.hallucinationGuard = false,
  });

  final List<ChatMessage> messages;
  final ChatStatus status;
  final bool isModelLoaded;
  final bool hallucinationGuard;

  ChatState copyWith({
    List<ChatMessage>? messages,
    ChatStatus? status,
    bool? isModelLoaded,
    bool? hallucinationGuard,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      status: status ?? this.status,
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
      hallucinationGuard: hallucinationGuard ?? this.hallucinationGuard,
    );
  }
}

/// Cubit RAG chat: output token real dari llama.cpp (via FFI) di-streaming
/// ke UI. Retrieval memakai RagRetrieverService (KNN cosine di tabel vec0
/// `knowledge_chunks`); bila model belum ter-load, tampilkan pesan status
/// eksplisit (bukan streaming tiruan).
/// Keputusan retrieval RAG untuk satu pertanyaan: systemPrompt, contextDocs,
/// dan citation yang diinjeksikan ke prompt + ditampilkan di UI.
class _Decision {
  const _Decision({
    required this.systemPrompt,
    required this.contextDocs,
    required this.citations,
  });

  final String systemPrompt;
  final String contextDocs;
  final List<SourceCitation> citations;
}

class ChatCubit extends Cubit<ChatState> {
  ChatCubit({LLMInference? llm, RagRetrieverService? rag})
    : _llm = llm ?? LLMInference.instance,
      _ragOverride = rag,
      super(const ChatState());

  final LLMInference _llm;
  final RagRetrieverService? _ragOverride;
  RagRetrieverService? _cachedRag;

  /// Pesan error startup native terakhir dari [LLMInference] (mis. C-API
  /// gagal alokasi RAM / quant incompatible), atau `null` bila sukses.
  /// Dipakai UI untuk menampilkan alasan kegagalan engine LLM Native.
  String? get startupError => _llm.startupError;

  StreamSubscription<String>? _llmSub;
  /// Buffer mentah hasil stream native. Sengaja TIDAK di-strip per-piece:
  /// memangkas token kontrol parsial (mis. `<|im_end`) di tengah stream akan
  /// merusak rangkaian token. Sanitasi dilakukan secara stateless dari
  /// seluruh buffer pada setiap tick.
  final StringBuffer _rawBuffer = StringBuffer();

  // State tracking blok berpikir untuk guard anti-loop & budget token.
  bool _thinkOpen = false;
  String _thinkBuffer = '';
  Stopwatch? _thinkWatch;
  int _thinkingSeconds = 0;

  /// Token pembuka blok berpikir yang sedang aktif (` thinking` / `<thinking>`)
  /// — dipakai agar tag penutup yang diinjeksi guard selalu cocok formatnya.
  String? _thinkOpenToken;

  /// Memastikan native backend+model siap (dipanggil sekali dari UI).
  /// Meng-update [ChatState.isModelLoaded] sesuai hasil inisialisasi.
  Future<void> init() async {
    // Sinkronkan flag opt-in Tier 3 (default OFF) + tier aktif agar cascade
    // translation tidak menunggu I/O disk di jalur panas.
    await ModelManager.refreshWebTranslationCache();
    _syncTranslationTiers();

    if (_llm.isReady) {
      emit(state.copyWith(isModelLoaded: true));
      return;
    }
    final ok = await _llm.initialize();
    if (!isClosed) {
      _syncTranslationTiers();
      emit(state.copyWith(isModelLoaded: ok, hallucinationGuard: ok));
    }
  }

  /// Sinkronkan state cascade translation dengan model yang benar-benar aktif.
  ///
  /// Tier 1 (Qwen 3.5 0.8B) = direct execution, middleware dilewati.
  /// Tier 2 (LFM2.5) = middleware NMT/web diteruskan.
  void _syncTranslationTiers() {
    TranslationService.instance
      ..tier1DirectModelActive = ModelManager.isTier1DirectExecution
      ..webTierEnabled = ModelManager.webTranslationEnabled;
  }

  /// Buka ulang LLM setelah user memilih/mengganti custom model path.
  /// Aman dipanggil ketika model sebelumnya belum ter-load (worker belum
  /// ada) maupun sudah load (worker akan di-dispose lalu di-init ulang).
  ///
  /// Coalescing: bila reload sedang berjalan (misal karena unduhan latar
  /// belakang selesai memberi dua pemicu sakaligus — sheet + listener ChatView),
  /// pemanggil berikutnya ikut menunggu hasil yang sama, mencegah double
  /// spawn worker.
  Future<void> reloadModel() {
    final pending = _reloading;
    if (pending != null) return pending;
    final future = _doReload();
    _reloading = future;
    return future.whenComplete(() {
      if (identical(_reloading, future)) _reloading = null;
    });
  }

  Future<void> _doReload() async {
    await _llm.dispose();
    if (isClosed) return;
    await init();
  }

  /// Muat model dari [newPath] (hasil "Simpan & Muat Model" di picker).
  ///
  /// Meneruskan path ke [LLMInference.reloadModel] — worker isolate lama
  /// (termasuk memori model C++) dihentikan, lalu worker baru di-spawn dengan
  /// GGUF tersebut. Setelah itu tier translation disinkronkan ulang dan state
  /// di-emit supaya badge model di header langsung ikut berubah.
  ///
  /// Mengembalikan `true` bila model baru siap dipakai.
  Future<bool> loadCustomModel(String newPath) async {
    stopGenerating();
    final ok = await _llm.reloadModel(newPath);
    if (isClosed) return ok;
    _syncTranslationTiers();
    emit(
      state.copyWith(
        isModelLoaded: ok,
        hallucinationGuard: ok,
        status: ChatStatus.idle,
      ),
    );
    debugPrint(
      '[ChatCubit] loadCustomModel: $newPath -> '
      '${ok ? 'siap' : 'GAGAL'} (${ModelManager.currentModelName}, '
      'family=${ModelManager.currentModelFamily.name})',
    );
    return ok;
  }

  Future<void>? _reloading;

  /// Menghentikan generasi yang sedang berjalan (streaming).
  void stopGenerating() {
    _llm.stopGeneration();
    _llmSub?.cancel();
    if (!isClosed && state.status == ChatStatus.streaming) {
      final msgs = state.messages.map((m) {
        if (!m.isStreaming) return m;
        return m.copyWith(isStreaming: false);
      }).toList();
      emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
    }
  }

  /// Tombol "Stop" pada composer: menghentikan generasi streaming secara
  /// imperatif. Berbeda dari [stopGenerating] — call ini menutup blok
  /// berpikir yang menggantung (injeksi tag penutup), menghentikan stopwatch
  /// [ChatMessage.thinkingSeconds], lalu menandai pesan selesai (bukan error).
  void stopStreaming() {
    if (isClosed || state.status != ChatStatus.streaming) return;
    _llmSub?.cancel();
    _llmSub = null;
    _llm.stopGeneration();
    if (isClosed) return;
    final streaming = state.messages.where((m) => m.isStreaming).toList();
    if (streaming.isEmpty) {
      emit(state.copyWith(status: ChatStatus.idle));
      return;
    }
    _finishStreaming(streaming.last.id);
  }

  /// Hapus percakapan dan reset context native (KV cache).
  Future<void> clearChat() async {
    stopGenerating();
    await _llm.resetContext();
    if (!isClosed) {
      emit(ChatState(isModelLoaded: state.isModelLoaded));
    }
  }

  /// Mengembalikan state pesan dari cache lokal persisten. Jangan menunda
  /// reset native KV cache — pesan yang dipulihkan adalah transcript
  /// tampilan, bukan context engine aktif (prompt dibangun ulang dari
  /// riwayat pada turn berikutnya).
  Future<void> restoreMessages(List<ChatMessage> messages) async {
    stopGenerating();
    if (isClosed) return;
    emit(
      state.copyWith(
        messages: List<ChatMessage>.unmodifiable(
          messages.map(
            (m) => m.copyWith(isStreaming: false, text: m.text),
          ),
        ),
        status: ChatStatus.idle,
      ),
    );
  }

  void startStreaming(String question) {
    if (state.status == ChatStatus.streaming ||
        state.status == ChatStatus.recording) {
      return;
    }
    // Retrieval RAG via KNN cosine di vec0 `knowledge_chunks` (ganti korpus
    // demo). Keputusan dipakai untuk systemPrompt, contextDocs, dan citation.
    final retrieval = _retrieve(question);

    // Snapshot riwayat SEBELUM turn baru ditambahkan, untuk context prompt.
    final history = List<ChatMessage>.of(state.messages);
    final userMsg = ChatMessage(
      id: 'm-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: question.trim().isEmpty
          ? 'Suara teknisi (tersegmentasi teks)'
          : question.trim(),
      timestamp: DateTime.now(),
    );
    emit(state.copyWith(messages: [...state.messages, userMsg]));

    emit(
      state.copyWith(
        messages: [
          ...state.messages,
          ChatMessage(
            id: 'm-${DateTime.now().microsecondsSinceEpoch + 1}',
            role: ChatRole.assistant,
            text: '',
            timestamp: DateTime.now(),
            isStreaming: true,
          ),
        ],
        status: ChatStatus.streaming,
        hallucinationGuard: true,
      ),
    );

    if (_llm.isReady) {
      unawaited(_startNativeTurn(question, history, retrieval: retrieval));
    } else {
      _emitModelNotReady();
    }
  }

  Set<String> _selectedDocsFilter = const <String>{};

  /// Update filter dokumen yang dipakai sebagai sumber retrieval RAG.
  /// Dipanggil dari UI setiap pilihan di sidebar KNOWLEDGE BASE berubah.
  void setSelectedDocsFilter(Set<String> docNames) {
    _selectedDocsFilter = Set<String>.of(docNames);
  }

  /// Hasil retrieval RAG untuk satu pertanyaan: chunk yang relevan ->
  /// systemPrompt + contextDocs + citation yang diinjeksikan ke prompt.
  Future<_Decision> _retrieve(String question) async {
    final rag = _ragOverride ?? await _defaultRag();
    // Koreksi typo umum yang sering muncul di input teknisi agar retrieval
    // berbanding benar (mis. ENTRIFUGAL → CENTRIFUGAL).
    final corrected = question.replaceAll(
      RegExp(r'ENTRIFUGAL', caseSensitive: false),
      'CENTRIFUGAL',
    );
    List<RetrievedChunk> chunks = const [];
    try {
      chunks = await rag.retrieve(corrected, topK: 8, minScore: 0.25);
    } catch (_) {
      chunks = const [];
    }
    if (_selectedDocsFilter.isNotEmpty) {
      chunks = chunks
          .where((c) => _selectedDocsFilter.contains(c.record.documentName))
          .toList();
    }
    chunks = chunks.take(4).toList();
    final usesRag = chunks.isNotEmpty;
    return _Decision(
      systemPrompt: usesRag ? kOperationalSystemPrompt : kGeneralSystemPrompt,
      contextDocs: usesRag
          ? chunks
                .map((c) => '[${chunks.indexOf(c) + 1}] '
                    '${c.record.documentName} (hlm. ${c.record.page}): '
                    '${c.record.chunkText}\n')
                .join('')
                .trim()
          : '',
      citations: chunks.map(_citationFromChunk).toList(),
    );
  }

  Future<RagRetrieverService> _defaultRag() async {
    if (_cachedRag != null) return _cachedRag!;
    final db = await KnowledgeChunksDb.open();
    _cachedRag = RagRetrieverService(db: db);
    return _cachedRag!;
  }

  SourceCitation _citationFromChunk(RetrievedChunk chunk) {
    return SourceCitation(
      id: chunk.record.id,
      title: chunk.record.documentName,
      type: CitationType.pdf,
      page: chunk.record.page,
      snippet: chunk.record.chunkText,
      score: chunk.similarity.clamp(0.0, 1.0),
      boundingBox: Rect.fromLTWH(
        chunk.record.x,
        chunk.record.y,
        chunk.record.w,
        chunk.record.h,
      ),
    );
  }

  /// Saat model LLM belum siap: pesan status eksplisit (bukan streaming tiruan).
  void _emitModelNotReady() {
    final msgs = state.messages.map((m) {
      if (!m.isStreaming) return m;
      return m.copyWith(
        text:
            'Model LLM belum dimuat. Pasang/pilih model GGUF di Pengaturan '
            'sebelum mengirim pesan.',
        isStreaming: false,
      );
    }).toList();
    emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
  }

  /// Jalankan satu turn native: siapkan prompt lewat cascade translation
  /// (Tier 1 direct / Tier 2 NMT offline / Tier 3 web / fallback direct),
  /// lalu stream jawaban ke [StringBuffer] [_rawBuffer].
  Future<void> _startNativeTurn(
    String question,
    List<ChatMessage> history, {
    required Future<_Decision> retrieval,
  }) async {
    final decision = await retrieval;
    if (isClosed) return;
    // Seed citasi pada bubble streaming setelah retrieval siap.
    final withCitations = state.messages.map((m) {
      if (!m.isStreaming) return m;
      return m.copyWith(citations: decision.citations);
    }).toList();
    emit(state.copyWith(messages: withCitations));
    final prepared = await _preparePrompt(question);
    if (isClosed) return;
    _streamNative(
      prepared.text,
      history,
      decision: decision,
      promptWasTranslated: prepared.wasTranslated,
    );
  }

  /// Cascade 3-tier untuk menyiapkan prompt yang dikirim ke LLM.
  ///
  /// Tier 1 (Qwen 3.5 0.8B) → prompt apa adanya (tanpa middleware).
  /// Tier 2 (LFM2.5) → `TranslationService` mencoba NMT offline lalu web
  /// publik (opt-in); bila semuanya gagal, teks asli diteruskan apa adanya
  /// sehingga LFM2.5 tetap menjawab (tidak ada bubble kosong).
  ///
  /// Mengembalikan [_PreparedPrompt] berisi teks final untuk LLM + flag
  /// apakah prompt diterjemahkan (dipakai untuk translasi balik EN→ID).
  Future<_PreparedPrompt> _preparePrompt(String question) async {
    _syncTranslationTiers();
    final outcome = await TranslationService.instance.translate(
      question,
      sourceLang: 'id',
      targetLang: 'en',
    );
    debugPrint(
      '[Translation] tier=${outcome.tier.label} '
      'translated=${outcome.wasTranslated}'
      '${outcome.error == null ? '' : ' reason="${outcome.error}"'}',
    );
    return _PreparedPrompt(
      text: outcome.text,
      wasTranslated: outcome.wasTranslated,
    );
  }

  /// Stream asli: token per-piece dari llama.cpp melalui worker isolate.
  /// [history] adalah riwayat pesan sebelum turn ini (context untuk LLM).
  /// [decision] hasil routing intent: memilih systemPrompt, contextDocs
  /// (referensi RAG) yang diinjeksikan ke prompt sistem.
  void _streamNative(
    String question,
    List<ChatMessage> history, {
    required _Decision decision,
    bool promptWasTranslated = false,
  }) {
    _thinkOpen = false;
    _thinkOpenToken = null;
    _thinkBuffer = '';
    _thinkWatch = null;
    _thinkingSeconds = 0;
    _rawBuffer.clear();
    _llmSub?.cancel();
    final assistantId = state.messages.lastWhere((m) => m.isStreaming).id;
    final contextBody = buildChatContextBody(question, history);
    _llmSub = _llm
        .generateStream(
          contextBody,
          systemPrompt: decision.systemPrompt,
          contextDocs: decision.contextDocs,
        )
        .listen(
          (piece) {
            if (isClosed) return;
            // Jaring pengaman ketiga: buang special token ChatML (utuh maupun
            // parsial seperti `<|im_end`) per piece SEBELUM tracking berpikir
            // dan sebelum digabung ke teks. Tanpa trim — menghilangkan spasi
            // per-piece merusak penggabungan kalimat.
            final clean = stripSpecialTokens(piece);
            debugPrint(
              '[LLM Stream] Raw Piece: "${jsonEncode(piece)}" | '
              'Cleaned: "${jsonEncode(clean)}"',
            );
            final injected = clean.isEmpty ? null : _trackThinking(clean);
            // Simpan buffer mentah TANPA stripping — memangkas token parsial
            // secara menyilang piece akan merusak rangkaian token.
            _rawBuffer.write(piece);
            if (injected != null) _rawBuffer.write(injected);
            // Sanitasi stateless dari SELURUH buffer tiap tick: token kontrol
            // ChatML hanya dibuang utuh, teks yang sudah selesai tetap utuh.
            final sanitizedFull = stripChatMlTokens(
              stripSpecialTokens(_rawBuffer.toString()),
            ).trimRight();
            final msgs = state.messages.map((m) {
              if (m.id != assistantId) return m;
              return m.copyWith(text: sanitizedFull);
            }).toList();
            emit(state.copyWith(messages: msgs));
          },
          onError: (Object error) => _finishStreaming(assistantId, error: error),
          onDone: () => _finishStreaming(
            assistantId,
            translateBackToIndonesian: promptWasTranslated,
          ),
        );
  }

  /// Menjaga model agar tidak nyangkut di blok berpikir tanpa henti.
  ///
  /// Mendukung format literal Qwen (` thinking`/` response`) maupun XML
  /// (`<thinking>`/`</thinking>`) — format ditentukan dari token pembuka yang
  /// muncul pertama kali pada piece.
  ///
  /// - Budget: bila konten berpikir melebihi [kThinkingCharBudget] karakter
  ///   tanpa tag penutup, injeksi tag penutup (format yang cocok).
  /// - Repetisi: bila substring 20 karakter berulang > [kThinkingRepeatLimit],
  ///   injeksi tag penutup (mencegah spinning infinite loop).
  String? _trackThinking(String piece) {
    if (!_thinkOpen) {
      final span = findThinkingSpan(piece);
      if (span == null) return null;
      final rest = piece.substring(span.startEnd);
      if (span.endIndex >= 0) {
        _thinkBuffer += rest.substring(0, span.endIndex - span.startEnd);
        _closeThinking();
        return null;
      }
      _thinkOpen = true;
      _thinkOpenToken = span.open;
      _thinkBuffer += rest;
      _thinkWatch = Stopwatch()..start();
      return _maybeForceClose();
    }
    final close = matchingCloseToken(_thinkOpenToken ?? kThinkingStartToken);
    final end = piece.indexOf(close);
    if (end >= 0) {
      _thinkBuffer += piece.substring(0, end);
      _closeThinking();
      return null;
    }
    _thinkBuffer += piece;
    return _maybeForceClose();
  }

  String? _maybeForceClose() {
    if (_thinkBuffer.length > kThinkingCharBudget ||
        _hasRepeatedSubstring(_thinkBuffer)) {
      _closeThinking();
      return matchingCloseTag(_thinkOpenToken ?? kThinkingStartToken);
    }
    return null;
  }

  bool _hasRepeatedSubstring(String text) {
    if (text.length < kThinkingRepeatWindow * (kThinkingRepeatLimit + 1)) {
      return false;
    }
    final counts = <String, int>{};
    for (var i = 0; i + kThinkingRepeatWindow <= text.length; i++) {
      final sub = text.substring(i, i + kThinkingRepeatWindow);
      final c = (counts[sub] ?? 0) + 1;
      if (c > kThinkingRepeatLimit) return true;
      counts[sub] = c;
    }
    return false;
  }

  void _closeThinking() {
    _thinkOpen = false;
    _thinkWatch?.stop();
    _thinkingSeconds = _thinkWatch?.elapsed.inSeconds ?? 0;
    _thinkWatch = null;
  }

  void _finishStreaming(
    String assistantId, {
    Object? error,
    bool translateBackToIndonesian = false,
  }) {
    if (isClosed) return;
    if (error != null) {
      debugPrint('[ChatCubit] stream error: $error');
    }
    if (_thinkOpen) _closeThinking();
    var backTranslateCandidate = false;
    final msgs = state.messages.map((m) {
      if (m.id != assistantId) return m;
      // Detail error native tidak ditampilkan ke pengguna (bisa berisi path
      // file / internal llama.cpp) — cukup log; UI kasih pesan generik.
      var text = m.text;
      if (error == null) {
        // Streaming berakhir padahal teks MASIH di dalam blok berpikir
        // (model tidak menutup tag) → injeksi tag penutup format yang cocok
        // agar blok tidak menggantung di UI/context.
        final span = findThinkingSpan(text);
        if (span != null && span.endIndex < 0) {
          text = '$text${matchingCloseTag(span.open)}';
        }
        // Buang blok reasoning KOSONG (tag pembuka/penutup tiba di piece
        // terpisah) dari teks final; blok berpikir berisi konten tidak
        // disentuh. Tanpa trim — menghilangkan whitespace eksekusi ubah
        // penggabungan teks dan sembunyikan bagian yang masih streaming.
        text = stripChatMlTokens(stripSpecialTokens(text));
        text = removeEmptyThinkingBlocks(text);
        text = text.trimRight();
        if (text.trim().isEmpty ||
            text.trim().toLowerCase() == 'assistant' ||
            text.trim().toLowerCase() == 'system' ||
            text.trim().toLowerCase() == 'user') {
          debugPrint(
            '[LLM Stream] empty final text — raw buffer '
            '(${_rawBuffer.length} chars): '
            '"${jsonEncode(_rawBuffer.toString())}"',
          );
          text =
              '⚠️ Model tidak menghasilkan jawaban. Pastikan file model GGUF '
              'valid dan telah dimuat dengan benar.';
        } else if (translateBackToIndonesian) {
          // Prompt sudah diterjemahkan ID→EN, jadi jawaban model (EN)
          // dikembalikan ke ID agar teknisi tetap membaca dalam bahasa
          // sendiri. Emit ditunda sampai translasi balik selesai.
          backTranslateCandidate = true;
        }
      } else {
        text = '$text\n\n⚠️ Gagal memproses. Periksa log untuk detail.';
      }
      return m.copyWith(
        isStreaming: false,
        text: text,
        thinkingSeconds: _thinkingSeconds,
      );
    }).toList();
    _thinkOpenToken = null;

    if (backTranslateCandidate) {
      // Tahan emit:_STATE belum final sampai translasi balik selesai, supaya
      // teknisi tidak pernah melihat jawaban Inggris.
      unawaited(_emitBackTranslated(assistantId, msgs));
      return;
    }
    emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
  }

  /// Translasi balik jawaban EN→ID lalu emit state final.
  ///
  /// Hanya berjalan bila model aktif keluarga LFM2 (bila model Tier 1/Qwen
  /// aktif, middleware memang tidak dipakai sehingga prompt & jawaban sudah
  /// konsisten). Bila translasi balik gagal / kosong, teks Inggris asli
  /// dipertahankan — lebih baik daripada bubble kosong.
  Future<void> _emitBackTranslated(
    String assistantId,
    List<ChatMessage> msgs,
  ) async {
    if (isClosed) return;
    try {
      if (ModelManager.currentModelFamily == ModelFamily.qwen) {
        emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
        return;
      }
      final english = msgs
          .firstWhere((m) => m.id == assistantId, orElse: () => msgs.last)
          .text;
      if (english.trim().isEmpty) {
        emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
        return;
      }

      _syncTranslationTiers();
      final outcome = await TranslationService.instance.translate(
        english,
        sourceLang: 'en',
        targetLang: 'id',
      );
      if (isClosed) return;
      debugPrint(
        '[Translation-back] tier=${outcome.tier.label} '
        'translated=${outcome.wasTranslated}',
      );

      final localized = outcome.wasTranslated ? outcome.text : english;
      final updated = msgs
          .map((m) => m.id == assistantId ? m.copyWith(text: localized) : m)
          .toList();
      emit(state.copyWith(messages: updated, status: ChatStatus.idle));
    } catch (e) {
      if (isClosed) return;
      debugPrint('[Translation-back] gagal: $e — teks Inggris dipertahankan');
      emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
    }
  }

  /// Placeholder rekaman suara: whisper.cpp akan mengembalikan
  /// teks hasil transkripsi on-device.
  void startVoiceRecording() {
    if (state.status == ChatStatus.streaming) return;
    emit(state.copyWith(status: ChatStatus.recording));
  }

  void stopVoiceRecording() {
    if (state.status != ChatStatus.recording) return;
    final voiceMsg = ChatMessage(
      id: 'm-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: 'Voice 0:12 · "Cara reset alarm AA-221 kompresor"',
      timestamp: DateTime.now(),
      isVoice: true,
      draftSopId: 'n-draft-1',
    );
    emit(
      state.copyWith(
        messages: [...state.messages, voiceMsg],
        status: ChatStatus.idle,
      ),
    );
  }

  @override
  Future<void> close() {
    _llmSub?.cancel();
    _llm.dispose();
    return super.close();
  }
}

/// Hasil [_preparePrompt]: teks prompt untuk LLM + apakah prompt itu
/// diterjemahkan (ID→EN) oleh cascade.
///
/// Flag ini menentukan apakah jawaban model perlu diterjemahkan balik
/// EN→ID sebelum ditampilkan ke teknisi.
class _PreparedPrompt {
  const _PreparedPrompt({required this.text, required this.wasTranslated});

  final String text;
  final bool wasTranslated;
}
