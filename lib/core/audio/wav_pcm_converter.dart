// wav_pcm_converter.dart — konversi file WAV (16 kHz, mono, 16-bit PCM)
// menjadi List<double> ternormalisasi untuk WhisperBridge.transcribe().
//
// Header RIFF di-parse per-chunk (bukan asumsi 44 byte) karena iOS dapat
// menambahkan chunk tambahan / WAVE_FORMAT_EXTENSIBLE, dan encoder lain bisa
// merapikan layout header. Format data divalidasi sebelum decode.

import 'dart:io';
import 'dart:typed_data';

/// Ukuran header RIFF/WAVE kanonik (untuk dokumen & fast-path).
const int kWavHeaderSize = 44;

/// Baca [wavFilePath] lalu kembalikan sampel PCM sebagai float ternormalisasi
/// (Int16 / 32768.0, rentang -1.0..1.0) siap untuk WhisperBridge.
///
/// Melempar [FileSystemException] bila file tidak ada dan [FormatException]
/// bila format tidak didukung (bukan 16 kHz mono 16-bit PCM).
Future<List<double>> extractPcm16kSamples(String wavFilePath) async {
  final file = File(wavFilePath);
  if (!file.existsSync()) {
    throw FileSystemException('File WAV tidak ditemukan', wavFilePath);
  }
  final bytes = await file.readAsBytes();
  return pcmFromWavBytes(bytes);
}

/// Versi sinkron berbasis buffer (dipakai uji & decode di isolate lain).
List<double> pcmFromWavBytes(Uint8List bytes) {
  if (bytes.length < 12) {
    throw const FormatException('File terlalu kecil untuk header WAV');
  }
  bool tagEquals(int offset, String tag) {
    for (var i = 0; i < tag.length; i++) {
      if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (!tagEquals(0, 'RIFF') || !tagEquals(8, 'WAVE')) {
    throw const FormatException('Bukan file RIFF/WAVE yang valid');
  }

  final bd = ByteData.sublistView(bytes);
  int? audioFormat;
  int? numChannels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataOffset;
  int? dataLength;

  var pos = 12;
  while (pos + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final chunkSize = bd.getUint32(pos + 4, Endian.little);
    final bodyStart = pos + 8;
    if (chunkId == 'fmt ') {
      if (bodyStart + 16 > bytes.length) break;
      audioFormat = bd.getUint16(bodyStart, Endian.little);
      numChannels = bd.getUint16(bodyStart + 2, Endian.little);
      sampleRate = bd.getUint32(bodyStart + 4, Endian.little);
      bitsPerSample = bd.getUint16(bodyStart + 14, Endian.little);
    } else if (chunkId == 'data') {
      dataOffset = bodyStart;
      dataLength = chunkSize;
      break;
    }
    pos = bodyStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }

  if (audioFormat != 1 || numChannels != 1 || sampleRate != 16000 ||
      bitsPerSample != 16) {
    throw const FormatException(
      'Hanya WAV PCM 16 kHz mono 16-bit yang didukung',
    );
  }
  if (dataOffset == null || dataLength == null ||
      dataOffset + dataLength > bytes.length) {
    throw const FormatException('Chunk data WAV tidak valid');
  }
  if (dataLength == 0 || dataLength % 2 != 0) {
    throw const FormatException(
      'Panjang data PCM bukan kelipatan 2 byte (bukan Int16)',
    );
  }

  final sampleCount = dataLength ~/ 2;
  final out = List<double>.filled(sampleCount, 0.0);
  for (var i = 0; i < sampleCount; i++) {
    var sample = bytes[dataOffset + i * 2] |
        (bytes[dataOffset + i * 2 + 1] << 8);
    if (sample >= 0x8000) sample -= 0x10000; // unsigned → int16
    out[i] = sample / 32768.0;
  }
  return out;
}
