import 'package:flutter/foundation.dart';

import '../../../core/models/citation.dart';
import '../../../core/rag/document_source_resolver.dart';

/// Resolve path file dokumen untuk [citation] lewat tabel `document_sources`
/// pada database knowledge (vec0). Defensive: kembalikan `null` bila file
/// tidak ada di disk. Caller wajib menangani `null` tanpa crash.
Future<String?> resolveCitationPdfPath(SourceCitation citation) async {
  try {
    return await DocumentSourceResolver().sourcePathForTitle(citation.title);
  } catch (e) {
    debugPrint('resolveCitationPdfPath: lookup gagal: $e');
    return null;
  }
}
