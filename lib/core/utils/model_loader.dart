import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Utility untuk lokasi penyimpanan model AI on-device (di memori internal aplikasi).
/// File `.gguf` (LLM) dan `.bin` (Whisper) disimpan di `<documents>/models`,
/// bukan di `assets/`.
class ModelLoader {
  static Future<String> getModelPath(String fileName) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory('${docsDir.path}/models');
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return '${modelsDir.path}/$fileName';
  }
}