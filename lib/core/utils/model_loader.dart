// ModelManager — pengelola file model AI on-device (`.gguf` LLM).
//
// Cross-platform: semua jalur diselesaikan secara dinamis sesuai platform
// (TIDAK ada path yang di-hardcode):
//   - Linux   : `$XDG_DATA_HOME/<app>` (path_provider)
//   - Windows : `%LOCALAPPDATA%/<app>`
//   - macOS   : `~/Library/Application Support/<app>` (path_provider)
//   - Android : App-Scoped Private Storage  (getApplicationSupportDirectory → files)
//   - iOS     : sandbox `Documents`
//
// Resolution chain (fallback berlapis):
//   1. Custom path yang dipilih user (disimpan di SharedPreferences).
//   2. Standard app storage `<dataRoot>/models/`.
//   3. Local P2P shared cache `<dataRoot>/mesh_cache/`.
//   4. Jika semuanya tidak tersedia → return `null` (pemanggil menampilkan
//      model picker / downloader, TIDAK melempar error resolusi model).

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gguf_validator.dart';

/// Resolver direktori data aplikasi per-platform.
class ModelPaths {
  ModelPaths._();

  /// Test hook: jika di-set, dipakai sebagai resolusi root direktori data
  /// (menggantikan logika per-platform) — berguna untuk unit test.
  @visibleForTesting
  static Future<Directory> Function()? dataRootOverride;

  /// Root direktori penyimpanan model (absolute path, siap untuk FFI).
  ///
  /// Memetakan ke direktori standar per-platform sesuai spec. Desktop
  /// di-scope ke folder app agar tidak menabrak aplikasi lain.
  static Future<Directory> appDataRoot() async {
    final override = dataRootOverride;
    if (override != null) return override();

    if (Platform.isAndroid) {
      // App-Scoped Private Storage (getFilesDir, tanpa izin storage publik)
      // — diselesaikan oleh path_provider, bukan jalur publik Android.
      return getApplicationSupportDirectory();
    }
    if (Platform.isIOS) {
      // Sandbox iOS: separuh Dokumen app.
      return getApplicationDocumentsDirectory();
    }
    if (Platform.isWindows) {
      // Windows: prefer LOCALAPPDATA (non-roaming), fallback via plugin.
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return Directory(p.join(localAppData, 'tacit_pulse_ai'));
      }
      return getApplicationSupportDirectory();
    }

    // Linux: path_provider → `$XDG_DATA_HOME/<app>` (fallback ~/.local/share).
    // macOS: path_provider → `~/Library/Application Support/<app>`.
    if (Platform.isLinux || Platform.isMacOS) {
      return getApplicationSupportDirectory();
    }

    // Platform lain / fallback aman.
    return getApplicationSupportDirectory();
  }
}

/// Service pengelola file model AI on-device (`.gguf` LLM, `.bin` Whisper).
/// Model disimpan di: `<dataRoot>/models/` (lihat [ModelPaths.appDataRoot]).
class ModelManager {
  ModelManager._();

  static const _modelsDirName = 'models';

  /// Direktori cache P2P mesh (sinkronisasi antar node).
  static const meshCacheDirName = 'mesh_cache';

  /// Nama folder cache staging unduhan. Ini HANYA cache — `.tmp` parsial
  /// ditulis di sini selama unduhan berjalan, dan seluruh folder dihapus
  /// begitu model selesai dipindahkan ke destinasi final.
  static const downloadCacheDirName = 'tacit_pulse_ai_download_cache';

  /// Test hook: override resolver folder cache unduhan (isolasi unit test).
  @visibleForTesting
  static Future<Directory> Function()? downloadCacheOverride;

  static const defaultModelName = 'qwen3.5-0.8b-q4_k_m.gguf';

