import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/native/llm_inference.dart';
import '../../../core/rag/intent_router.dart';
import '../../../core/utils/thinking_utils.dart';
import '../../mock_data.dart';

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
    r' thinking.*? response|<thinking>.*?</thinking>',
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
    final content = (m.role == ChatRole.assistant
            ? stripThinkingFromHistory(m.text)
            : m.text)
        .trim();
    if (content.isEmpty) continue;
    buf.write('<|im_start|>${m.role == ChatRole.user ? 'user' : 'assistant'}\n'
        '$content<|im_end|>\n');
  }
  buf.write('<|im_start|>user\n${question.trim()}<|im_end|>\n');
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
/// ke UI. Kalau model belum ter-load (tidak ada .gguf), jatuh ke simulasi
/// mock supaya demo tetap berjalan.
class ChatCubit extends Cubit<ChatState> {
  ChatCubit({LLMInference? llm})
    : _llm = llm ?? LLMInference.instance,
      super(ChatState(messages: MockData.buildMessages()));

  final LLMInference _llm;

  /// Pesan error startup native terakhir dari [LLMInference] (mis. C-API
  /// gagal alokasi RAM / quant incompatible), atau `null` bila sukses.
  /// Dipakai UI untuk menampilkan alasan kegagalan engine LLM Native.
  String? get startupError => _llm.startupError;

  Timer? _tokenTimer;
  StreamSubscription<String>? _llmSub;
  int _wordIndex = 0;

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
    if (_llm.isReady) {
      emit(state.copyWith(isModelLoaded: true));
      return;
    }
    final ok = await _llm.initialize();
    if (!isClosed) {
      emit(state.copyWith(isModelLoaded: ok, hallucinationGuard: ok));
    }
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

  Future<void>? _reloading;

  /// Menghentikan generasi yang sedang berjalan (streaming).
  void stopGenerating() {
    _llm.stopGeneration();
    _tokenTimer?.cancel();
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
    _tokenTimer?.cancel();
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
      emit(ChatState(messages: MockData.buildMessages()));
    }
  }

  void startStreaming(String question) {
    if (state.status == ChatStatus.streaming ||
        state.status == ChatStatus.recording) {
      return;
    }
    // Routing intent shallow: fast path (salam/math/frasa pendek) lewat tanpa
    // RAG; pertanyaan operasional di-skoring ke korpus (ambang 0.35). Keputusan
    // dipakai untuk systemPrompt, contextDocs, dan citation yang ditampilkan.
    final decision = IntentRouter.instance.route(question);

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
            citations: decision.citations,
          ),
        ],
        status: ChatStatus.streaming,
        hallucinationGuard: true,
      ),
    );

    if (_llm.isReady) {
      _streamNative(question, history, decision: decision);
    } else {
      _streamMock();
    }
  }

  /// Stream asli: token per-piece dari llama.cpp melalui worker isolate.
  /// [history] adalah riwayat pesan sebelum turn ini (context untuk LLM).
  /// [decision] hasil routing intent: memilih systemPrompt, contextDocs
  /// (referensi RAG) yang diinjeksikan ke prompt sistem.
  void _streamNative(
    String question,
    List<ChatMessage> history, {
    required RoutingDecision decision,
  }) {
    _thinkOpen = false;
    _thinkOpenToken = null;
    _thinkBuffer = '';
    _thinkWatch = null;
    _thinkingSeconds = 0;
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
            if (clean.isEmpty) return;
            final injected = _trackThinking(clean);
            final msgs = state.messages.map((m) {
              if (m.id != assistantId) return m;
              var text = m.text.isEmpty ? clean : m.text + clean;
              if (injected != null) text = '$text$injected';
              return m.copyWith(text: text);
            }).toList();
            emit(state.copyWith(messages: msgs));
          },
          onError: (Object error) => _finishStreaming(assistantId, error: error),
          onDone: () => _finishStreaming(assistantId),
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

  void _finishStreaming(String assistantId, {Object? error}) {
    if (isClosed) return;
    if (error != null) {
      debugPrint('[ChatCubit] stream error: $error');
    }
    if (_thinkOpen) _closeThinking();
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
        text = removeEmptyThinkingBlocks(text);
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
    emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
  }

  /// Fallback simulasi (dipakai kalau model belum ada / native tidak siap).
  void _streamMock() {
    _wordIndex = 0;
    _tokenTimer?.cancel();
    _tokenTimer = Timer.periodic(const Duration(milliseconds: 140), (_) {
      if (isClosed) return;
      final words = MockData.streamWords;
      if (_wordIndex >= words.length) {
        _tokenTimer?.cancel();
        final msgs = state.messages
            .map((m) => m.isStreaming ? m.copyWith(isStreaming: false) : m)
            .toList();
        emit(state.copyWith(messages: msgs, status: ChatStatus.idle));
        return;
      }
      final next = _wordIndex <= words.length ? words[_wordIndex] : '';
      final msgs = state.messages.map((m) {
        if (!m.isStreaming) return m;
        return ChatMessage(
          id: m.id,
          role: m.role,
          text: m.text.isEmpty ? next : '${m.text} $next',
          timestamp: m.timestamp,
          isStreaming: true,
          citations: m.citations,
        );
      }).toList();
      _wordIndex++;
      emit(state.copyWith(messages: msgs));
    });
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
    _tokenTimer?.cancel();
    _llmSub?.cancel();
    _llm.dispose();
    return super.close();
  }
}
