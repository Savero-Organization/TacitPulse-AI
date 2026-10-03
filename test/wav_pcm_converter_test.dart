import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/audio/wav_pcm_converter.dart';

/// Bangun buffer WAV kanonik (44-byte header) berisi sampel Int16 LE.
Uint8List buildWav(List<int> samples) {
  final dataSize = samples.length * 2;
  final total = kWavHeaderSize + dataSize;
  final bytes = Uint8List(total);
  final bd = ByteData.sublistView(bytes);
  // 'RIFF'
  bytes[0] = 0x52; bytes[1] = 0x49; bytes[2] = 0x46; bytes[3] = 0x46;
  bd.setUint32(4, total - 8, Endian.little);
  bytes[8] = 0x57; bytes[9] = 0x41; bytes[10] = 0x56; bytes[11] = 0x45; // WAVE
  bytes[12] = 0x66; bytes[13] = 0x6d; bytes[14] = 0x74; bytes[15] = 0x20; // 'fmt '
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, 1, Endian.little); // mono
  bd.setUint32(24, 16000, Endian.little);
  bd.setUint32(28, 32000, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  bytes[36] = 0x64; bytes[37] = 0x61; bytes[38] = 0x74; bytes[39] = 0x61; // 'data'
  bd.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(kWavHeaderSize + i * 2, samples[i], Endian.little);
  }
  return bytes;
}

void main() {
  group('pcmFromWavBytes', () {
    test('Int16 nol → 0.0', () {
      final wav = buildWav([0]);
      expect(pcmFromWavBytes(wav), [0.0]);
    });

    test('nilai ekstrem → -1.0 dan mendekati 1.0', () {
      final wav = buildWav([-32768, 32767]);
      final out = pcmFromWavBytes(wav);
      expect(out[0], -1.0);
      expect(out[1], closeTo(32767 / 32768.0, 1e-9));
    });

    test('Int16 negatif → float negatif ternormalisasi', () {
      final wav = buildWav([-16384, 16384]);
      final out = pcmFromWavBytes(wav);
      expect(out[0], closeTo(-0.5, 1e-6));
      expect(out[1], closeTo(0.5, 1e-6));
    });

    test('panjang output = jumlah sampel, bukan byte', () {
      final wav = buildWav(List.generate(160, (_) => 100));
      expect(pcmFromWavBytes(wav).length, 160);
    });

    test('bukan RIFF/WAVE → FormatException', () {
      final bad = Uint8List(64);
      expect(() => pcmFromWavBytes(bad), throwsFormatException);
    });

    test('lebih pendek dari 44 byte → FormatException', () {
      expect(() => pcmFromWavBytes(Uint8List(20)), throwsFormatException);
    });

    test('data PCM ganjil → FormatException', () {
      final wav = buildWav([1, 2]);
      // Patch ukuran chunk data jadi ganjil (bukan kelipatan Int16).
      final bd = ByteData.sublistView(wav);
      bd.setUint32(40, 5, Endian.little);
      final odd = Uint8List.fromList([...wav, 0x00]);
      expect(() => pcmFromWavBytes(odd), throwsFormatException);
    });

    test('format bukan PCM 16 kHz mono 16-bit → FormatException', () {
      final wav = buildWav([1, 2]);
      final bd = ByteData.sublistView(wav);
      bd.setUint16(22, 2, Endian.little); // stereo
      expect(() => pcmFromWavBytes(wav), throwsFormatException);
    });

    test('header dengan chunk ekstra sebelum data tetap ter-parse', () {
      final wav = buildWav([8192]);
      // Sisipkan chunk LIST (size 4 + padding) di antara fmt dan data.
      final extra = Uint8List(12)
        ..[0] = 0x4c // 'L'
        ..[1] = 0x49
        ..[2] = 0x53
        ..[3] = 0x54 // 'LIST'
        ..[4] = 4; // size 4 (genap → tanpa padding)
      final out = <int>[
        ...wav.sublist(0, 36 + 0),
      ];
      // Bangun ulang: header RIFF/fmt + chunk LIST + chunk data.
      final fmtEnd = 36; // offset 'data'
      final dataChunk = wav.sublist(fmtEnd);
      final merged = Uint8List(36 + extra.length + dataChunk.length)
        ..setRange(0, 36, wav)
        ..setRange(36, 36 + extra.length, extra)
        ..setRange(36 + extra.length, 36 + extra.length + dataChunk.length,
            dataChunk);
      // RIFF size tidak mempengaruhi parsing chunk, jadi cukup parse.
      expect(pcmFromWavBytes(merged), [0.25]);
      expect(out, isNotEmpty);
    });
  });

  group('extractPcm16kSamples', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('tacit_wav_');
    });

    tearDown(() {
      tempRoot.deleteSync(recursive: true);
    });

    test('membaca file WAV dari disk dan menormalisasi', () async {
      final file = File('${tempRoot.path}/test.wav')
        ..writeAsBytesSync(buildWav([0, 32767, -32768]));
      final out = await extractPcm16kSamples(file.path);
      expect(out.length, 3);
      expect(out[0], 0.0);
      expect(out[2], -1.0);
    });

    test('file tidak ada → FileSystemException', () async {
      await expectLater(
        extractPcm16kSamples('${tempRoot.path}/nope.wav'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
