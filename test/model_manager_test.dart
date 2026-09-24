import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tacit_pulse_ai/core/utils/model_loader.dart';

class _FakePathProvider extends Fake with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.documentsPath, this.downloadsPath);

  final String documentsPath;
  final String downloadsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getDownloadsPath() async => downloadsPath;
}

/// Membangun byte header GGUF minimal yang valid
/// (magic "GGUF" + metadata `general.architecture` & `general.name`).
Uint8List buildGgufBytes({
  String architecture = 'qwen2',
  String name = 'Qwen2-0.8B-Instruct',
  int version = 3,
}) {
  final b = BytesBuilder(copy: false);
  Uint8List le32(int v) {
    final d = ByteData(4);
    d.setUint32(0, v, Endian.little);
    return d.buffer.asUint8List();
  }

  Uint8List le64(int v) {
    final d = ByteData(8);
    d.setUint64(0, v, Endian.little);
    return d.buffer.asUint8List();
  }

  void str(String s) {
    final bytes = utf8.encode(s);
    b.add(le64(bytes.length));
    b.add(bytes);
  }

  void kv(String key, String value) {
    str(key);
    b.add(le32(8)); // GGUFValueType.string = 8
    str(value);
  }

  b.add([0x47, 0x47, 0x55, 0x46]); // "GGUF"
  b.add(le32(version));
  b.add(le64(0)); // tensor_count
  const kvs = {
    'general.architecture': '',
    'general.name': '',
  };
  b.add(le64(kvs.length));
  kv('general.architecture', architecture);
  kv('general.name', name);
  return b.toBytes();
}

