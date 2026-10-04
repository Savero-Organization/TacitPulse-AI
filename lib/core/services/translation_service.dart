// TranslationService — orkestrasi fallback berjenjang (cascade) untuk
// menerjemahkan prompt/respons ketika model aktif bukan Tier 1.
//
// Cascade (sesuai prioritas, berhenti di tier pertama yang berhasil):
//   Tier 1 — direct : model Tier 1 (Qwen 3.5 0.8B) sudah multilingual.
//                   Prompt dikirim apa adanya, middleware TIDAK dijalankan.
//   Tier 2 — localNmt: model NMT on-device (MarianMT ID<->EN via ONNX).
//                   Sepenuhnya offline; dipakai hanya bila model aktif bukan
//                   Tier 1.
//   Tier 3 — publicWeb: endpoint web translation tanpa akun/API key.
//                   OPT-IN: default OFF (lihat ModelManager
//                   .isWebTranslationEnabled) karena memakai jaringan dan
//                   mengirim konten user ke pihak ketiga.
//   Fallback  — directPass: bila semua tier gagal (offline / file NMT hilang),
//                   teks asli diteruskan ke LFM2.5 apa adanya (tanpa crash).
//
// Prinsip:
//   - Tidak pernah melempar; kegagalan tiap tier dicatat di [TranslationOutcome]
//     dan jatuh ke tier berikutnya.
//   - Tier 3 dibungkus timeout ketat (default 3 detik) + deadline total.
//   - Semua I/O jaringan memakai `http.Client` yang di-close setelah pakai.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Tier mana yang menghasilkan hasil akhir.
enum TranslationTier {
  /// Model Tier 1 (Qwen) — tidak ada terjemahan, prompt langsung.
  modelDirect,

  /// Tier 2 — NMT lokal on-device (offline).
  localNmt,

  /// Tier 3 — web translation publik (account-less, opt-in).
  publicWeb,

  /// Semua tier terjemahan gagal; teks asli diteruskan ke LFM2.5.
  directModelPassThrough,
}

extension TranslationTierLabel on TranslationTier {
  /// Label pendek untuk log/UI.
  String get label => switch (this) {
        TranslationTier.modelDirect => 'tier1-model-direct',
        TranslationTier.localNmt => 'tier2-local-nmt',
        TranslationTier.publicWeb => 'tier3-public-web',
        TranslationTier.directModelPassThrough => 'fallback-direct-lfm',
      };
}

/// Hasil satu permintaan terjemahan.
class TranslationOutcome {
  const TranslationOutcome({
    required this.tier,
    required this.text,
    this.error,
  });

  /// Tier yang menghasilkan [text].
  final TranslationTier tier;

  /// Teks final (hasil terjemahan, atau teks asli bila fallback).
  final String text;

  /// Alasan tier sebelumnya gagal (null bila [tier] langsung berhasil).
  final String? error;

  /// Benar bila teks underwent penerjemahan (bukan pass-through).
  bool get wasTranslated => tier == TranslationTier.localNmt ||
      tier == TranslationTier.publicWeb;
}

/// Basis provider NMT lokal.
abstract class LocalNmtProvider {
  /// Benar bila model NMT untuk pasangan bahasa [sourceLang]→[targetLang]
  /// tersedia di device.
  Future<bool> isAvailable(String sourceLang, String targetLang);

  /// Terjemahkan [text]; lempar exception bila gagal (dipanggil orchestrator).
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  });
}

/// Provider NMT lokal berbasis file ONNX (MarianMT).
///
/// Berkas model diasumsikan berada di `<dataRoot>/models/nmt/<pair>/` dengan
/// nama `model.onnx`. Eksekusi ONNX Runtimeinject lewat
/// [NmtRunner] (bridge native / `onnxruntime` binding) — bila runner tidak
/// dipasang, provider dianggap tidak tersedia dan orchestrator jatuh ke tier
/// berikutnya. Ini menjaga app tetap fully offline & tidak crash saat runtime
/// ONNX belum ada.
class MarianNmtProvider implements LocalNmtProvider {
  MarianNmtProvider({this.runner, this.rootOverride});

  /// Dieksekusi sebagai: `runner(text, source, target) -> translated`.
  /// Null => NMT offline dianggap tidak tersedia.
  final Future<String> Function(String text, String source, String target)?
      runner;

