import 'citation.dart';

enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
    this.citations = const [],
    this.isStreaming = false,
    this.isVoice = false,
    this.draftSopId,
  });

  final String id;
  final ChatRole role;
  final String text;
  final DateTime timestamp;
  final List<SourceCitation> citations;
  final bool isStreaming;
  final bool isVoice;
  final String? draftSopId;

  ChatMessage copyWith({
    String? text,
    List<SourceCitation>? citations,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      timestamp: timestamp,
      citations: citations ?? this.citations,
      isStreaming: isStreaming ?? this.isStreaming,
      isVoice: isVoice,
      draftSopId: draftSopId,
    );
  }
}