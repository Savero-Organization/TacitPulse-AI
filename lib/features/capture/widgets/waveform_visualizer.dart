import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Waveform visualizer realtime untuk merekam suara teknisi
/// (placeholder listenable yang direglook dari CaptureCubit).
class WaveformVisualizer extends StatelessWidget {
  const WaveformVisualizer({
    super.key,
    required this.samples,
    required this.color,
    this.active = true,
  });

  final List<double> samples;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 96),
      painter: _WavePainter(samples: samples, color: color, active: active),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.samples, required this.color, required this.active});

  final List<double> samples;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    final barWidth = (size.width / samples.length) * 0.55;
    final gap = (size.width / samples.length) * 0.45;
    final midY = size.height / 2;

    final inactivePaint = Paint()
      ..color = AppColors.slateMuted.withValues(alpha: 0.7)
      ..strokeWidth = 2;

    for (var i = 0; i < samples.length; i++) {
      final x = i * (barWidth + gap) + gap / 2;
      final amp = size.height * 0.42 * samples[i].clamp(0.03, 1);
      final paint = active ? (Paint()..color = color) : inactivePaint;
      paint.strokeWidth = barWidth.clamp(1.5, 6) as double;
      paint.strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, midY - amp), Offset(x, midY + amp), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.color != color ||
        oldDelegate.active != active;
  }
}