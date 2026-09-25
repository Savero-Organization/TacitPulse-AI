import 'dart:io';

import '../../../core/models/citation.dart';

// Kontrak dengan branch sibling `feat/gabut-23-pdf-ingestion` — file store
// ini belum ada di tree sebelum merge, jadi `flutter analyze` melaporkan
// tepat satu error `uri_does_not_exist` di baris import berikut; error itu
// hilang setelah merge. Sengaja TANPA `// ignore:` supaya sinyalnya jelas.
import 'package:tacit_pulse_ai/core/rag/pdf_ingest_store.dart' as pdf_ingest;

/// Resolve path file PDF lokal untuk [citation] lewat store ingesti
/// (`docPathForCitation`) milik gabut-23.
///
/// Defensive: kembalikan `null` bila store belum terpasang, lookup gagal,
/// atau file tidak ada di disk (mis. citation dari korpus mock
/// `kKnowledgeCorpus` yang tidak punya file nyata). Caller wajib menangani
/// `null` tanpa crash.
Future<String?> resolveCitationPdfPath(SourceCitation citation) async {
  String? path;
  try {
    path = await pdf_ingest.docPathForCitation(citation.id);
  } catch (_) {
    return null;
  }
  if (path == null || path.isEmpty) return null;
  try {
    return File(path).existsSync() ? path : null;
  } catch (_) {
    return null;
  }
}
