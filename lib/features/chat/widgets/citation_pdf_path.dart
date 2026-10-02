import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/models/citation.dart';

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
  } catch (e) {
    debugPrint('resolveCitationPdfPath: docPathForCitation gagal: $e');
    return null;
  }
  if (path == null || path.isEmpty) return null;
  try {
    return File(path).existsSync() ? path : null;
  } catch (e) {
    debugPrint('resolveCitationPdfPath: cek file gagal untuk $path: $e');
    return null;
  }
}
