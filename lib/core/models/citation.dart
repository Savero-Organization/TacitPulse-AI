import 'dart:ui';

/// Jenis referensi sumber dokumen RAG.
enum CitationType {
  sop('SOP', 'SOP'),
  pdf('PDF', 'PDF'),
  worklog('Worklog', 'LOG'),
  machine('Mesin', 'MESIN');

  const CitationType(this.label, this.badge);
  final String label;
  final String badge;
}

/// Referensi dokumen yang dijadikan sumber jawaban RAG
/// (SOP / PDF + bounding box region pada halaman).
class SourceCitation {
  const SourceCitation({
    required this.id,
    required this.title,
    required this.type,
    required this.page,
    required this.snippet,
    required this.score,
    this.boundingBox = const Rect.fromLTWH(0.08, 0.32, 0.6, 0.2),
  });

  final String id;
  final String title;
  final CitationType type;
  final int page;
  final String snippet;

  /// Skor kemiripan embedding (0..1).
  final double score;

  /// Bounding box relatif (0..1) pada halaman PDF/SOP.
  final Rect boundingBox;
}