  /// URL mirror HuggingFace (CDN) untuk In-App Downloader. Menyediakan
  /// [defaultModelName] (Qwen 3.5 0.8B Q4_K_M). Bisa diganti mirror lain
  /// tanpa mengubah kode — downloader relatif terhadap URL ini.
  static const String defaultModelDownloadUrl =
      'https://huggingface.co/Mustafaege/Qwen3.5-0.8B-GGUF-q4_k_m/resolve/main/'
      'Qwen3.5-0.8B.Q4_K_M.gguf';

  /// Default fallback size ketika offline / ukuran remote tidak ter-resolve.
  static const double defaultModelSizeMb = 532.5;

  /// Kunci SharedPreferences untuk custom model path yang dipilih user.
  static const customModelPathKey = 'custom_model_path';

  /// Mengambil ukuran model remote (MB) dari HTTP `Content-Length` header
  /// CDN HuggingFace via request `HEAD`. Mengikuti redirect otomatis (CDN HF
  /// memakai redirect 302 ke LFS storage). Mengembalikan `null` bila gagal /
  /// offline / timeout → pemanggil memakai [defaultModelSizeMb].
  static Future<double?> fetchRemoteModelSize({String? url}) async {
    final targetUrl = url ?? defaultModelDownloadUrl;
    final httpClient = http.Client();
    try {
      final uri = Uri.parse(targetUrl);
      final request = http.Request('HEAD', uri)..followRedirects = true;
      final response =
          await httpClient.send(request).timeout(const Duration(seconds: 5));

      final contentLengthStr = response.headers['content-length'];
      if (contentLengthStr != null) {
        final bytes = int.tryParse(contentLengthStr);
        if (bytes != null && bytes > 0) {
          return bytes / (1024 * 1024); // Convert bytes to MB
        }
      }
    } catch (_) {
      // Silently catch network errors/timeouts and return null for fallback.
    } finally {
      httpClient.close();
    }
    return null;
  }

