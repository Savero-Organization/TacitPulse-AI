// transfer_status.dart — Model status transfer + formatter.

import 'package:flutter/foundation.dart';

/// Status transfer satu file/model.
enum TransferState { connecting, transferring, paused, completed, failed }

/// Snapshot satu transfer: file, progress, throughput, keadaan.
@immutable
class TransferStatus {
  const TransferStatus({
    required this.fileName,
    required this.receivedBytes,
    required this.totalBytes,
    this.speedBytesPerSec = 0,
    this.state = TransferState.connecting,
  }) : assert(receivedBytes >= 0, 'receivedBytes tidak boleh negatif'),
       assert(totalBytes >= 0, 'totalBytes tidak boleh negatif');

  final String fileName;
  final int receivedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final TransferState state;

  /// Progres 0.0–1.0.
  double get progress {
    if (totalBytes <= 0) return 0.0;
    final p = receivedBytes / totalBytes;
    return p.clamp(0.0, 1.0);
  }

  int get percent => (progress * 100).round();

  bool get isPaused => state == TransferState.paused;
  bool get isFailed => state == TransferState.failed;
  bool get isCompleted => state == TransferState.completed;
  bool get isActive =>
      state == TransferState.transferring || state == TransferState.connecting;

  double get receivedMB => receivedBytes / (1024 * 1024);
  double get totalMB => totalBytes / (1024 * 1024);

  /// ETA berdasarkan throughput saat ini; null bila tidak bisa dihitung.
  Duration? get remaining {
    if (isCompleted) return Duration.zero;
    if (isFailed) return null;
    if (speedBytesPerSec <= 0) return null;
    final remainingBytes = totalBytes - receivedBytes;
    if (remainingBytes <= 0) return Duration.zero;
    final seconds = remainingBytes / speedBytesPerSec;
    // Batas atas 99 jam agar tidak overflow Duration/int saat kecepatan
    // mendekati nol (socket stall → B/s sangat kecil).
    if (seconds > 356400) return const Duration(hours: 99);
    return Duration(seconds: seconds.round());
  }

  TransferStatus copyWith({
    String? fileName,
    int? receivedBytes,
    int? totalBytes,
    double? speedBytesPerSec,
    TransferState? state,
  }) =>
      TransferStatus(
        fileName: fileName ?? this.fileName,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
        state: state ?? this.state,
      );
}

/// Kontroler nilai [TransferStatus] yang dapat didengar (ChangeNotifier).
class TransferStatusController extends ValueNotifier<TransferStatus> {
  TransferStatusController(super.value);
}

/// "1024.0 KB/s" / "1.5 MB/s".
String formatSpeed(double bytesPerSec) {
  if (bytesPerSec >= 1024 * 1024) {
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
}

/// "mm:ss" untuk kurang dari satu jam; "hh:mm:ss" untuk ≥ 1 jam; "--:--"
/// bila null; "00:00" untuk durasi nol.
String formatEta(Duration? remaining) {
  if (remaining == null) return '--:--';
  final h = remaining.inHours;
  final m = remaining.inMinutes.remainder(60);
  final s = remaining.inSeconds.remainder(60);
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// "45.0%" — 1 desimal.
String formatPercent(double progress) =>
    '${(progress * 100).toStringAsFixed(1)}%';