void main() {
  late Directory tempDir;
  late String docsPath;
  late String downloadsPath;

  /// Folder cache unduhan (staging `.tmp`) — proper `/tmp` via
  /// `Directory.systemTemp`, dan ikut terhapus saat `tempDir` dibuang.
  late String cachePath;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('model_manager_test');
    docsPath = '${tempDir.path}/docs';
    downloadsPath = '${tempDir.path}/Download';
    cachePath = '${tempDir.path}/download_cache';
    Directory(downloadsPath).createSync(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    PathProviderPlatform.instance =
        _FakePathProvider(docsPath, downloadsPath);
    ModelPaths.dataRootOverride = () async => Directory(docsPath);
    ModelManager.downloadCacheOverride = () async => Directory(cachePath);
  });

  tearDown(() {
    ModelPaths.dataRootOverride = null;
    ModelManager.downloadCacheOverride = null;
    tempDir.deleteSync(recursive: true);
    PathProviderPlatform.instance = _InitialPlatform();
  });

  group('ModelManager.findModel', () {
    test('null ketika model belum ada', () async {
      expect(await ModelManager.findModel(), isNull);
    });

    test('path ketika model ada, direktori models dibuat otomatis', () async {
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.defaultModelName}')
          .writeAsStringSync('gguf');

      final path = await ModelManager.findModel();
      expect(path, '$docsPath/models/${ModelManager.defaultModelName}');
    });
  });

  group('ModelManager.copyFromDownloads', () {
    test('null ketika file tidak ada di Downloads', () async {
      expect(await ModelManager.copyFromDownloads(), isNull);
    });

    test('menyalin file dari Downloads ke direktori internal', () async {
      final source =
          File('$downloadsPath/${ModelManager.defaultModelName}')
            ..writeAsStringSync('gguf-data');

      final dest = await ModelManager.copyFromDownloads();

      expect(
        dest,
        '$docsPath/models/${ModelManager.defaultModelName}',
      );
      expect(File(dest!).readAsStringSync(), source.readAsStringSync());
    });
  });

  group('ModelManager.downloadModel', () {
    test('unduh fresh (tanpa .tmp): request tanpa Range, file final valid',
        () async {
      final full = buildGgufBytes();
      String? seenRange;
      final client = MockClient.streaming((request, _) async {
        seenRange = request.headers['range'];
        return http.StreamedResponse(
          Stream.fromIterable([full]),
          200,
          headers: {'content-length': '${full.length}'},
        );
      });

      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'fresh.gguf',
        client: client,
      );

      expect(seenRange, isNull);
      expect(path, '$docsPath/models/fresh.gguf');
      expect(File(path!).readAsBytesSync(), full);
      // Sukses → seluruh folder cache unduhan ikut perished (hanya cache).
      expect(File('$docsPath/models/fresh.gguf.tmp').existsSync(), isFalse);
      expect(Directory(cachePath).existsSync(), isFalse);
    });

    test('resume 50%: kirim Range bytes=N-, 206 append, progress mulai di N',
        () async {
      final full = buildGgufBytes();
      final halfLen = full.length ~/ 2;
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      File('$cachePath/resume.gguf.tmp')
          .writeAsBytesSync(full.sublist(0, halfLen));

      String? seenRange;
      final progress = <int>[];
      final client = MockClient.streaming((request, _) async {
        seenRange = request.headers['range'];
        return http.StreamedResponse(
          Stream.fromIterable([full.sublist(halfLen)]),
          206,
          headers: {
            'content-range': 'bytes $halfLen-${full.length - 1}/${full.length}',
            'content-length': '${full.length - halfLen}',
          },
        );
      });

      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'resume.gguf',
        client: client,
        onProgress: (done, total) => progress.add(done),
      );

      expect(seenRange, 'bytes=$halfLen-');
      expect(path, '${dir.path}/resume.gguf');
      expect(File(path!).readAsBytesSync(), full);
      // Sukses → folder cache (.tmp) ikut perished.
      expect(Directory(cachePath).existsSync(), isFalse);
      // Resume harus melanjutkan dari 50%, bukan restart dari 0.
      expect(progress.first, halfLen);
      expect(progress.last, full.length);
    });

    test('interrupt di tengah menyimpan .tmp; unduh ulang resume dari 50%',
        () async {
      final full = buildGgufBytes();
      final halfLen = full.length ~/ 2;
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      final tmpPath = '$cachePath/resume.gguf.tmp';

      // Attempt 1: koneksi putus setelah separuh byte terkirim.
      Stream<List<int>> halfThenFail() async* {
        yield full.sublist(0, halfLen);
        throw const SocketException('connection reset oleh peer');
      }

      final flaky = MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          halfThenFail(),
          200,
          headers: {'content-length': '${full.length}'},
        );
      });

      expect(
        await ModelManager.downloadModel(
          url: 'https://example.com/model.gguf',
          fileName: 'resume.gguf',
          client: flaky,
        ),
        isNull,
      );

      // .tmp parsial harus dipertahankan untuk resume.
      final tmpFile = File(tmpPath);
      expect(tmpFile.existsSync(), isTrue);
      expect(tmpFile.lengthSync(), halfLen);

      // Attempt 2: server melayani Range → lanjut dari byte ke-halfLen.
      String? seenRange;
      final resumeClient = MockClient.streaming((request, _) async {
        seenRange = request.headers['range'];
        return http.StreamedResponse(
          Stream.fromIterable([full.sublist(halfLen)]),
          206,
          headers: {
            'content-range': 'bytes $halfLen-${full.length - 1}/${full.length}',
            'content-length': '${full.length - halfLen}',
          },
        );
      });

      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'resume.gguf',
        client: resumeClient,
      );

      expect(seenRange, 'bytes=$halfLen-');
      expect(path, '${dir.path}/resume.gguf');
      expect(File(path!).readAsBytesSync(), full);
    });

    test('server abaikan Range (balas 200) → tulis ulang dari 0', () async {
      final full = buildGgufBytes();
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      // .tmp basi yang lebih panjang dari respons baru → harus ditimpa.
      File('$cachePath/rewrite.gguf.tmp')
          .writeAsBytesSync('<garbage parsial lama yang basi>'.codeUnits);

      final client = MockClient.streaming((request, _) async {
        expect(request.headers['range'], 'bytes=32-');
        return http.StreamedResponse(
          Stream.fromIterable([full]),
          200,
          headers: {'content-length': '${full.length}'},
        );
      });

      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'rewrite.gguf',
        client: client,
      );

      expect(path, '${dir.path}/rewrite.gguf');
      expect(File(path!).readAsBytesSync(), full);
    });

    test('unduhan tidak lengkap → null, .tmp dipertahankan untuk resume',
        () async {
      final full = buildGgufBytes();
      final dir = Directory('$docsPath/models')..createSync(recursive: true);

      // Stream selesai "normal" tapi lebih pendek dari content-length.
      final client = MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.fromIterable([full.sublist(0, 10)]),
          200,
          headers: {'content-length': '${full.length}'},
        );
      });

      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'partial.gguf',
        client: client,
      );

      expect(path, isNull);
      // Gagal (belum lengkap) → `.tmp` dipertahankan di folder cache untuk
      // resume; destinasi final tetap kosong.
      expect(File('$cachePath/partial.gguf.tmp').existsSync(), isTrue);
      expect(File('${dir.path}/partial.gguf').existsSync(), isFalse);
    });

    test('file terunduh bukan GGUF valid → null dan .tmp dihapus', () async {
      final garbage = '[BODY] bukan model GGUF sama sekali';
      final client = MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.fromIterable([
            garbage.codeUnits,
          ]),
          200,
          headers: {'content-length': '${garbage.length}'},
        );
      });

      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'invalid.gguf',
        client: client,
      );

      expect(path, isNull);
      // File lengkap tapi bukan GGUF → `.tmp` di cache dihapus.
      expect(File('$cachePath/invalid.gguf.tmp').existsSync(), isFalse);
    });

    test('.tmp basi (416) → hapus lalu unduh ulang dari 0 otomatis', () async {
      final full = buildGgufBytes();
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      File('$cachePath/stale.gguf.tmp').writeAsBytesSync(full.sublist(0, 10));

      final calls = <String?>[];
      final client = MockClient.streaming((request, _) async {
        final range = request.headers['range'];
        calls.add(range);
        if (range != null) {
          return http.StreamedResponse(
            const Stream.empty(),
            416,
            headers: {'content-range': 'bytes */${full.length}'},
          );
        }
        return http.StreamedResponse(
          Stream.fromIterable([full]),
          200,
          headers: {'content-length': '${full.length}'},
        );
      });

      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'stale.gguf',
        client: client,
      );

      expect(calls, ['bytes=10-', null]);
      expect(path, '${dir.path}/stale.gguf');
      expect(File(path!).readAsBytesSync(), full);
    });

    test('folder cache default ada di system temp (proper /tmp) + perished saat sukses',
        () async {
      // Pakai resolver DEFAULT (system temp), bukan override setUp.
      ModelManager.downloadCacheOverride = null;
      final cache = await ModelManager.downloadCacheDir();

      expect(cache.path, startsWith(Directory.systemTemp.path));
      expect(cache.path, contains(ModelManager.downloadCacheDirName));
      expect(cache.existsSync(), isTrue);

      // Unduhan sukses → seluruh folder cache ikut perished.
      final full = buildGgufBytes();
      final client = MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.fromIterable([full]),
          200,
          headers: {'content-length': '${full.length}'},
        );
      });
      final path = await ModelManager.downloadModel(
        url: 'https://example.com/model.gguf',
        fileName: 'purge_cache.gguf',
        client: client,
      );

      expect(path, '$docsPath/models/purge_cache.gguf');
      expect(File(path!).readAsBytesSync(), full);
      expect(cache.existsSync(), isFalse, reason: 'cache hanyalah folder '
          'sementara — harus lenyap setelah model berhasil diunduh');
    });
  });

  group('ModelManager.parseContentRangeTotal', () {
    test('parse total dari header Content-Range', () {
      expect(
        ModelManager.parseContentRangeTotal('bytes 100-499/1000'),
        1000,
      );
      expect(
        ModelManager.parseContentRangeTotal('bytes 0-0/532617596'),
        532617596,
      );
      expect(
        ModelManager.parseContentRangeTotal('bytes */532617596'),
        532617596,
      );
    });

    test('null untuk header tidak terbaca / tanpa total', () {
      expect(ModelManager.parseContentRangeTotal(null), isNull);
      expect(ModelManager.parseContentRangeTotal('bytes 100-499'), isNull);
      expect(ModelManager.parseContentRangeTotal(''), isNull);
    });
  });

  group('ModelManager.resolveModelPath', () {
    test('return path standard storage bila model target ada & valid',
        () async {
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.defaultModelName}')
          .writeAsBytesSync(buildGgufBytes());

      expect(await ModelManager.resolveModelPath(),
          '$docsPath/models/${ModelManager.defaultModelName}');
    });

    test('return null bila file internal bukan GGUF yang valid', () async {
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.defaultModelName}')
          .writeAsStringSync('gguf');

      expect(await ModelManager.resolveModelPath(), isNull);
    });

    test('custom path dari SharedPreferences dipakai duluan bila valid',
        () async {
      final custom = File('${tempDir.path}/custom/model.gguf')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(buildGgufBytes());

      await ModelManager.setCustomModelPath(custom.path);

      expect(await ModelManager.resolveModelPath(), custom.path);
    });

    test('custom path relatif POSIX (tanpa /) dinormalisasi ke absolut '
        '(home/savero/... ≡ /home/savero/...)', () async {
      final custom = File('${tempDir.path}/custom/model.gguf')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(buildGgufBytes());

      // Hilangkan '/' depan → bentuk "relatif dari root" yang harus
      // dinormalisasi ulang oleh resolveModelPath menjadi absolut.
      final relative = custom.path.substring(1);
      await ModelManager.setCustomModelPath(relative);

      expect(custom.path.startsWith('/'), isTrue);
      expect(await ModelManager.resolveModelPath(), custom.path);
    });

    test('custom path tidak valid → lanjut ke tier standard storage',
        () async {
      final broken = File('${tempDir.path}/broken.gguf')
        ..writeAsStringSync('bukan-gguf');
      await ModelManager.setCustomModelPath(broken.path);

      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.defaultModelName}')
          .writeAsBytesSync(buildGgufBytes());

      expect(await ModelManager.resolveModelPath(),
          '$docsPath/models/${ModelManager.defaultModelName}');
    });

    test('fallback ke P2P mesh cache bila storage standard kosong',
        () async {
      final cache = Directory('$docsPath/${ModelManager.meshCacheDirName}')
        ..createSync(recursive: true);
      File('${cache.path}/qwen3.5-0.8b.q4_k_m.gguf')
          .writeAsBytesSync(buildGgufBytes());

      expect(await ModelManager.resolveModelPath(),
          '${cache.path}/qwen3.5-0.8b.q4_k_m.gguf');
    });

    test('null (bukan throw) bila tidak tersedia di semua tier', () async {
      expect(await ModelManager.resolveModelPath(), isNull);
    });
  });
}

class _InitialPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {}