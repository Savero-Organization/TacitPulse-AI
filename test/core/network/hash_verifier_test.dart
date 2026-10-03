import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/network/utils/hash_verifier.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('hash_verify_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('computeSha256 menghasilkan hex SHA-256 yang benar', () async {
    const content = 'Tacit Pulse AI knowledge store\n';
    final file = File('${tempDir.path}/sample.bin')..writeAsStringSync(content);

    final actual = await computeSha256(file);
    final expected = sha256.convert(content.codeUnits).toString();
    expect(actual, expected);
    expect(actual.length, 64);
  });

  test('mengstream banyak chunk: onProgress monoton & total sesuai', () async {
    final bytes = List<int>.generate(300000, (i) => i % 256);
    final file = File('${tempDir.path}/big.bin')..writeAsBytesSync(bytes);

    final progress = <(int, int)>[];
    await computeSha256(
      file,
      onProgress: (processed, total) => progress.add((processed, total)),
    );

    expect(progress, isNotEmpty);
    // Tiap panggilan: processed non-decreasing dan total selalu ukuran file.
    for (var i = 0; i < progress.length; i++) {
      expect(progress[i].$2, bytes.length);
      if (i > 0) expect(progress[i].$1, greaterThanOrEqualTo(progress[i - 1].$1));
    }
    expect(progress.last.$1, bytes.length);
  });

  test('verifyFileHash: cocok vs tidak cocok (case-insensitive)', () async {
    const content = 'xx-tacit-pulse';
    final file = File('${tempDir.path}/f.bin')..writeAsStringSync(content);
    final good = sha256.convert(content.codeUnits).toString();

    expect(await verifyFileHash(file, good), isTrue);
    expect(await verifyFileHash(file, good.toUpperCase()), isTrue);
    expect(await verifyFileHash(file, '0' * 64), isFalse);
  });

  test('verifyFileHash mengembalikan false untuk file hilang', () async {
    final missing = File('${tempDir.path}/does_not_exist.gguf');
    expect(await verifyFileHash(missing, 'abc'), isFalse);
    expect(() => computeSha256(missing), throwsA(isA<FileSystemException>()));
  });
}