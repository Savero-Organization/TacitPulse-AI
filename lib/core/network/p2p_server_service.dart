// p2p_server_service.dart — kontrol server HTTP file di isolate terpisah.

import 'dart:async';
import 'dart:isolate';

import 'models/p2p_server_config.dart';
import 'models/p2p_server_stats.dart';
import 'isolates/p2p_server_isolate.dart';

/// Service yang menjalankan server HTTP P2P pada isolate terpisah.
abstract class P2pServerService {
  /// Memulai server. Bila argumen tidak diberikan, nilai dari [P2pServerConfig]
  /// yang dipakai constructor service menjadi fallback.
  Future<void> start({
    String? modelsDirPath,
    int? port,
    int? maxRateBytesPerSec,
  });

  /// Menghentikan server dan melepas isolate.
  Future<void> stop();

  /// Stream statistik realtime (update tiap ~1 detik).
  Stream<P2pServerStats> get statsStream;

  /// Port server yang terikat (setelah [start] selesai).
  int? get serverPort;

  /// Matrix terakhir yang diterima dari isolate.
  P2pServerStats get lastStats;

  /// Menutup service selamanya; stats stream ditutup dan server dihentikan.
  Future<void> dispose();
}

/// Implementasi default memakai isolate via shelf.
class P2pServerServiceImpl implements P2pServerService {
  P2pServerServiceImpl({this.config});

  /// Konfigurasi opsional. Nilai argumen eksplisit pada [start] selalu
  /// menang; field ini hanya dipakai sebagai fallback bila argumen null.
  final P2pServerConfig? config;

  Isolate? _isolate;
  ReceivePort? _mainPort;
  SendPort? _control;
  Completer<void>? _started;
  Completer<void>? _stopped;
  int? _serverPort;
  P2pServerStats _lastStats = P2pServerStats.empty;
  bool _disposed = false;

  final StreamController<P2pServerStats> _statsController =
      StreamController<P2pServerStats>.broadcast();

  @override
  Stream<P2pServerStats> get statsStream => _statsController.stream;

  @override
  int? get serverPort => _serverPort;

  @override
  P2pServerStats get lastStats => _lastStats;

  void _emit(P2pServerStats stats) {
    _lastStats = stats;
    if (!_statsController.isClosed) {
      _statsController.add(stats);
    }
  }

  @override
  Future<void> start({
    String? modelsDirPath,
    int? port,
    int? maxRateBytesPerSec,
  }) async {
    if (_disposed) {
      throw StateError('P2pServerServiceImpl sudah di-dispose');
    }
    final modelsDir = modelsDirPath ?? config?.modelsDirPath;
    final bindPort = port ?? config?.port;
    final rate = maxRateBytesPerSec ?? config?.maxRateBytesPerSec;
    if (modelsDir == null || bindPort == null) {
      throw ArgumentError(
        'modelsDirPath dan port wajib diisi lewat argumen start() atau P2pServerConfig',
      );
    }

    // Tunggu start yang sedang berjalan supaya tidak ada isolate yatim.
    final inFlight = _started;
    if (_isolate != null || inFlight != null) {
      await stop();
    }

    final mainPort = ReceivePort();
    final started = Completer<void>();
    _mainPort = mainPort;
    _started = started;

    mainPort.listen((dynamic event) {
      if (event is! Map) return;
      switch (event['type']) {
        case 'control':
          _control = event['port'] as SendPort;
          break;
        case 'started':
          _serverPort = event['port'] as int;
          if (!started.isCompleted) started.complete();
          break;
        case 'error':
          if (!started.isCompleted) {
            started.completeError(
              StateError(event['message'] as String? ?? 'unknown error'),
            );
          }
          break;
        case 'stats':
          final map = Map<String, dynamic>.from(event);
          map.remove('type');
          _emit(P2pServerStats.fromMap(map));
          break;
        case 'stopped':
          // Pertahankan counter; yang berubah hanya status berjalan.
          _emit(_lastStats.copyWith(isRunning: false));
          final stopped = _stopped;
          if (stopped != null && !stopped.isCompleted) stopped.complete();
          break;
      }
    });

    try {
      _isolate = await Isolate.spawn(
        p2pServerIsolateMain,
        [modelsDir, bindPort, rate, mainPort.sendPort],
      );
    } catch (e) {
      mainPort.close();
      _mainPort = null;
      _started = null;
      rethrow;
    }

    try {
      await started.future.timeout(const Duration(seconds: 10));
      // Tandai langsung agar lastStats/isRunning akurat sejak start selesai,
      // tanpa harus menunggu tick statistik pertama dari isolate.
      _emit(_lastStats.copyWith(isRunning: true));
    } catch (_) {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _started = null;
      mainPort.close();
      _mainPort = null;
      _serverPort = null;
      rethrow;
    }
    _started = null;
  }

  @override
  Future<void> stop() async {
    final isolate = _isolate;
    final mainPort = _mainPort;
    final control = _control;
    final stopped = Completer<void>();

    _isolate = null;
    _mainPort = null;
    _control = null;
    _started = null;
    _stopped = stopped;
    _serverPort = null;
    _emit(_lastStats.copyWith(isRunning: false));

    if (control == null) {
      // belum sempat start / isolate sudah mati.
      isolate?.kill(priority: Isolate.immediate);
      mainPort?.close();
      _stopped = null;
      return;
    }

    control.send({'cmd': 'stop'});
    try {
      // Tunggu ack supaya graceful close selesai dan pesan 'stopped' terkirim.
      await stopped.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      isolate?.kill(priority: Isolate.immediate);
    } finally {
      _stopped = null;
      mainPort?.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _statsController.close();
  }
}