  /// Test hook: Override root data app.
  final Future<Directory> Function()? rootOverride;

  static const String _modelFileName = 'model.onnx';

  Future<Directory> _nmtRoot() async {
    final override = rootOverride;
    final root = override != null
        ? await override()
        : await getApplicationSupportDirectory();
    return Directory(p.join(root.path, 'models', 'nmt'));
  }

  /// Path direktori model untuk pasangan bahasa tertentu (mis. `id-en`).
  Future<Directory> _pairDir(String sourceLang, String targetLang) async {
    final root = await _nmtRoot();
    return Directory(p.join(root.path, '$sourceLang-$targetLang'));
  }

  @override
  Future<bool> isAvailable(String sourceLang, String targetLang) async {
    if (runner == null) return false;
    final dir = await _pairDir(sourceLang, targetLang);
    return File(p.join(dir.path, _modelFileName)).exists();
  }

  @override
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final activeRunner = runner;
    if (activeRunner == null) {
      throw StateError('NMT offline: runner tidak terpasang');
    }
    final dir = await _pairDir(sourceLang, targetLang);
    final modelFile = File(p.join(dir.path, _modelFileName));
    if (!await modelFile.exists()) {
      throw StateError(
        'NMT offline: model $sourceLang-$targetLang tidak ditemukan '
        'di ${dir.path}',
      );
    }
    return activeRunner(text, sourceLang, targetLang);
  }
}

/// Provider Tier 3 — web translation account-less (tanpa API key).
///
/// Default ENDPOINT memakai MyMemory (endpoint publik, tanpa akun). Timeout
/// ketat 3 detik. Selalu ops: hanya dijalankan bila opt-in Tier 3 aktif.
class PublicWebNmtProvider {
  PublicWebNmtProvider({
    this.timeout = const Duration(seconds: 3),
    String? endpointTemplate,
    this.clientFactory,
  }) : endpointTemplate = endpointTemplate ?? _defaultTemplate;

  /// Timeout per permintaan (default 3 detik sesuai spesifikasi).
  final Duration timeout;

  /// Template endpoint dengan placeholder `{q}`, `{source}`, `{target}`.
  final String endpointTemplate;

  static const String _defaultTemplate =
      'https://api.mymemory.translated.net/get?q={q}&langpair={source}|{target}';

  /// Test hook: HTTP client kustom (default `http.Client`).
  final http.Client Function()? clientFactory;

  Uri _buildUri(String text, String sourceLang, String targetLang) {
    final q = Uri.encodeQueryComponent(text);
    final source = Uri.encodeQueryComponent(sourceLang);
    final target = Uri.encodeQueryComponent(targetLang);
    return Uri.parse(
      endpointTemplate
          .replaceAll('{q}', q)
          .replaceAll('{source}', source)
          .replaceAll('{target}', target),
    );
  }

  /// Terjemahkan via endpoint publik. Lempar exception bila gagal / timeout /
  /// respons tidak berisi hasil (orchestrator yang menangani fallback).
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final client = clientFactory?.call() ?? http.Client();
    try {
      final uri = _buildUri(text, sourceLang, targetLang);
      final response =
          await client.get(uri).timeout(timeout, onTimeout: () {
        throw TimeoutException(
          'Tier 3 web translation timeout (${timeout.inSeconds}s)',
          timeout,
        );
      });

      if (response.statusCode != 200) {
        throw http.ClientException(
          'Tier 3 HTTP ${response.statusCode}',
          uri,
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw FormatException('Tier 3: body bukan JSON object');
      }
      final result = decoded['responseData'];
      final translated = (result is Map) ? result['translatedText'] : null;
      if (translated is! String || translated.trim().isEmpty) {
        throw const FormatException('Tier 3: translatedText kosong');
      }
      return _decodeEntities(translated.trim());
    } finally {
      if (clientFactory == null) client.close();
    }
  }

  /// Decode entity HTML umum yang dikembalikan beberapa endpoint.
  static String _decodeEntities(String input) {
    return input
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }
}

/// Orkestrator cascade terjemahan 3-tier.
class TranslationService {
  TranslationService._();

  static final TranslationService instance = TranslationService._();

