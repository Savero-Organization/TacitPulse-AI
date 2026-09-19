import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Tombol mik yang ditaruh di dalam TextField (suffixIcon) untuk query suara cepat.
/// Mode tap-toggle: tekan untuk mulai rekam, tekan lagi untuk stop.
class ChatMicButton extends StatelessWidget {
  const ChatMicButton({
    super.key,
    required this.isRecording,
    required this.onStart,
    required this.onStop,
    this.enabled = true,
  });

  final bool isRecording;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: enabled ? (isRecording ? onStop : onStart) : null,
      tooltip: isRecording ? 'Stop rekam suara' : 'Query suara cepat',
      icon: Icon(
        isRecording ? Icons.stop_rounded : Icons.mic_rounded,
        color: isRecording ? AppColors.danger : AppColors.textSecondary,
      ),
    );
  }
}