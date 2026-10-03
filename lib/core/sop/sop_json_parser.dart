// sop_json_parser.dart — parse output LLM menjadi SopDraftModel yang aman.

import 'dart:convert';

import 'models/sop_draft_model.dart';

/// Parse output mentah LLM menjadi [SopDraftModel].
class SopJsonParser {
  /// Bersihkan, parse, lalu fallback ke model aman bila malformed.
  ///
  /// Fallback menjamin data suara pengguna tidak pernah hilang: transkrip
  /// asli selalu muncul di [SopDraftModel.summary] dan satu langkah.
  SopDraftModel parse(
    String rawLlmOutput, {
    required String originalTranscript,
  }) {
    final cleaned = cleanLlmOutput(rawLlmOutput);
    for (final candidate in _candidates(cleaned)) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map<String, dynamic> && _hasRequiredData(decoded)) {
          final model = SopDraftModel.fromJson(decoded);
          if (model.steps.isNotEmpty) return _normalizeSteps(model);
        }
      } on FormatException {
        // coba kandidat berikutnya
      } catch (_) {
        // coba kandidat berikutnya
      }
    }
    return _fallback(originalTranscript);
  }

  /// Ekstrak kandidat objek JSON top-level (`{...}` seimbang) satu per satu
  /// memakai penghitung kedalaman brace — O(panjang teks), tidak kuadratik
  /// seperti semua pasangan start/end, jadi payload besar/rusak tidak
  /// memicu ratusan jsonDecode di isolate UI.
  Iterable<String> _candidates(String cleaned) sync* {
    if (cleaned.isNotEmpty) yield cleaned;
    var depth = 0;
    var start = -1;
    for (var i = 0; i < cleaned.length; i++) {
      final char = cleaned[i];
      if (char == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (char == '}' && depth > 0) {
        depth--;
        if (depth == 0 && start >= 0) {
          yield cleaned.substring(start, i + 1);
          start = -1;
        }
      }
    }
  }

  /// Pre-processing: strip code fence lalu ambil substring `{...}`.
  String cleanLlmOutput(String raw) {
    var text = raw.trim();
    // Buang code fence markdown (```json ... ``` / ``` ... ```).
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final fenceMatch = fence.firstMatch(text);
    if (fenceMatch != null) {
      text = fenceMatch.group(1)!.trim();
    } else {
      // Backtick tunggal / tanpa penutup: rapikan sisa ``` di tepi.
      text = text.replaceAll(RegExp(r'^```(?:json)?\s*'), '');
      text = text.replaceAll(RegExp(r'\s*```$'), '');
    }
    // Potong noise percakapan: ambil dari '{' pertama sampai '}' terakhir.
    final first = text.indexOf('{');
    final last = text.lastIndexOf('}');
    if (first >= 0 && last > first) {
      text = text.substring(first, last + 1);
    }
    return text.trim();
  }

  bool _hasRequiredData(Map<String, dynamic> json) {
    final hasTitle = json['title'] is String &&
        (json['title'] as String).trim().isNotEmpty;
    final steps = json['steps'];
    final hasSteps = steps is List &&
        steps.any((s) =>
            s is Map &&
            s['action'] is String &&
            (s['action'] as String).trim().isNotEmpty);
    return hasTitle && hasSteps;
  }

  /// Urutkan langkah berdasarkan stepNumber aslinya lalu beri nomor ulang
  /// mulai dari 1 — LLM kecil sering menghasilkan nomor acak/duplikat.
  SopDraftModel _normalizeSteps(SopDraftModel model) {
    // Tie-breaker index asli supaya urutan langkah ber-stepNumber sama
    // tetap mengikuti urutan array JSON (stable sort).
    final indexed = model.steps.asMap().entries.toList()
      ..sort((a, b) {
        final cmp = a.value.stepNumber.compareTo(b.value.stepNumber);
        return cmp != 0 ? cmp : a.key.compareTo(b.key);
      });
    final renumbered = [
      for (var i = 0; i < indexed.length; i++)
        indexed[i].value.copyWith(stepNumber: i + 1),
    ];
    return model.copyWith(steps: renumbered);
  }

  SopDraftModel _fallback(String originalTranscript) {
    return SopDraftModel(
      title: 'Draft SOP (Terdeteksi Error Format)',
      equipment: '',
      category: '',
      summary: originalTranscript,
      hazards: const [],
      requiredTools: const [],
      steps: [
        SopStep(stepNumber: 1, action: originalTranscript),
      ],
    );
  }
}
