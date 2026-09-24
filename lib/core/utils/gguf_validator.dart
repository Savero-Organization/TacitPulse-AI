// Validator GGUF ringan — memverifikasi file model on-device sebelum
// dioper ke llama.cpp (FFI native).
//
// Cukup membaca header file (magic GGUF + beberapa pasangan metadata)
// sehingga aman untuk file model berukuran ratusan MB tanpa memuat
// ke memory.
//
// Format header GGUF v3 (little-endian):
//   magic         : uint32 = 0x46554747 (ASCII "GGUF")
//   version       : uint32
//   tensor_count  : uint64
//   metadata_kv_count : uint64
//   metadata kv    : (key: GGUF string, value_type: uint32, value)
//   … tensor info
//
// Target yang dicari: keluarga Qwen (arktitektur qwen2 / qwen3 / qwen3.5)
// dengan ukuran 0.8B / 0.5B (default `qwen3.5-0.8b-q4_k_m.gguf`).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Hasil validasi satu file model.
class GgufValidationResult {
  const GgufValidationResult({
    required this.isValidGguf,
    required this.isTargetModel,
    this.architecture,
    this.modelName,
    this.fileName,
    this.errorMessage,
  });

  /// Benar bila file memulai dengan magic bytes GGUF (`0x46554747`).
  final bool isValidGguf;

  /// Benar bila file terdeteksi sebagai model target keluarga Qwen
  /// ukuran 0.8B / 0.5B (via metadata ataupun nama file).
  final bool isTargetModel;

  /// Arsitektur GGUF dari metadata `general.architecture`
  /// (contoh: "qwen2", "qwen3", "llama", null bila tidak terbaca).
  final String? architecture;

  /// Nama model dari metadata `general.name` (contoh: "Qwen2.5-0.5B-Instruct").
  final String? modelName;

  /// Nama file yang divalidasi.
  final String? fileName;

  /// Pesan tambahan; null saat file valid & cocok, berisi detail
  /// penolakan saat tidak.
  final String? errorMessage;

  /// Gabungan: aman dipakai langsung sebagai model LLM.
  bool get validForUse => isValidGguf && isTargetModel;
}

/// Validator kecil untuk file `.gguf` (llama.cpp) on-device.
class GgufValidator {
  GgufValidator._();

  /// Label model target yang diekspektasikan app.
  static const String targetModelLabel = 'Qwen 3.5 0.8B';

  /// Arsitektur yang dikenali sebagai keluarga Qwen.
  static const List<String> _qwenArchMarks = [
    'qwen2',
    'qwen3',
    'qwen3.5',
    'qwen',
  ];

  /// Penanda ukuran target (0.8B / 0.5B) pada nama/deskripsi model.
  static const List<String> _targetSizeMarks = ['0.8b', '0.5b'];

  static const int _ggufMagic = 0x46554747;

  static const String _kArchitectureKey = 'general.architecture';
  static const String _kNameKey = 'general.name';

