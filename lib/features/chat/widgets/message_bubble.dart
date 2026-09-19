import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/theme/app_colors.dart';
import 'citation_card.dart';

/// Bubble pesan chat: user (kanan, amber) & assistant (kiri, charcoal)
/// lengkap dengan kartu Source Citation + indikator streaming token.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final isAssistant = !isUser;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser ? AppColors.industrialAmber.withValues(alpha: 0.16) : AppColors.deepCharcoal,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(isUser ? 14 : 3),
          bottomRight: Radius.circular(isUser ? 3 : 14),
        ),
        border: Border.all(
          color: isUser ? AppColors.industrialAmber.withValues(alpha: 0.45) : AppColors.surfaceBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.isVoice) ...[
            const Row(
              children: [
                Icon(Icons.mic_rounded, color: AppColors.cyanAccent, size: 15),
                SizedBox(width: 5),
                Text('INPUT SUARA',
                    style: TextStyle(color: AppColors.cyanAccent, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1)),
              ],
            ),
            const SizedBox(height: 5),
          ],
          _buildBody(isAssistant),
          if (message.citations.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'SUMBER REFERENSI${isAssistant && message.isStreaming ? ' · STREAMING' : ''}',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < message.citations.length; i++) ...[
              CitationCard(citation: message.citations[i]),
              if (i < message.citations.length - 1) const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.86,
            ),
            child: bubble,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '$label · $_time',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  String get label => switch (message.role) {
        ChatRole.user => 'TEKNISI',
        ChatRole.assistant => 'TACITPULSE',
      };

  String get _time {
    final d = message.timestamp;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Widget _buildBody(bool isAssistant) {
    final text = message.text;
    if (!isAssistant || !message.isStreaming) {
      return Text(text, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, height: 1.45));
    }

    // Streaming: tampilkan teks + kursor berkedip (token-by-token).
    return RichText(
      text: TextSpan(
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, height: 1.45),
        children: [
          TextSpan(text: text),
          const TextSpan(text: '▍', style: TextStyle(color: AppColors.cyanAccent)),
        ],
      ),
    );
  }
}