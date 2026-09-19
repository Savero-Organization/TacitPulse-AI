import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/citation.dart';
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

/// Cubit simulasi RAG chat: output token stream llama.cpp akan
/// dihubungkan ke [streamWord] dari native FFI nanti.
class ChatCubit extends Cubit<ChatState> {
  ChatCubit() : super(ChatState(messages: MockData.buildMessages()));

  Timer? _tokenTimer;
  int _wordIndex = 0;

  void startStreaming(String question) {
    if (state.status == ChatStatus.streaming || state.status == ChatStatus.recording) return;
    final userMsg = ChatMessage(
      id: 'm-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: question.trim().isEmpty ? 'Suara teknisi (tersegmentasi teks)' : question.trim(),
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

    emit(state.copyWith(
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
    ));

    _wordIndex = 0;
    _tokenTimer?.cancel();
    _tokenTimer = Timer.periodic(const Duration(milliseconds: 140), (_) {
      if (isClosed) return;
      final words = MockData.streamWords;
      if (_wordIndex >= words.length) {
        _tokenTimer?.cancel();
        final msgs = state.messages.map((m) => m.isStreaming ? m.copyWith(isStreaming: false) : m).toList();
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
    emit(state.copyWith(messages: [...state.messages, voiceMsg], status: ChatStatus.idle));
  }

  @override
  Future<void> close() {
    _tokenTimer?.cancel();
    return super.close();
  }
}