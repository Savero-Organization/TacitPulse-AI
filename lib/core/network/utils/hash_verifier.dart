// hash_verifier.dart — SHA-256 streaming untuk file besar & verifikasi.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Menghitung SHA-256 sebuah file tanpa memuatnya penuh ke memori.
///
/// Byte mengalir dari [File.openRead] ke [sha256.bind], jadi penggunaan RAM
/// independen dari ukuran file. [onProgress] dipanggil tiap chunk dengan
/// (bytesProcessed, totalBytes) bila disediakan. Melemparkan
/// [FileSystemException] bila file tidak ada/tidak bisa dibaca.
Future<String> computeSha256(
  File file, {
  void Function(int bytesProcessed, int totalBytes)? onProgress,
}) async {
  final totalBytes = await file.length();
  var bytesProcessed = 0;
  final Stream<List<int>> progressStream = file.openRead().transform(
    StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (List<int> chunk, EventSink<List<int>> sink) {
        bytesProcessed += chunk.length;
        onProgress?.call(bytesProcessed, totalBytes);
        sink.add(chunk);
      },
    ),
  );
  final digest = await sha256.bind(progressStream).first;
  return digest.toString();
}

/// Memverifikasi bahwa hash SHA-256 file cocok dengan [expectedHash].
///
/// Perbandingan hex bersifat case-insensitive; whitespace di ujung awal/akhir
/// [expectedHash] diabaikan (spasi dalam di tengah masih dianggap tidak
/// sama — bersihkan sebelum dibandingkan bila perlu).
/// Mengembalikan `false` bila file hilang/tidak terbaca atau terjadi
/// kesalahan lain selama hashing (tidak melempar).
Future<bool> verifyFileHash(File file, String expectedHash) async {
  try {
    final actual = await computeSha256(file);
    return actual.toLowerCase() == expectedHash.trim().toLowerCase();
  } catch (_) {
    return false;
  }
}