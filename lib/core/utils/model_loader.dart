import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Service pengelola file model AI on-device (`.gguf` LLM, `.bin` Whisper).
/// Direktori internal privat aplikasi: `<app_documents>/models/`
/// (di Android: `/data/user/0/<pkg>/app_flutter/models/`).
///
/// Development fallback: jika model belum ada di direktori internal,
/// salin otomatis dari direktori Downloads publik (lokasi target
/// `adb push model.gguf /storage/emulated/0/Download/`).
///
/// Entry point utama: [resolveModelPath] mengembalikan absolute path
/// bertipe String yang siap dioper ke engine C++ (llama.cpp via FFI).
class ModelManager {
  ModelManager._();

  static const _modelsDirName = 'models';
  static const defaultModelName = 'qwen3.5-0.8b-q4_k_m.gguf';

  /// Mengembalikan direktori models internal, membuatnya bila belum ada.
  static Future<Directory> _ensureModelsDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/$_modelsDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cek ketersediaan model di direktori internal privat aplikasi.
  /// Mengembalikan absolute path bila ada, `null` bila belum ada.
  static Future<String?> findModel([String fileName = defaultModelName]) async {
    final dir = await _ensureModelsDir();
    final file = File('${dir.path}/$fileName');
    return await file.exists() ? file.path : null;
  }

  /// Development fallback: salin model dari direktori Downloads publik
  /// (lokasi `adb push`). Mengembalikan path tujuan bila berhasil,
  /// `null` bila file sumber tidak ditemukan.
  ///
  /// Integritas diverifikasi via ukuran file; salinan parsial dihapus.
  static Future<String?> copyFromDownloads([
    String fileName = defaultModelName,
  ]) async {
    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir == null) return null;

    final source = File('${downloadsDir.path}/$fileName');
    if (!await source.exists()) return null;

    final dir = await _ensureModelsDir();
    final dest = File('${dir.path}/$fileName');

    final sourceLen = await source.length();
    final tempPath = '${dest.path}.tmp';
    await source.copy(tempPath);
    final tempLen = await File(tempPath).length();
    if (tempLen != sourceLen) {
      await File(tempPath).delete();
      return null;
    }
    await File(tempPath).rename(dest.path);
    return dest.path;
  }

  /// Entry point untuk engine C++: cari model di direktori internal,
  /// bila belum ada coba fallback salin dari Downloads, lalu kembalikan
  /// absolute path. Melempar [StateError] bila model tetap tidak tersedia.
  static Future<String> resolveModelPath([
    String fileName = defaultModelName,
  ]) async {
    final existing = await findModel(fileName);
    if (existing != null) return existing;

    final copied = await copyFromDownloads(fileName);
    if (copied != null) return copied;

    throw StateError(
      'Model "$fileName" tidak ditemukan. Salin via:\n'
      'adb push $fileName /storage/emulated/0/Download/',
    );
  }
}