  /// Provider Tier 2 (NMT offline). Default `MarianNmtProvider` tanpa runner
  /// (menjadi no-op aman sampai runtime ONNX dipasang).
  LocalNmtProvider localNmtProvider = MarianNmtProvider();

  /// Provider Tier 3 (web publik). Default `PublicWebNmtProvider`.
  PublicWebNmtProvider publicWebProvider = PublicWebNmtProvider();

  /// Deadline total untuk cascade (default 6 detik) — mencegah chat tertahan
  /// lama bila Tier 2 lambat & Tier 3 timeout.
  Duration totalDeadline = const Duration(seconds: 6);

  /// True bila model aktif mendukung direct multilingual execution (Tier 1).
  /// Di-set orchestrator (ChatCubit) dari state model; default `false` agar
  /// middleware aktif secara konservatif.
  bool tier1DirectModelActive = false;

  /// Opt-in Tier 3 (default `false`). Di-set dari `ModelManager`.
  bool webTierEnabled = false;

  /// Cache hasil untuk pasangan bahasa + teks identik (avoid re-request di
  /// streaming ulang). Kosongkan via [clearCache] bila sumber teks berubah.
  final Map<String, String> _cache = {};

  void clearCache() => _cache.clear();

  String _cacheKey(String text, String s, String t) => '$s|$t|$text';

  /// Jalankan cascade terjemahan.
  ///
  /// Mengembalikan [TranslationOutcome]:
  ///   - Tier 1 (modelDirect) bila [tier1DirectModelActive] — teks asli,
  ///     tanpa terjemahan, tanpa I/O.
  ///   - Tier 2 (localNmt) bila model NMT offline tersedia & berhasil.
  ///   - Tier 3 (publicWeb) bila web opt-in aktif & berhasil (timeout 3s).
  ///   - Fallback directModelPassThrough bila semua gagal — teks asli, LFM2.5
  ///     tetap menjawab (tidak crash, tidak bubble kosong).
  Future<TranslationOutcome> translate(
    String text, {
    String sourceLang = 'id',
    String targetLang = 'en',
  }) async {
    final trimmed = text.trim();

    // Tier 1 — model Qwen: prompt langsung, tanpa middleware.
    if (tier1DirectModelActive) {
      return TranslationOutcome(tier: TranslationTier.modelDirect, text: text);
    }

    // Input kosong: tidak perlu terjemahan.
    if (trimmed.isEmpty) {
      return TranslationOutcome(
        tier: TranslationTier.directModelPassThrough,
        text: text,
      );
    }

    final cacheKey = _cacheKey(trimmed, sourceLang, targetLang);
    final cached = _cache[cacheKey];
    if (cached != null) {
      return TranslationOutcome(tier: TranslationTier.localNmt, text: cached);
    }

    final reasons = <String>[];
    try {
      // Tier 2 — NMT offline.
      if (await localNmtProvider.isAvailable(sourceLang, targetLang)) {
        final out = await localNmtProvider.translate(
          trimmed,
          sourceLang: sourceLang,
          targetLang: targetLang,
        ).timeout(totalDeadline);
        if (out.trim().isNotEmpty) {
          _cache[cacheKey] = out;
          return TranslationOutcome(tier: TranslationTier.localNmt, text: out);
        }
        reasons.add('Tier 2: hasil kosong');
      } else {
        reasons.add('Tier 2: model NMT offline tidak tersedia');
      }
    } catch (e) {
      reasons.add('Tier 2 gagal: $e');
    }

    // Tier 3 — web publik (account-less), HANYA bila opt-in aktif.
    if (webTierEnabled) {
      try {
        final out = await publicWebProvider.translate(
          trimmed,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
        if (out.trim().isNotEmpty) {
          _cache[cacheKey] = out;
          return TranslationOutcome(tier: TranslationTier.publicWeb, text: out);
        }
        reasons.add('Tier 3: hasil kosong');
      } catch (e) {
        reasons.add('Tier 3 gagal: $e');
      }
    } else {
      reasons.add('Tier 3 dilewati: opt-in jaringan nonaktif');
    }

    // Fallback — teruskan teks asli ke LFM2.5 (offline-safe, tanpa crash).
    return TranslationOutcome(
      tier: TranslationTier.directModelPassThrough,
      text: text,
      error: reasons.join(' | '),
    );
  }
}