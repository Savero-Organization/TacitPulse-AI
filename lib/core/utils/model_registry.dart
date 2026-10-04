// ModelRegistry — katalog model GGUF yang didukung app.
//
// Setiap entri membawa metadata lengkap untuk dipakai lintas fitur:
//   - ModelSettingsCubit   → menyimpan `id` pilihan user (SharedPreferences)
//   - ModelDownloadService → mulai unduhan dari [ModelInfo.downloadUrl]
//   - UI Model Picker      → menampilkan nama/ukuran/status per keluarga
//
// Keluarga model: Qwen (tier direct multilingual) vs LFM (middleware
// terjemahan). `ModelFamily` di sini sengaja terpisah dari enum bernama sama
// di `gguf_validator.dart` — registry murni data statis, sedangkan enum di
// validator berasal dari metadata GGUF saat runtime.

enum ModelFamily { qwen, lfm }

class ModelInfo {
  final String id;
  final String name;
  final ModelFamily family;
  final String downloadUrl;
  final String fileName;

  /// Ukuran fallback (MB) untuk label tombol unduh ketika HEAD request
  /// ke CDN gagal / offline.
  final double sizeInMb;

  const ModelInfo({
    required this.id,
    required this.name,
    required this.family,
    required this.downloadUrl,
    required this.fileName,
    this.sizeInMb = 0,
  });
}

class ModelRegistry {
  /// Liquid AI (LFM Family).
  static const ModelInfo lfm350m = ModelInfo(
    id: 'lfm_2_5_350m',
    name: 'LFM 2.5 350M (Q4_K_M)',
    family: ModelFamily.lfm,
    downloadUrl:
        'https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/resolve/main/LFM2.5-350M-Q4_K_M.gguf?download=true',
    fileName: 'LFM2.5-350M-Q4_K_M.gguf',
    sizeInMb: 229,
  );

  static const ModelInfo lfm230m = ModelInfo(
    id: 'lfm_2_5_230m',
    name: 'LFM 2.5 230M (Q4_K_M)',
    family: ModelFamily.lfm,
    downloadUrl:
        'https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF/resolve/main/LFM2.5-230M-Q4_K_M.gguf?download=true',
    fileName: 'LFM2.5-230M-Q4_K_M.gguf',
    sizeInMb: 160,
  );

  /// Qwen Family (Unsloth).
  static const ModelInfo qwen08b = ModelInfo(
    id: 'qwen_3_5_0_8b',
    name: 'Qwen 3.5 0.8B (Q4_K_M)',
    family: ModelFamily.qwen,
    downloadUrl:
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
    fileName: 'Qwen3.5-0.8B-Q4_K_M.gguf',
    sizeInMb: 512,
  );

  static const List<ModelInfo> allModels = [
    lfm350m,
    lfm230m,
    qwen08b,
  ];

  static ModelInfo get defaultModel => lfm350m;

  static List<ModelInfo> modelsFor(ModelFamily family) =>
      allModels.where((m) => m.family == family).toList(growable: false);

  static ModelInfo? byId(String? id) {
    if (id == null) return null;
    for (final m in allModels) {
      if (m.id == id) return m;
    }
    return null;
  }
}
