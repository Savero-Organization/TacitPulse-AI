import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/thinking_utils.dart';
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
    if (!isAssistant) {
      return Text(
        text,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          height: 1.45,
        ),
      );
    }

    // Assistant: pisahkan blok berpikir (bisa di-collapse) dari jawaban final.
    final thinking = thinkingPreview(text);
    final answer = answerContent(text);
    final activeThinking = message.isStreaming && isInsideThinkingBlock(text);

    // Belum ada konten sama sekali (token berpikir/jawaban belum keluar) tapi
    // stream aktif → tampilkan panel "Proses Berpikir" sebagai indikator
    // analisis live.
    final pending = message.isStreaming && answer.isEmpty && thinking == null;

    final children = <Widget>[];
    if (thinking != null) {
      children.add(_ThinkingPanel(
        key: ValueKey('${message.id}-thinking'),
        text: thinking,
        seconds: message.thinkingSeconds,
        autoExpanded: activeThinking,
        streaming: message.isStreaming,
      ));
      children.add(const SizedBox(height: 8));
    } else if (pending) {
      children.add(_ThinkingPanel(
        key: ValueKey('${message.id}-pending'),
        text: '',
        seconds: message.thinkingSeconds,
        autoExpanded: true,
        streaming: true,
        pending: true,
      ));
      children.add(const SizedBox(height: 8));
    }

    if (answer.isNotEmpty) {
      children.add(Text(
        message.isStreaming ? '$answer ▍' : answer,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          height: 1.45,
        ),
      ));
    } else if (message.isStreaming && thinking != null) {
      children.add(Text(
        activeThinking
            ? '⚙️ menyusun jawaban…'
            : '⚙️ menghasilkan jawaban…',
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 12,
          fontStyle: FontStyle.italic,
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children.isEmpty
          ? [
              const Text(
                '· · ·',
                style: TextStyle(color: AppColors.textMuted, fontSize: 14),
              ),
            ]
          : children,
    );
  }
}

/// Panel aksen "Proses Berpikir" yang bisa di-expand/collapse manual.
///
/// - Auto-expand selama model masih STREAMING token dalam blok berpikir
///   (atau mode [pending] saat belum ada konten sama sekali).
/// - Auto-collapse begitu tag ` response` diterima atau stream selesai.
/// - Tampil dark card (slateDark), teks monospace muted 11.5pt.
class _ThinkingPanel extends StatefulWidget {
  const _ThinkingPanel({
    super.key,
    required this.text,
    required this.seconds,
    required this.autoExpanded,
    required this.streaming,
    this.pending = false,
  });

  final String text;
  final int seconds;
  final bool autoExpanded;
  final bool streaming;

  /// Mode "menunggu konten": stream aktif tapi token berpikir/jawaban belum
  /// keluar — body menampilkan indikator analisis aktif.
  final bool pending;

  @override
  State<_ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<_ThinkingPanel> {
  bool _userExpanded = false;
  Stopwatch? _watch;
  Timer? _ticker;
  int _elapsed = 0;

  bool get _active => widget.autoExpanded || widget.pending;
  bool get _expanded => _active ? true : _userExpanded;

  @override
  void initState() {
    super.initState();
    _syncActive();
  }

  @override
  void didUpdateWidget(_ThinkingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncActive();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncActive() {
    if (_active) {
      _watch ??= Stopwatch()..start();
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _elapsed = _watch?.elapsed.inSeconds ?? 0);
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
      _watch?.stop();
    }
  }

  int _tokenEstimate() {
    final len = widget.text.length;
    return len == 0 ? 0 : (len / 4).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final secs = widget.seconds > 0 ? widget.seconds : _elapsed;
    final label = '💡 Proses Berpikir ($secs detik / ${_tokenEstimate()} token)';
    final bodyText = widget.pending
        ? '⚙️ Menganalisis SOP & menyusun penalaran...'
        : widget.text;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.slateDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.slateMuted.withValues(alpha: 0.55),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _userExpanded = !_userExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      _active
                          ? Icons.auto_awesome_rounded
                          : Icons.lightbulb_outline_rounded,
                      color: _active
                          ? AppColors.cyanAccent
                          : AppColors.industrialAmber,
                      size: 15,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: AppColors.textMuted,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              alignment: Alignment.topCenter,
              duration: const Duration(milliseconds: 180),
              child: _expanded
                  ? Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Text(
                        bodyText,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          height: 1.55,
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}