  /// Normalkan input path user menjadi absolute path yang valid.
  ///
  /// Menangani:
  ///   - whitespace berlebih (di-trim);
  ///   - ekspansi `~` (tilde → `HOME` / `USERPROFILE`);
  ///   - path POSIX tanpa `/` di depan (mis. `home/user/...` →
  ///     `/home/user/...`, sehingga dievaluasi sebagai absolute);
  ///   - segment `.` / `..` dan separator redundan (normalisasi leksikal).
  ///
  /// Pada Windows path dibiarkan absolut dengan separator `\` (tanpa
  /// prepend `/`). Input kosong dikembalikan apa adanya.
  static String normalizePath(String rawPath) {
    var path = rawPath.trim();
    if (path.isEmpty) return path;

    final isWindows = Platform.isWindows;
    final sep = isWindows ? r'\' : '/';

    // Ekspansi tilde (~ / ~/tujuan).
    if (path.startsWith('~')) {
      var home = Platform.environment[isWindows ? 'USERPROFILE' : 'HOME'];
      home ??= Platform.environment[isWindows ? 'HOME' : 'USERPROFILE'];
      if (home == null || home.isEmpty) {
        home = isWindows
            ? (Platform.environment['HOMEDRIVE'] ?? 'C:') +
                  (Platform.environment['HOMEPATH'] ?? r'\Users')
            : sep;
      }
      home = home.replaceAll('/', sep);
      final rest = path.substring(1);
      path = rest.isEmpty
          ? home
          : (rest.startsWith('/') || rest.startsWith(r'\'))
              ? home + rest
              : home + sep + rest;
    }

    if (isWindows) {
      // Windows: samakan separator, pertahankan drive/UNC apa adanya.
      path = path.replaceAll('/', r'\');
      while (path.contains(r'\\')) {
        path = path.replaceAll(r'\\', r'\');
      }
      return path;
    }

    // POSIX (Linux/macOS): pastikan absolute, lalu normalize segment.
    if (!path.startsWith('/')) path = '/$path';
    final parts = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return '/${parts.join('/')}';
  }

  /// Validasi file model via [File].
  static Future<GgufValidationResult> validate(File file) {
    return validateFile(file.path);
  }

  /// Validasi file model beserta metadatanya dari jalur [path].
  ///
  /// Jalur dinormalisasi dulu via [normalizePath] (tilde, relatif-POSIX,
  /// segment `.`/`..`) sehingga `~/...`, `home/user/...`, dan `/home/...`
  /// semua merujuk ke file yang sama.
  ///
  /// Tidak pernah melempar: semua kondisi error (file hilang, header
  /// rusak, tidak terbaca) dikembalikan sebagai [GgufValidationResult]
  /// dengan `isValidGguf = false` + [GgufValidationResult.errorMessage].
  static Future<GgufValidationResult> validateFile(String path) async {
    path = normalizePath(path);
    final file = File(path);
    final fileName = path.split(Platform.pathSeparator).last;
    if (!await file.exists()) {
      return GgufValidationResult(
        isValidGguf: false,
        isTargetModel: false,
        fileName: fileName,
        errorMessage: 'File tidak ditemukan: $path',
      );
    }

    try {
      final raf = await file.open();
      try {
        return await _readHeader(raf, fileName);
      } finally {
        await raf.close();
      }
    } on FormatException catch (e) {
      return GgufValidationResult(
        isValidGguf: false,
        isTargetModel: false,
        fileName: fileName,
        errorMessage: e.message,
      );
    } catch (e) {
      return GgufValidationResult(
        isValidGguf: false,
        isTargetModel: false,
        fileName: fileName,
        errorMessage: 'Gagal membaca file: $e',
      );
    }
  }

  static Future<GgufValidationResult> _readHeader(
    RandomAccessFile raf,
    String fileName,
  ) async {
    final reader = _GgufHeaderReader(raf, await raf.length());

    final magic = await reader.readBytes(4);
    if (_u32le(magic) != _ggufMagic) {
      return GgufValidationResult(
        isValidGguf: false,
        isTargetModel: false,
        fileName: fileName,
        errorMessage:
            'Bukan file GGUF valid — magic bytes "GGUF" tidak ditemukan '
            'di awal file.',
      );
    }

    await reader.readBytes(4); // version
    await reader.readUint64(); // tensor_count
    final kvCount = await reader.readUint64();
    final maxKv = kvCount > 65536 ? 65536 : kvCount;

    String? architecture;
    String? modelName;

    for (var i = 0; i < maxKv; i++) {
      final key = await reader.readString();
      final valueType = await reader.readUint32();

      // Metadata tokenizer muncul setelah blok general.*; arsitektur & nama
      // sudah pasti terbaca sebelumnya — berhenti agar tidak membaca
      // vocab besar (ribuan string) yang tidak relevan.
      if (key.startsWith('tokenizer.')) break;

      if (key == _kArchitectureKey) {
        if (valueType == _GgufValueType.string_) {
          architecture = await reader.readString();
        } else {
          await reader.skipValue(valueType);
        }
      } else if (key == _kNameKey) {
        if (valueType == _GgufValueType.string_) {
          modelName = await reader.readString();
        } else {
          await reader.skipValue(valueType);
        }
      } else {
        await reader.skipValue(valueType);
      }

      if (architecture != null && modelName != null) break;
    }

    final isQwenFamily = _isQwenFamily(architecture, modelName, fileName);
    final matchesTargetSize = _matchesTargetSize(modelName, fileName);
    final isTarget = isQwenFamily && matchesTargetSize;

    String? message;
    if (!isTarget) {
      if (!isQwenFamily) {
        final detected = architecture == null
            ? 'tidak diketahui'
            : '$architecture${modelName == null ? '' : ' ($modelName)'}';
        message =
            'File GGUF valid, tetapi bukan model Qwen. Arsitektur terdeteksi: '
            '$detected. Diharapkan: $targetModelLabel.';
      } else {
        final detected = modelName ?? '*tidak terbaca / nama file*';
        message =
            'Arsitektur Qwen cocok, tetapi ukuran model tidak sesuai '
            '(terdeteksi "$detected"). Diharapkan ukuran 0.8B atau 0.5B '
            'dengan quantisasi keluarga Q4 (contoh q4_k_m).';
      }
    }

    return GgufValidationResult(
      isValidGguf: true,
      isTargetModel: isTarget,
      architecture: architecture,
      modelName: modelName,
      fileName: fileName,
      errorMessage: message,
    );
  }

  static bool _isQwenFamily(
    String? architecture,
    String? modelName,
    String fileName,
  ) {
    final arch = (architecture ?? '').toLowerCase();
    if (_qwenArchMarks.any(arch.contains)) return true;
    final combined = '${modelName ?? ''} $fileName'.toLowerCase();
    return _qwenArchMarks.any(combined.contains);
  }

  static bool _matchesTargetSize(String? modelName, String fileName) {
    final combined = '${modelName ?? ''} $fileName'.toLowerCase();
    return _targetSizeMarks.any(combined.contains);
  }

  static int _u32le(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint32(0, Endian.little);
}

/// Nama konstanta tipe nilai GGUF (bagian dari `GGUFValueType`).
abstract final class _GgufValueType {
  static const int uint8 = 0;
  static const int int8 = 1;
  static const int uint16 = 2;
  static const int int16 = 3;
  static const int uint32 = 4;
  static const int int32 = 5;
  static const int float32 = 6;
  static const int bool_ = 7;
  static const int string_ = 8;
  static const int array = 9;
  static const int uint64 = 10;
  static const int int64 = 11;
  static const int float64 = 12;
}

/// Reader sequential little-endian untuk header GGUF dengan page kecil.
class _GgufHeaderReader {
  _GgufHeaderReader(this._handle, this._length);

  final RandomAccessFile _handle;
  final int _length;
  int _pos = 0;

  Future<Uint8List> readBytes(int n) async {
    if (_pos + n > _length) {
      throw FormatException(
        'Header GGUF terpotong / file terlalu pendek (posisi $_pos, butuh $n byte, '
        'total $_length byte).',
      );
    }
    await _handle.setPosition(_pos);
    final bytes = await _handle.read(n);
    if (bytes.length != n) {
      throw const FormatException('Header GGUF tidak terbaca lengkap.');
    }
    _pos += n;
    return bytes;
  }

  Future<int> readUint32() async {
    final raw = await readBytes(4);
    return ByteData.sublistView(raw).getUint32(0, Endian.little);
  }

  Future<int> readUint64() async {
    final raw = await readBytes(8);
    return ByteData.sublistView(raw).getUint64(0, Endian.little);
  }

  Future<String> readString() async {
    final len = await readUint64();
    if (len > 0x7FFFFF) {
      throw FormatException('GGUF string metadata terlalu panjang ($len byte).');
    }
    final raw = await readBytes(len);
    return utf8.decode(raw, allowMalformed: true);
  }

  Future<void> skip(int n) async {
    if (n < 0 || _pos + n > _length) {
      throw const FormatException('GGUF metadata melewati akhir header.');
    }
    _pos += n;
  }

  /// Lompati satu nilai GGUF berdasarkan [valueType] (tanpa materialisasi).
  Future<void> skipValue(int valueType) async {
    switch (valueType) {
      case _GgufValueType.uint8:
      case _GgufValueType.int8:
      case _GgufValueType.bool_:
        return skip(1);
      case _GgufValueType.uint16:
      case _GgufValueType.int16:
        return skip(2);
      case _GgufValueType.uint32:
      case _GgufValueType.int32:
      case _GgufValueType.float32:
        return skip(4);
      case _GgufValueType.uint64:
      case _GgufValueType.int64:
      case _GgufValueType.float64:
        return skip(8);
      case _GgufValueType.string_:
        final len = await readUint64();
        return skip(len);
      case _GgufValueType.array:
        final elementType = await readUint32();
        final count = await readUint64();
        if (count > 100000000) {
          throw const FormatException('GGUF array metadata terlalu besar.');
        }
        if (elementType == _GgufValueType.string_) {
          for (var i = 0; i < count; i++) {
            final len = await readUint64();
            await skip(len);
          }
        } else {
          final size = _fixedSizeOf(elementType);
          await skip(count * size);
        }
        return;
      default:
        throw FormatException('GGUF value type tidak dikenal: $valueType');
    }
  }

  static int _fixedSizeOf(int valueType) => switch (valueType) {
        _GgufValueType.uint8 ||
        _GgufValueType.int8 ||
        _GgufValueType.bool_ =>
          1,
        _GgufValueType.uint16 || _GgufValueType.int16 => 2,
        _GgufValueType.uint32 ||
        _GgufValueType.int32 ||
        _GgufValueType.float32 =>
          4,
        _GgufValueType.uint64 ||
        _GgufValueType.int64 ||
        _GgufValueType.float64 =>
          8,
        _ => throw FormatException(
            'GGUF array element type tidak dikenal: $valueType',
          ),
      };
}