  /// Mengembalikan direktori models internal, membuatnya bila belum ada.
  static Future<Directory> _ensureModelsDir() async {
    final root = await ModelPaths.appDataRoot();
    final dir = Directory(p.join(root.path, _modelsDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cek ketersediaan model di standard app storage (`<root>/models/<file>`).
  /// Mengembalikan absolute path bila file ada, `null` bila belum ada.
  static Future<String?> findModel([String fileName = defaultModelName]) async {
    final dir = await _ensureModelsDir();
    final file = File(p.join(dir.path, fileName));
    return await file.exists() ? file.path : null;
  }

  /// Cari model target (Qwen 3.5 0.8B) di P2P shared cache
  /// (`<root>/mesh_cache/`). Memvalidasi setiap kandidat `.gguf`;
  /// mengembalikan path pertama yang valid & sesuai target, atau `null`.
  static Future<String?> findModelInMeshCache() async {
    final root = await ModelPaths.appDataRoot();
    final cacheDir = Directory(p.join(root.path, meshCacheDirName));
    if (!await cacheDir.exists()) return null;

    final entries = await cacheDir.list(followLinks: true).toList();
    final candidates = <File>[];
    for (final entry in entries) {
      if (entry is! File) continue;
      if (p.extension(entry.path).toLowerCase() != '.gguf') continue;
      candidates.add(entry);
    }

    String? found;
    for (final candidate in candidates) {
      final result = await GgufValidator.validate(candidate);
      if (!result.isValidGguf) continue;
      if (result.isTargetModel) {
        found = candidate.path;
        break;
      }
    }
    return found;
  }

  /// Ambil custom model path yang tersimpan di SharedPreferences.
  static Future<String?> getCustomModelPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(customModelPathKey);
  }

  /// Simpan (atau hapus, bila [path] null/kosong) custom model path.
  static Future<void> setCustomModelPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    final value = path?.trim() ?? '';
    if (value.isEmpty) {
      await prefs.remove(customModelPathKey);
    } else {
      await prefs.setString(customModelPathKey, value);
    }
  }

  /// Development helper: salin model dari direktori Downloads publik
  /// (mis. hasil SCP/USB) ke storage internal app. Bukan bagian dari
  /// resolution chain utama.
  ///
  /// Integritas diverifikasi via ukuran file; salinan parsial dihapus.
  static Future<String?> copyFromDownloads([
    String fileName = defaultModelName,
  ]) async {
    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir == null) return null;

      final source = File(p.join(downloadsDir.path, fileName));
      if (!await source.exists()) return null;

      final dir = await _ensureModelsDir();
      final dest = File(p.join(dir.path, fileName));

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
    } catch (_) {
      return null;
    }
  }

  /// Resolver folder cache staging unduhan.
  ///
  /// Preferensi: system temp — proper `/tmp` di Linux/macOS (`TMPDIR` bila
  /// di-set) → bila system temp tidak bisa ditulis (sandbox Android/iOS),
  /// fallback ke `<appDataRoot>/<downloadCacheDirName>`. Folder ini murni
  /// cache, bukan destinasi model:
  ///   - `.tmp` parsial ditulis di sini selama unduhan berjalan (resume OK),
  ///   - seluruh folder DIHAPUS begitu model selesai dipindahkan ke
  ///     `<appDataRoot>/models/` (lihat [downloadModel]).
  static Future<Directory> downloadCacheDir() async {
    final override = downloadCacheOverride;
    if (override != null) {
      final dir = await override();
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }

    try {
      final tmp = Directory(
        p.join(Directory.systemTemp.path, downloadCacheDirName),
      );
      if (!await tmp.exists()) {
        await tmp.create(recursive: true);
      }
      // Uji tulis-nyata: system temp bisa ada tapi read-only di sandbox.
      final probe = File(p.join(tmp.path, '.write_probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      return tmp;
    } catch (_) {
      final root = await ModelPaths.appDataRoot();
      final dir = Directory(p.join(root.path, downloadCacheDirName));
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
  }

  /// Hapus seluruh folder cache unduhan (best-effort, recursive). Dipanggil
  /// SETELAH unduhan sukses sehingga tidak ada sisa `.tmp` yang menginap —
  /// folder ini memang hanya cache, bukan sumber kebenaran model.
  static Future<void> purgeDownloadCache(Directory cacheDir) async {
    try {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (_) {
      // Gagal membersihkan tidak boleh merusak hasil unduhan yang valid.
    }
  }

  /// Pindahkan hasil staging ke destinasi final.
  ///
  /// `rename()` atomik bila satu filesystem; kalau folder cache ada di mount
  /// lain (mis. `/tmp` tmpfs vs disk utama) rename melempar EXDEV → salin lalu
  /// hapus sumber sebagai fallback.
  static Future<void> _moveIntoPlace(File staged, File dest) async {
    try {
      await staged.rename(dest.path);
    } on FileSystemException {
      await staged.copy(dest.path);
      await staged.delete();
    }
  }

  /// Download a GGUF model from a URL directly into the app's private models
  /// directory (Resolusi tier "In-App Downloader").
  ///
  /// Resumable (setara `wget -c`):
  ///   - Unduhan ditulis ke folder cache system-temp
  ///     ([downloadCacheDir], mis. `/tmp/<downloadCacheDirName>/`), BUKAN
  ///     langsung ke nama final dan bukan di destinasi model.
  ///   - Sebelum request, ukuran `.tmp` yang sudah ada diukur; HTTP request
  ///     membawa header `Range: bytes=<existing>-` bila parsel sudah ada.
  ///   - Server `206 Partial Content` → byte disambung (append) tanpa mulai
  ///     dari 0 MB. Server `200` (tidak mendukung Range / file baru) →
  ///     `.tmp` ditulis ulang dari nol.
  ///   - Interupsi jaringan TIDAK menghapus `.tmp`; unduhan berikutnya
  ///     dilanjutkan dari byte terakhir yang tersimpan (selama cache masih
  ///     ada — OS boleh membersihkan `/tmp`, ini memang hanya cache).
  ///
  /// Saat 100% lengkap dan header GGUF valid (via [GgufValidator]), `.tmp`
  /// dipindahkan (rename / salin lintas-mount) ke `<dest_path>`, lalu
  /// SELURUH folder cache ikut dihapus ([purgeDownloadCache]) — folder cache
  /// lenyap begitu model berhasil diunduh.
  ///
  /// [shouldCancel] adalah checkpoint kooperatif yang dicek di antara chunk:
  /// bila mengembalikan `true`, unduhan dihentikan dengan LEMBUT — `.tmp`
  /// parsial dipertahankan untuk resume, hasil `null` (bukan error berat).
  /// Dipakai service latar belakang ([ModelDownloadService]) untuk
  /// pause/cancel tanpa memutus koneksi paksa.
  ///
  /// Returns the absolute path to the downloaded model on success, `null` on
  /// failure / incomplete / cancelled.
  static Future<String?> downloadModel({
    required String url,
    required String fileName,
    Function(int bytesDownloaded, int totalBytes)? onProgress,
    http.Client? client,
    bool Function()? shouldCancel,
  }) async {
    final dir = await _ensureModelsDir();
    final dest = File(p.join(dir.path, fileName));
    // Stage di folder cache system-temp (proper `/tmp`) — bukan di destinasi
    // model. Folder ini hanya cache dan dibersihkan saat sukses.
    final cacheDir = await downloadCacheDir();
    final tempPath = p.join(cacheDir.path, '$fileName.tmp');
    final tempFile = File(tempPath);

    final httpClient = client ?? http.Client();
    final shouldCloseClient = client == null;

    try {
      // Ukuran parsial yang sudah ada di disk (untuk resume wget -c).
      var existingBytes = await tempFile.exists() ? await tempFile.length() : 0;

      // Satu percobaan ulang: kalau server balas 416 (Range tidak bisa
      // dipenuhi — biasanya `.tmp` basi/korup), hapus dan unduh dari 0.
      var restartedFresh = false;

      while (true) {
        final request = http.Request('GET', Uri.parse(url));
        if (existingBytes > 0) {
          request.headers['Range'] = 'bytes=$existingBytes-';
        }

        final streamedResponse = await httpClient.send(request);
        final status = streamedResponse.statusCode;

        if (status == 416 && existingBytes > 0 && !restartedFresh) {
          await tempFile.delete();
          existingBytes = 0;
          restartedFresh = true;
          continue;
        }

        if (status != 200 && status != 206) {
          throw HttpException(
            'Failed to download model: HTTP $status',
          );
        }

        // 206 → lanjutkan penulisan dari byte yang sudah ada; 200 → tulis
        // ulang file dari nol (server tidak mendukung Range / file fresh).
        final isPartial = status == 206;
        final baseBytes = isPartial ? existingBytes : 0;

        final contentLength =
            int.tryParse(streamedResponse.headers['content-length'] ?? '');
        int? totalBytes;
        if (isPartial) {
          totalBytes =
              parseContentRangeTotal(streamedResponse.headers['content-range']);
          totalBytes ??= contentLength != null ? baseBytes + contentLength : null;
        } else {
          totalBytes = contentLength;
        }

        final sink = tempFile.openWrite(
          mode: isPartial ? FileMode.append : FileMode.write,
        );
        var streamBytes = 0;
        var cancelled = false;

        if (baseBytes > 0) {
          onProgress?.call(baseBytes, totalBytes ?? -1);
        }

        try {
          await for (final chunk in streamedResponse.stream) {
            sink.add(chunk);
            streamBytes += chunk.length;
            onProgress?.call(baseBytes + streamBytes, totalBytes ?? -1);
            // Checkpoint kooperatif: pause/cancel dari service latar belakang.
            // Putuskan menulis segera (bukan tunda sampai koneksi berakhir).
            if (shouldCancel?.call() ?? false) {
              cancelled = true;
              break;
            }
          }
          if (!cancelled) {
            await sink.flush();
          }
        } finally {
          // Pastikan memanggang semua yang sudah diterima walau koneksi putus
          // di tengah — `close()` meng-flush buffer sink sebelumnya.
          await sink.close();
        }

        if (cancelled) {
          // `.tmp` parsial dipertahankan — resume akan lanjut dari byte ini.
          return null;
        }

        final downloadedSize = await tempFile.length();

        // Belum lengkap (ukurannya kurang dari target): pertahankan `.tmp`
        // agar unduhan berikutnya bisa melanjutkan dari posisi ini.
        if (totalBytes != null && totalBytes > 0 && downloadedSize != totalBytes) {
          return null;
        }

        // Header GGUF harus valid sebelum dipindahkan ke nama final.
        final validation = await GgufValidator.validateFile(tempPath);
        if (!validation.isValidGguf) {
          await tempFile.delete();
          return null;
        }

        // Model valid → pindahkan ke destinasi final, lalu PERISH folder
        // cache (`.tmp` sudah tidak ada gunanya — hanya cache, bukan model).
        await _moveIntoPlace(tempFile, dest);
        await purgeDownloadCache(cacheDir);
        return dest.path;
      }
    } catch (_) {
      // Interupsi jaringan / error lain: simpankan `.tmp` parsial supaya
      // resume tetap mungkin (wget -c). Gagal total malah dihapus di jalur
      // validasi GGUF di atas (file lengkap tapi bukan model).
      return null;
    } finally {
      if (shouldCloseClient) {
        httpClient.close();
      }
    }
  }

  /// Parse total byte dari header HTTP `Content-Range`:
  /// `bytes <start>-<end>/<total>` (bentuk `bytes */<total>` tak terpenuhi).
  /// Mengembalikan `null` bila header tidak terbaca.
  static int? parseContentRangeTotal(String? header) {
    if (header == null) return null;
    final slash = header.lastIndexOf('/');
    if (slash < 0) return null;
    final totalPart = header.substring(slash + 1).trim();
    if (totalPart == '*') return null;
    return int.tryParse(totalPart);
  }

  /// Entry point untuk engine C++ (llama.cpp via FFI).
  ///
  /// Adaptive multi-tier resolution (tidak pernah melempar):
  ///   1. Custom path user (SharedPreferences) — divalidasi GGUF + target.
  ///   2. Standard app storage `<root>/models/<fileName>`.
  ///   3. P2P shared cache `<root>/mesh_cache/`.
  ///
  /// Mengembalikan absolute path model yang siap dioper ke `tacit_llama`
  /// bila ditemukan & valid, atau `null` bila belum ada (pemanggil harus
  /// menampilkan Model Path Picker / Downloader / P2P Sync Sheet).
  static Future<String?> resolveModelPath([
    String fileName = defaultModelName,
  ]) async {
    // Tier 1 — custom path yang dipilih user.
    final customPath = await getCustomModelPath();
    if (customPath != null && customPath.isNotEmpty) {
      // Normalisasi (tilde / relatif-POSIX) sebelum dibaca dari disk.
      final normalized = GgufValidator.normalizePath(customPath);
      final file = File(normalized);
      if (await file.exists()) {
        final result = await GgufValidator.validate(file);
        if (result.validForUse) return file.path;
      }
    }

    // Tier 2 — standard app storage.
    final standard = await findModel(fileName);
    if (standard != null) {
      final result = await GgufValidator.validateFile(standard);
      if (result.validForUse) return standard;
    }

    // Tier 3 — P2P shared cache dir.
    final cached = await findModelInMeshCache();
    if (cached != null) return cached;

    // Tier 4 — tidak tersedia. Serahkan ke pemanggil (download / sync sheet).
    return null;
  }
}