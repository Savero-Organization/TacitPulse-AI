// p2p_server_service.dart — kontrol server HTTP file di isolate terpisah.

import 'dart:async';
import 'dart:isolate';

import 'models/p2p_server_config.dart';
import 'models/p2p_server_stats.dart';
import 'isolates/p2p_server_isolate.dart';

/// Service yang menjalankan server HTTP P2P pada isolate terpisah.
abstract class P2pServerService {
  /// Memulai server pada [port] yang melayani file di [modelsDirPath].
  /// [maxRateBytesPerSec] opsional membatasi laju transfer.
  Future<void> start({
    required String modelsDirPath,
    required int port,
    int? maxRateBytesPerSec,
  });

  /// Menghentikan server dan membebaskan isolate.
  Future<void> stop();

  /// Stream statistik realtime (update tiap ~1 detik).
  Stream<P2pServerStats> get statsStream;

  /// Port server yang terikat (setelah [start]).
  int? get serverPort;
}

/// Implementasi default memakai isolate via shelf.
class P2pServerServiceImpl implements P2pServerService {
  P2pServerServiceImpl({this.config});

  /// Konfigurasi awal opsional (dipakai otomatis oleh start()).
  final P2pServerConfig? config;

  Isolate? _isolate;
  ReceivePort? _mainPort;
  SendPort? _control;
  final StreamController<P2pServerStats> _statsController =
      StreamController<P2pServerStats>.broadcast();
  int? _serverPort;
  Completer<void>? _started;

  @override
  Stream<P2pServerStats> get statsStream => _statsController.stream;

  @override
  int? get serverPort => _serverPort;

  @override
  Future<void> start({
    required String modelsDirPath,
    required int port,
    int? maxRateBytesPerSec,
  }) async {
    if (_isolate != null) {
      await stop();
    }
    _mainPort = ReceivePort();
    _started = Completer<void>();
    _isolate = await Isolate.spawn(
      p2pServerIsolateMain,
      [modelsDirPath, port, maxRateBytesPerSec, _mainPort!.sendPort],
    );
    _mainPort!.listen((dynamic event) {
      if (event is! Map) return;
      switch (event['type']) {
        case 'control':
          _control = event['port'] as SendPort;
          break;
        case 'started':
          _serverPort = event['port'] as int;
          if (!(_started?.isCompleted ?? true)) {
            _started?.complete();
          }
          break;
        case 'error':
          if (!(_started?.isCompleted ?? true)) {
            _started?.completeError(
              StateError(event['message'] as String? ?? 'unknown error'),
            );
          }
          break;
        case 'stats':
          _statsController.add(P2pServerStats.fromMap(
            Map<String, dynamic>.from(event),
          ));
          break;
        case 'stopped':
          _statsController.add(P2pServerStats.empty.copyWith(isRunning: false));
          break;
      }
    });
    try {
      await _started!.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      // Buang isolate yang gagal start.
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _mainPort?.close();
      _mainPort = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final isolate = _isolate;
    final mainPort = _mainPort;
    final control = _control;
    _isolate = null;
    _mainPort = null;
    _control = null;
    _statsController.add(P2pServerStats.empty.copyWith(isRunning: false));
    if (control != null) {
      control.send({'cmd': 'stop'});
      // Beri singkat waktu untuk graceful close.
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    isolate?.kill(priority: Isolate.immediate);
    mainPort?.close();
    _serverPort = null;
  }
}
