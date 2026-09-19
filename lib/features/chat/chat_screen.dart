import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/profile_app_bar_action.dart';
import '../../core/widgets/widgets.dart';
import 'cubit/chat_cubit.dart';
import 'widgets/message_bubble.dart';
import 'widgets/voice_record_button.dart';

/// Knowledge Chat & RAG UI (persiapan stream token llama.cpp).
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (ctx) => ChatCubit(),
      child: const _ChatView(),
    );
  }
}

class _ChatView extends StatefulWidget {
  const _ChatView();

  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send(BuildContext context) {
    final text = _controller.text.trim();
    _controller.clear();
    context.read<ChatCubit>().startStreaming(text);
    FocusScope.of(context).unfocus();
  }

  void _attach(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Simulasi upload dokumen → SQLite Knowledge Store (FFI backend)'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge Chat'),
        actions: [
          const ProfileAppBarAction(),
          BlocBuilder<ChatCubit, ChatState>(
            builder: (context, state) {
              final online = state.isModelLoaded && state.hallucinationGuard;
              return Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Row(
                  children: [
                    PulseDot(color: online ? AppColors.success : AppColors.warning),
                    const SizedBox(width: 6),
                    const Text('Qwen 3.5-0.8B',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 11, fontFamily: 'monospace')),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: BlocBuilder<ChatCubit, ChatState>(
        builder: (context, state) {
          return Column(
            children: [
              if (state.status == ChatStatus.recording)
                const _RecordingBanner()
              else if (state.status == ChatStatus.streaming)
                const _StreamingBanner(),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  controller: ScrollController(),
                  itemCount: state.messages.length,
                  itemBuilder: (context, i) => MessageBubble(message: state.messages[i]),
                ),
              ),
              _Composer(
                controller: _controller,
                isRecording: state.status == ChatStatus.recording,
                isStreaming: state.status == ChatStatus.streaming,
                onAttach: () => _attach(context),
                onSend: () => _send(context),
                onVoiceStart: () => context.read<ChatCubit>().startVoiceRecording(),
                onVoiceStop: () => context.read<ChatCubit>().stopVoiceRecording(),
              ),
              const SizedBox(height: 6),
            ],
          );
        },
      ),
    );
  }
}

class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
      color: AppColors.danger.withValues(alpha: 0.14),
      child: const Row(
        children: [
          PulseDot(color: AppColors.danger),
          SizedBox(width: 8),
          Text('Merekam suara teknisi · whisper.cpp on-device',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _StreamingBanner extends StatelessWidget {
  const _StreamingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
      color: AppColors.cyanAccent.withValues(alpha: 0.12),
      child: const Row(
        children: [
          PulseDot(color: AppColors.cyanAccent),
          SizedBox(width: 8),
          Text('Streaming token · llama.cpp (Qwen 3.5-0.8B Q4_K_M)',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isRecording,
    required this.isStreaming,
    required this.onAttach,
    required this.onSend,
    required this.onVoiceStart,
    required this.onVoiceStop,
  });

  final TextEditingController controller;
  final bool isRecording;
  final bool isStreaming;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final VoidCallback onVoiceStart;
  final VoidCallback onVoiceStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
      decoration: const BoxDecoration(
        color: AppColors.deepCharcoal,
        border: Border(top: BorderSide(color: AppColors.surfaceBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: onAttach,
            tooltip: 'Lampirkan dokumen (PDF) ke Knowledge Store',
            icon: const Icon(Icons.attach_file_rounded, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: isRecording ? 'Merekam… ketuk lagi untuk berhenti' : 'Ask TacitPulse AI…',
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                suffixIcon: ChatMicButton(
                  isRecording: isRecording,
                  enabled: !isStreaming,
                  onStart: onVoiceStart,
                  onStop: onVoiceStop,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            onPressed: isStreaming ? null : onSend,
            tooltip: 'Kirim',
            icon: Icon(
              Icons.send_rounded,
              color: isStreaming ? AppColors.textSecondary : AppColors.industrialAmber,
            ),
          ),
        ],
      ),
    );
  }
}