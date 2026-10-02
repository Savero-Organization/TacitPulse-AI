import 'package:flutter/material.dart';

/// Peta satu bounding box NORMALIZED (0..1, fraksi left/top/width/height
/// relatif halaman — konvensi `SourceCitation.boundingBox`) ke Rect lokal
/// widget dengan ukuran [pageSize].
///
/// Rumus: `x = norm.side * pageSize.(width|height)` untuk tiap sisi,
/// sisi hasil clamp di-clip dulu ke rentang 0..1 supaya box RAG yang sedikit
/// melewati tepi halaman tidak meloncat ke luar page.
Rect mapNormalizedBboxToPageRect(Rect normalized, Size pageSize) {
  // Normalisasi dulu: bila box terbalik (right < left / bottom < top),
  // tukar tepinya supaya hasilnya selalu rect valid.
  final normLeft = normalized.left <= normalized.right
      ? normalized.left
      : normalized.right;
  final normRight = normalized.left <= normalized.right
      ? normalized.right
      : normalized.left;
  final normTop = normalized.top <= normalized.bottom
      ? normalized.top
      : normalized.bottom;
  final normBottom = normalized.top <= normalized.bottom
      ? normalized.bottom
      : normalized.top;
  final left = normLeft.clamp(0.0, 1.0);
  final top = normTop.clamp(0.0, 1.0);
  final right = normRight.clamp(0.0, 1.0);
  final bottom = normBottom.clamp(0.0, 1.0);
  return Rect.fromLTRB(
    left * pageSize.width,
    top * pageSize.height,
    right * pageSize.width,
    bottom * pageSize.height,
  );
}

/// Highlight kuning translusen di atas halaman PDF yang dirender.
///
/// [boxes] memakai koordinat NORMALIZED 0..1 yang sama seperti thumbnail
/// kutipan ([CitationThumbnail]); [pageSize] harus berupa ukuran halaman
/// yang benar-benar dirender (mis. `pageRectInViewer.size` dari pdfrx)
/// agar kotak mengikuti zoom/scroll otomatis.
class BoundingBoxOverlay extends StatelessWidget {
  const BoundingBoxOverlay({
    super.key,
    required this.boxes,
    required this.pageSize,
    this.color = Colors.yellow,
  });

  /// Bounding box normalized 0..1 (boleh lebih dari satu).
  final List<Rect> boxes;

  /// Ukuran halaman hasil render dalam koordinat lokal overlay.
  final Size pageSize;

  final Color color;

  @override
  Widget build(BuildContext context) {
    if (boxes.isEmpty || pageSize.isEmpty) return const SizedBox.shrink();
    return CustomPaint(
      size: pageSize,
      painter: _BoundingBoxPainter(
        rects: [for (final b in boxes) mapNormalizedBboxToPageRect(b, pageSize)],
        color: color,
      ),
    );
  }
}

class _BoundingBoxPainter extends CustomPainter {
  const _BoundingBoxPainter({required this.rects, required this.color});

  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = color.withValues(alpha: 0.28)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final r in rects) {
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _BoundingBoxPainter oldDelegate) {
    return oldDelegate.rects != rects || oldDelegate.color != color;
  }
}
