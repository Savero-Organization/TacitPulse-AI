import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/citation.dart';
import '../../../core/native/llm_inference.dart';
import '../../mock_data.dart';

enum ChatStatus { idle, streaming, recording, paused }

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

  Timer? _tokenTimer;
  StreamSubscription<String>? _llmSub;
  int _wordIndex = 0;

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

  void startStreaming(String question) {
    if (state.status == ChatStatus.streaming ||
        state.status == ChatStatus.recording) {
      return;
    }
    final userMsg = ChatMessage(
      id: 'm-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: question.trim().isEmpty
          ? 'Suara teknisi (tersegmentasi teks)'
          : question.trim(),
      timestamp: DateTime.now(),
    );
    emit(state.copyWith(messages: [...state.messages, userMsg]));

    final citationStream = <SourceCitation>[
      const SourceCitation(
        id: 'c-stream-1',
        title: 'SOP PM-KOM-014: Cold Start Kompresor Screw',
        type: CitationType.sop,
        page: 3,
        snippet: 'Cold start kompresor screw: tekanan oli stabil 3,5 bar dalam 5 detik.',
        score: 0.87,
      ),
      const SourceCitation(
        id: 'c-stream-2',
        title: 'Log Anomali Mesin - Line 2',
        type: CitationType.worklog,
        page: 1,
        snippet: 'Output token via llama.cpp (Qwen 3.5-0.8B Q4_K_M) on-device.',
        score: 0.64,
      ),
    ];

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
            citations: citationStream,
          ),
        ],
        status: ChatStatus.streaming,
        hallucinationGuard: true,
      ),
    );

    if (_llm.isReady) {
      _streamNative(question);
    } else {
      _streamMock();
    }
  }

  /// Stream asli: token per-piece dari llama.cpp melalui worker isolate.
  void _streamNative(String question) {
    _llmSub?.cancel();
    final assistantId = state.messages.lastWhere((m) => m.isStreaming).id;
    _llmSub = _llm
        .generateStream(question)
        .listen(
          (piece) {
            if (isClosed) return;
            final msgs = state.messages.map((m) {
              if (m.id != assistantId) return m;
              return m.copyWith(text: m.text.isEmpty ? piece : m.text + piece);
            }).toList();
            emit(state.copyWith(messages: msgs));
          },
          onError: (Object error) => _finishStreaming(assistantId),
          onDone: () => _finishStreaming(assistantId),
        );
  }

  void _finishStreaming(String assistantId) {
    if (isClosed) return;
    final msgs = state.messages.map((m) {
      if (m.id != assistantId) return m;
      return m.copyWith(isStreaming: false);
    }).toList();
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
    return super.close();
  }
}
