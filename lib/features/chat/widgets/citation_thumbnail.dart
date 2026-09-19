import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Thumbnail mini halaman dokumen dengan bounding box hasil
/// ekstraksi RAG (format seperti highlight region).
class CitationThumbnail extends StatelessWidget {
  const CitationThumbnail({super.key, required this.box, required this.color});

  final Rect box;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 64,
      decoration: BoxDecoration(
        color: AppColors.slateDark,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: CustomPaint(
        painter: _ThumbnailPainter(box: box, color: color),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _ThumbnailPainter extends CustomPainter {
  _ThumbnailPainter({required this.box, required this.color});

  final Rect box;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Garis teks palsu sebagai simulasi isi halaman.
    final linePaint = Paint()
      ..color = AppColors.textMuted.withValues(alpha: 0.35)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    for (var y = 10.0; y < h - 8; y += 7.0) {
      final len = w * (0.5 + ((y * 0.31) % 0.4));
      canvas.drawLine(Offset(4, y), Offset(5 + len, y), linePaint);
    }

    // Bounding box region yang dikutip.
    final rect = Rect.fromLTWH(
      box.left * w,
      box.top * h,
      box.width * w,
      box.height * h,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _ThumbnailPainter oldDelegate) {
    return oldDelegate.box != box || oldDelegate.color != color;
  }
}