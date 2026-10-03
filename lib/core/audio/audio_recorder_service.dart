// audio_recorder_service.dart — layanan perekaman suara 16 kHz mono WAV
// untuk pipeline Voice-to-SOP (TP302 / GABUT-48, GABUT-49).
//
// Konfigurasi sengaja diselaraskan dengan kebutuhan whisper.cpp:
//   WAV (RIFF/PCM), 16000 Hz, 1 channel (mono), 16-bit signed PCM.

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Konfigurasi rekaman standar untuk whisper.cpp.
const RecordConfig kWhisperRecordConfig = RecordConfig(
  encoder: AudioEncoder.wav,
  sampleRate: 16000,
  numChannels: 1,
  bitRate: 256000,
);

/// Antarmuka minimal atas `AudioRecorder` agar bisa di-mock di unit test
/// tanpa plugin native.
abstract class AudioRecorderHandle {
  Future<bool> hasPermission();
  Future<void> start(RecordConfig config, {required String path});
  Future<String?> stop();
  Future<void> cancel();
  Stream<RecordState> get onStateChanged;
  Stream<Amplitude> onAmplitudeChanged(Duration interval);
  Future<void> dispose();
}

/// Implementasi default: langsung membungkus `AudioRecorder` dari package:record.
class _AudioRecorderHandleImpl implements AudioRecorderHandle {
  _AudioRecorderHandleImpl() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(RecordConfig config, {required String path}) =>
      _recorder.start(config, path: path);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Stream<RecordState> get onStateChanged => _recorder.onStateChanged();

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _recorder.onAmplitudeChanged(interval);

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Service lifecycle perekaman audio teknisi.
class AudioRecorderService {
  AudioRecorderService({
    AudioRecorderHandle? recorder,
    Future<Directory> Function()? tempDirResolver,
    this.amplitudeInterval = const Duration(milliseconds: 200),
  })  : _recorder = recorder ?? _AudioRecorderHandleImpl(),
        _tempDirResolver = tempDirResolver ?? getTemporaryDirectory;

  final AudioRecorderHandle _recorder;
  final Future<Directory> Function() _tempDirResolver;
  final Duration amplitudeInterval;

  String? _currentPath;

  /// Path file rekaman aktif, null bila tidak sedang merekam.
  String? get currentPath => _currentPath;

  /// Cek + minta izin mikrofon. Dipakai UI sebelum [startRecording].
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Status rekaman native (`stopped` / `recording` / `paused`).
  Stream<RecordState> get onStateChanged => _recorder.onStateChanged;

  /// Amplitude realtime untuk visualisasi waveform.
  Stream<Amplitude> get onAmplitudeChanged =>
      _recorder.onAmplitudeChanged(amplitudeInterval);

  /// Mulai rekaman 16 kHz mono WAV.
  ///
  /// [customPath] opsional: bila null, file dibuat di temporary directory
  /// dengan nama `tacit_capture_<timestamp>.wav`.
  Future<void> startRecording({String? customPath}) async {
    if (_currentPath != null) {
      throw StateError('Rekaman sedang berjalan — hentikan dulu');
    }
    final granted = await _recorder.hasPermission();
    if (!granted) {
      throw StateError('Izin mikrofon ditolak');
    }
    final dir = await _tempDirResolver();
    final path = customPath ??
        '${dir.path}/tacit_capture_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(kWhisperRecordConfig, path: path);
    // Set hanya setelah start sukses, supaya path tidak pernah menunjuk
    // ke rekaman yang gagal dimulai.
    _currentPath = path;
  }

  /// Hentikan rekaman; mengembalikan path file .wav (null bila tidak aktif).
  Future<String?> stopRecording() async {
    final path = await _recorder.stop() ?? _currentPath;
    _currentPath = null;
    return path;
  }

  /// Hentikan lalu hapus file sementara hasil rekaman.
  Future<String?> cancelRecording() async {
    final path = _currentPath;
    _currentPath = null;
    try {
      await _recorder.cancel();
    } catch (_) {
      // Handle tidak sedang merekam — lanjut hapus file bila ada.
    }
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
    return path;
  }

  /// Bebaskan resource native plugin.
  Future<void> dispose() => _recorder.dispose();
}
