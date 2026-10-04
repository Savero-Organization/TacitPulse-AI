import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tacit_pulse_ai/core/services/translation_service.dart';

/// Provider NMT offline yang bisa dikontrol test.
class _FakeNmt implements LocalNmtProvider {
  _FakeNmt({required this.available, this.result, this.throwsError = false});

  bool available;
  String? result;
  bool throwsError;
  int callCount = 0;

  @override
  Future<bool> isAvailable(String sourceLang, String targetLang) async =>
      available;

  @override
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    callCount++;
    if (throwsError) throw StateError('onnx session gagal');
    return result ?? text;
  }
}

/// HTTP client palsu untuk menguji parsing + timeout Tier 3.
class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient({required this.handler, this.delay = Duration.zero});

  final Future<http.Response> Function(http.BaseRequest request) handler;
  final Duration delay;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final response = await handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

TranslationService _service() => TranslationService.instance;

void main() {
  setUp(() {
    final s = _service();
    s
      ..tier1DirectModelActive = false
      ..webTierEnabled = false
      ..localNmtProvider = _FakeNmt(available: false)
      ..publicWebProvider = PublicWebNmtProvider()
      ..totalDeadline = const Duration(seconds: 6);
    s.clearCache();
  });

  group('TranslationService cascade', () {
    test('Tier 1 (model direct) → prompt apa adanya, tanpa NMT/web',
        () async {
      final nmt = _FakeNmt(available: true, result: 'translated');
      final s = _service()
        ..tier1DirectModelActive = true
        ..localNmtProvider = nmt;

      final out = await s.translate('ganti solenoid pompa');

      expect(out.tier, TranslationTier.modelDirect);
      expect(out.text, 'ganti solenoid pompa');
      expect(out.wasTranslated, isFalse);
      expect(nmt.callCount, 0);
    });

    test('Tier 2 NMT offline dipakai saat model LFM2.5 aktif', () async {
      final s = _service()
        ..localNmtProvider =
            _FakeNmt(available: true, result: 'replace the pump solenoid');

      final out = await s.translate('ganti solenoid pompa');

      expect(out.tier, TranslationTier.localNmt);
      expect(out.text, 'replace the pump solenoid');
      expect(out.wasTranslated, isTrue);
    });

    test('Tier 2 gagal → Tier 3 dipakai bila web opt-in aktif', () async {
      final s = _service()
        ..localNmtProvider =
            _FakeNmt(available: true, throwsError: true)
        ..webTierEnabled = true
        ..publicWebProvider = PublicWebNmtProvider(
          clientFactory: () => _FakeHttpClient(
            handler: (_) async => http.Response(
              jsonEncode({
                'responseData': {'translatedText': 'replace the solenoid'},
              }),
              200,
            ),
          ),
        );

      final out = await s.translate('ganti solenoid pompa');

      expect(out.tier, TranslationTier.publicWeb);
      expect(out.text, 'replace the solenoid');
    });

    test('Tier 3 DILEWATI bila opt-in nonaktif (default offline-safe)',
        () async {
      final s = _service()
        ..localNmtProvider = _FakeNmt(available: false)
        ..webTierEnabled = false;

      final out = await s.translate('ganti solenoid pompa');

      expect(out.tier, TranslationTier.directModelPassThrough);
      expect(out.text, 'ganti solenoid pompa');
      expect(out.error, contains('Tier 3 dilewati'));
    });

    test('Tier 3 timeout 3 detik → jatuh ke direct LFM2.5 pass-through',
        () async {
      final s = _service()
        ..localNmtProvider = _FakeNmt(available: false)
        ..webTierEnabled = true
        ..publicWebProvider = PublicWebNmtProvider(
          timeout: const Duration(milliseconds: 200),
          clientFactory: () => _FakeHttpClient(
            handler: (_) async => http.Response('{}', 200),
            delay: const Duration(seconds: 5),
          ),
        );

      final out = await s.translate('ganti solenoid pompa');

      expect(out.tier, TranslationTier.directModelPassThrough);
      expect(out.text, 'ganti solenoid pompa');
      expect(out.error, contains('Tier 3 gagal'));
    });

    test('Tier 3 respons rusak → jatuh ke direct pass-through', () async {
      final s = _service()
        ..localNmtProvider = _FakeNmt(available: false)
        ..webTierEnabled = true
        ..publicWebProvider = PublicWebNmtProvider(
          clientFactory: () => _FakeHttpClient(
            handler: (_) async => http.Response(
              jsonEncode({'responseData': {'translatedText': ''}}),
              200,
            ),
          ),
        );

      final out = await s.translate('ganti solenoid pompa');

      expect(out.tier, TranslationTier.directModelPassThrough);
      expect(out.error, contains('Tier 3'));
    });

    test('input kosong → pass-through tanpa menyentuh tier mana pun',
        () async {
      final nmt = _FakeNmt(available: true, result: 'x');
      final s = _service()..localNmtProvider = nmt;

      final out = await s.translate('   ');

      expect(out.tier, TranslationTier.directModelPassThrough);
      expect(nmt.callCount, 0);
    });

    test('hasil Tier 2 di-cache (giliran identik tidak memanggil NMT lagi)',
        () async {
      final nmt = _FakeNmt(available: true, result: 'cached result');
      final s = _service()..localNmtProvider = nmt;

      await s.translate('solenoid');
      final second = await s.translate('solenoid');

      expect(second.tier, TranslationTier.localNmt);
      expect(nmt.callCount, 1);
    });
  });

  group('MarianNmtProvider', () {
    test('tanpa runner → tidak tersedia (tidak crash)', () async {
      final provider = MarianNmtProvider(
        rootOverride: () async => Directory.systemTemp.createTempSync('nmt'),
      );
      expect(await provider.isAvailable('id', 'en'), isFalse);
    });

    test('berkas model.onnx ada → tersedia & menerjemahkan via runner',
        () async {
      final root = Directory.systemTemp.createTempSync('nmt_ok');
      addTearDown(() => root.deleteSync(recursive: true));
      final pairDir = Directory('${root.path}/models/nmt/id-en')
        ..createSync(recursive: true);
      File('${pairDir.path}/model.onnx').writeAsBytesSync([1, 2, 3]);

      final provider = MarianNmtProvider(
        rootOverride: () async => root,
        runner: (text, source, target) async => '$text|$source-$target',
      );

      expect(await provider.isAvailable('id', 'en'), isTrue);
      final out = await provider.translate(
        'solenoid',
        sourceLang: 'id',
        targetLang: 'en',
      );
      expect(out, 'solenoid|id-en');
    });

    test('pasangan bahasa lain tidak tersedia → orchestrator fallback',
        () async {
      final root = Directory.systemTemp.createTempSync('nmt_missing');
      addTearDown(() => root.deleteSync(recursive: true));
      final provider = MarianNmtProvider(
        rootOverride: () async => root,
        runner: (text, source, target) async => text,
      );
      expect(await provider.isAvailable('id', 'en'), isFalse);
    });
  });

  group('PublicWebNmtProvider', () {
    test('URL dibangun dengan langpair + q ter-encode', () async {
      Uri? seen;
      final provider = PublicWebNmtProvider(
        clientFactory: () => _FakeHttpClient(
          handler: (req) async {
            seen = req.url;
            return http.Response(
              jsonEncode({
                'responseData': {'translatedText': 'a &amp; b'},
              }),
              200,
            );
          },
        ),
      );

      final out = await provider.translate(
        'pompa & katup',
        sourceLang: 'id',
        targetLang: 'en',
      );

      expect(out, 'a & b');
      expect(seen!.queryParameters['langpair'], 'id|en');
      expect(seen!.queryParameters['q'], 'pompa & katup');
    });

    test('HTTP non-200 → lempar ClientException (orchestrator fallback)',
        () async {
      final provider = PublicWebNmtProvider(
        clientFactory: () => _FakeHttpClient(
          handler: (_) async => http.Response('nope', 503),
        ),
      );
      expect(
        () => provider.translate('x', sourceLang: 'id', targetLang: 'en'),
        throwsA(isA<http.ClientException>()),
      );
    });
  });
}