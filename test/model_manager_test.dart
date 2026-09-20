import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
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

void main() {
  late Directory tempDir;
  late String docsPath;
  late String downloadsPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('model_manager_test');
    docsPath = '${tempDir.path}/docs';
    downloadsPath = '${tempDir.path}/Download';
    Directory(downloadsPath).createSync(recursive: true);
    PathProviderPlatform.instance =
        _FakePathProvider(docsPath, downloadsPath);
  });

  tearDown(() {
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

  group('ModelManager.resolveModelPath', () {
    test('return path internal bila model sudah ada', () async {
      final dir = Directory('$docsPath/models')..createSync(recursive: true);
      File('${dir.path}/${ModelManager.defaultModelName}')
          .writeAsStringSync('gguf');

      expect(await ModelManager.resolveModelPath(),
          '$docsPath/models/${ModelManager.defaultModelName}');
    });

    test('fallback salin dari Downloads bila belum ada di internal',
        () async {
      File('$downloadsPath/${ModelManager.defaultModelName}')
          .writeAsStringSync('gguf-data');

      expect(await ModelManager.resolveModelPath(),
          '$docsPath/models/${ModelManager.defaultModelName}');
      expect(
        File('$docsPath/models/${ModelManager.defaultModelName}')
            .readAsStringSync(),
        'gguf-data',
      );
    });

    test('StateError bila tidak tersedia di kedua lokasi', () async {
      expect(
        () => ModelManager.resolveModelPath(),
        throwsA(isA<StateError>()),
      );
    });
  });
}

class _InitialPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {}
