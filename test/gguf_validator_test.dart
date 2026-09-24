import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/utils/gguf_validator.dart';

Uint8List _str(String s) {
  final bytes = utf8.encode(s);
  final out = BytesBuilder(copy: false);
  final d = ByteData(8);
  d.setUint64(0, bytes.length, Endian.little);
  out.add(d.buffer.asUint8List());
  out.add(bytes);
  return out.toBytes();
}

/// Bangun GGUF dengan support array metadata (untuk menguji skip-value).
Uint8List _buildGguf({
  String? architecture,
  String? name,
  bool includeArrayBefore = false,
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

  void str(String s) => b.add(_str(s));
  void kv(String key, String value) {
    str(key);
    b.add(le32(8)); // string = 8
    str(value);
  }

  b.add([0x47, 0x47, 0x55, 0x46]); // magic "GGUF"
  b.add(le32(3)); // version
  b.add(le64(0)); // tensor_count

  var count = 0;
  if (includeArrayBefore) {
    count += 1;
  }
  if (architecture != null) count++;
  if (name != null) count++;
  b.add(le64(count));

  if (includeArrayBefore) {
    // key "general.array_test": value type array(9) of string(8), count 2
    str('general.array_test');
    b.add(le32(9));
    b.add(le32(8)); // element type string
    b.add(le64(2));
    b.add(_str('pertama'));
    b.add(_str('kedua'));
  }
  if (architecture != null) kv('general.architecture', architecture);
  if (name != null) kv('general.name', name);

  return b.toBytes();
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('gguf_validator_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File writeFile(String name, List<int> bytes) =>
      File('${tempDir.path}/$name')..writeAsBytesSync(bytes);

  group('GgufValidator.validateFile', () {
    test('bukan GGUF (magic salah) → isValidGguf false + errorMessage',
        () async {
      final f = writeFile('bukan.gguf', utf8.encode('PK\x03\x04random'));
      final r = await GgufValidator.validateFile(f.path);

      expect(r.isValidGguf, isFalse);
      expect(r.isTargetModel, isFalse);
      expect(r.errorMessage, isNotNull);
    });

    test('file tidak ada → isValidGguf false', () async {
      final r = await GgufValidator.validateFile('${tempDir.path}/ghost.gguf');
      expect(r.isValidGguf, isFalse);
      expect(r.errorMessage, isNotNull);
    });

    test('GGUF Qwen 0.8B via metadata → target model', () async {
      final f = writeFile(
        'qwen.gguf',
        _buildGguf(architecture: 'qwen2', name: 'Qwen2-0.8B-Instruct'),
      );
      final r = await GgufValidator.validateFile(f.path);

      expect(r.isValidGguf, isTrue);
      expect(r.isTargetModel, isTrue);
      expect(r.architecture, 'qwen2');
      expect(r.modelName, 'Qwen2-0.8B-Instruct');
      expect(r.validForUse, isTrue);
    });

    test('GGUF valid tapi Llama → bukan target', () async {
      final f = writeFile(
        'llama.gguf',
        _buildGguf(architecture: 'llama', name: 'Llama-3-70B'),
      );
      final r = await GgufValidator.validateFile(f.path);

      expect(r.isValidGguf, isTrue);
      expect(r.isTargetModel, isFalse);
      expect(r.architecture, 'llama');
      expect(r.errorMessage, isNotNull);
    });

    test('GGUF Qwen tapi ukuran besar (> 0.8B) → bukan target', () async {
      final f = writeFile(
        'qwen-besar.gguf',
        _buildGguf(architecture: 'qwen2', name: 'Qwen2-7B'),
      );
      final r = await GgufValidator.validateFile(f.path);

      expect(r.isValidGguf, isTrue);
      expect(r.isTargetModel, isFalse);
      expect(r.errorMessage, isNotNull);
    });

    test('fallback nama file bila metadata tokenizer besar / tidak terbaca '
        '(nama file qwen + 0.8b tetap diterima)', () async {
      // Header valid tapi metadata hanya sampai magic (tidak ada general.*):
      // keputusan target diambil dari nama file.
      final f = writeFile('qwen3.5-0.8b-q4_k_m.gguf', _buildGguf());
      final r = await GgufValidator.validateFile(f.path);

      expect(r.isValidGguf, isTrue);
      expect(r.isTargetModel, isTrue);
    });

    test('skip array metadata sebelum general.* tidak merusak parse',
        () async {
      final f = writeFile(
        'skip-array.gguf',
        _buildGguf(
          architecture: 'qwen2',
          name: 'Qwen3-0.5B-Instruct',
          includeArrayBefore: true,
        ),
      );
      final r = await GgufValidator.validateFile(f.path);

      expect(r.isValidGguf, isTrue);
      expect(r.isTargetModel, isTrue);
      expect(r.architecture, 'qwen2');
      expect(r.modelName, 'Qwen3-0.5B-Instruct');
    });

    test('file terpotong setelah magic → isValidGguf false tanpa throw',
        () async {
      final f = writeFile('truncated.gguf', [0x47, 0x47, 0x55, 0x46]);
      final r = await GgufValidator.validateFile(f.path);

      // Magic ketemu tapi header tidak lengkap — validator tidak melempar,
      // dikembalikan sebagai error yang bisa ditampilkan ke UI.
      expect(r.isValidGguf, isFalse);
      expect(r.isTargetModel, isFalse);
      expect(r.errorMessage, isNotNull);
    });

    test('jalur relatif-POSIX (tanpa /) dinormalisasi → file yang sama ter-'
        'validasi (home/savero/... ≡ /home/savero/...)', () async {
      final f = writeFile(
        'qwen.gguf',
        _buildGguf(architecture: 'qwen2', name: 'Qwen2-0.8B-Instruct'),
      );
      // bentuk relatif = absolut tanpa '/' depan → normalizePath menambahkan
      // '/' kembali sehingga menunjuk ke file yang sama.
      final relative = f.path.substring(1);
      final r = await GgufValidator.validateFile(relative);

      expect(GgufValidator.normalizePath(relative), f.path);
      expect(r.isValidGguf, isTrue);
      expect(r.validForUse, isTrue);
    });
  });

  group('GgufValidator.normalizePath', () {
    test('trim whitespace & empty → empty', () {
      expect(GgufValidator.normalizePath('   '), '');
      expect(GgufValidator.normalizePath('  /a/b.gguf  '), '/a/b.gguf');
    });

    test('absolut POSIX dipertahankan', () {
      expect(
        GgufValidator.normalizePath('/home/savero/model.gguf'),
        '/home/savero/model.gguf',
      );
    });

    test('relatif POSIX (tanpa /) mendapat prefix / → menjadi absolut', () {
      expect(
        GgufValidator.normalizePath('home/savero/model.gguf'),
        '/home/savero/model.gguf',
      );
    });

    test('tilde diekspansi ke HOME', () {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      expect(GgufValidator.normalizePath('~/model.gguf'), '$home/model.gguf');
      expect(GgufValidator.normalizePath('~'), home);
    });

    test('spec: /home/savero/.., home/savero/.., ~/.. → absolute terkait'
        ' yang sama', () {
      // Bentuk absolut & relatif selalu identik secara struktural.
      expect(
        GgufValidator.normalizePath('home/savero/model.gguf'),
        GgufValidator.normalizePath('/home/savero/model.gguf'),
      );
      final home = Platform.environment['HOME'];
      if (home == '/home/savero') {
        expect(
          GgufValidator.normalizePath('~/model.gguf'),
          GgufValidator.normalizePath('/home/savero/model.gguf'),
        );
      } else if (home != null) {
        // Semua bentuk tilde mengarah ke HOME yang sama dengan absolut.
        expect(GgufValidator.normalizePath('~/model.gguf'), '$home/model.gguf');
      }
    });

    test('segment . dan .. dinormalisasi secara leksikal', () {
      expect(
        GgufValidator.normalizePath('/a/./b/../c.gguf'),
        '/a/c.gguf',
      );
      expect(GgufValidator.normalizePath('a/../../b.gguf'), '/b.gguf');
    });
  });
}