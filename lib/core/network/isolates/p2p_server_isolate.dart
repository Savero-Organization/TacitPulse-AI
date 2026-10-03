// p2p_server_isolate.dart — entry point isolate untuk server P2P.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

import '../handlers/model_file_handler.dart';

/// Entry point background isolate: server dimulai lalu menerima perintah
/// `stop` dan mengirim statistik realtime kembali ke parent.
Future<void> p2pServerIsolateMain(List<dynamic> args) async {
  final modelsDirPath = args[0] as String;
  final port = args[1] as int;
  final maxRateBytesPerSec = args[2] as int?;
  final sanitizedMaxRate =
      (maxRateBytesPerSec is int && maxRateBytesPerSec > 0)
          ? maxRateBytesPerSec
          : null;
  final SendPort parent = args[3] as SendPort;

  // Jalur balik untuk perintah control dari main thread.
  final control = ReceivePort();
  parent.send({'type': 'control', 'port': control.sendPort});

  var activeConnections = 0;
  var totalBytesServed = 0;
  var lastReportedBytes = 0;
  HttpServer? httpServer;

  // Timer statistik: hitung speed dari selisih byte tiap detik.
  final statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
    final delta = totalBytesServed - lastReportedBytes;
    lastReportedBytes = totalBytesServed;
    parent.send({
      'type': 'stats',
      'activeConnections': activeConnections,
      'currentSpeedBytesPerSec': delta.toDouble(),
      'totalBytesServed': totalBytesServed,
      'isRunning': httpServer != null,
    });
  });

  try {
    httpServer = await HttpServer.bind(InternetAddress.anyIPv4, port);

    final fileHandler = ModelFileHandler(
      modelsDirPath,
      maxRateBytesPerSec: sanitizedMaxRate,
      onBytesServed: (n) => totalBytesServed += n,
      onConnectionStart: () => activeConnections++,
      onConnectionEnd: () => activeConnections--,
    );

    final router = Router()
      ..get('/health', (Request req) {
        return Response.ok(
          jsonEncode({'status': 'ok', 'version': '1.0.0'}),
          headers: {'content-type': 'application/json'},
        );
      })
      ..get('/models', (Request req) async {
        final list = await _describeModels(modelsDirPath);
        return Response.ok(
          jsonEncode(list),
          headers: {'content-type': 'application/json'},
        );
      })
      ..get('/models/<filename>', (Request req) {
        final filename = req.params['filename'];
        if (filename == null) {
          return Future.value(Response.badRequest(body: 'missing filename'));
        }
        return fileHandler.handle(req, filename);
      });

    final server = IOServer(httpServer);
    server.mount(router.call);

    parent.send({'type': 'started', 'port': httpServer.port});
  } catch (e) {
    statsTimer.cancel();
    parent.send({'type': 'error', 'message': '$e'});
    httpServer = null;
  }

  control.listen((dynamic message) async {
    if (message is! Map) return;
    switch (message['cmd']) {
      case 'stop':
        final server = httpServer;
        httpServer = null;
        statsTimer.cancel();
        await server?.close(force: true);
        control.close();
        parent.send({
          'type': 'stats',
          'activeConnections': activeConnections,
          'currentSpeedBytesPerSec': 0.0,
          'totalBytesServed': totalBytesServed,
          'isRunning': false,
        });
        parent.send({'type': 'stopped'});
        break;
      default:
        break;
    }
  });
}

/// Cache hash per (path, ukuran, mtime) supaya `/models` tidak menghitung
/// ulang MD5 pada setiap request.
final Map<String, String> _hashCache = <String, String>{};

/// Batas file yang di-hash; di atas ini hanya ukuran file yang dilaporkan
/// agar hashing tetap murah.
const int _kMaxHashBytes = 64 * 1024 * 1024;

/// Daftar file di [modelsDirPath] beserta ukuran dan hash-nya.
///
/// Enumerasi dan hashing dilakukan asynchronously supaya isolate server tetap
/// bisa menulis chunk ke socket peer yang sedang mengunduh.
Future<List<Map<String, dynamic>>> _describeModels(String modelsDirPath) async {
  final dir = Directory(modelsDirPath);
  final list = <Map<String, dynamic>>[];
  if (!dir.existsSync()) return list;

  final entities = await dir.list(followLinks: false).toList();
  for (final entity in entities) {
    if (entity is! File) continue;
    final FileStat stat;
    try {
      stat = await entity.stat();
    } on FileSystemException {
      continue; // file hilang/terkunci saat listing.
    }
    if (stat.type != FileSystemEntityType.file) continue;

    String? hash;
    if (stat.size <= _kMaxHashBytes) {
      final cacheKey = '${entity.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
      final cached = _hashCache[cacheKey];
      if (cached != null) {
        hash = cached;
      } else {
        try {
          // Hash dialirkan dari file, bukan readAsBytes: memori tetap konstan
          // dan event loop tidak terblokir selama pembacaan.
          final digest = await md5.bind(entity.openRead()).first;
          hash = digest.toString();
          _hashCache[cacheKey] = hash;
        } on FileSystemException {
          hash = null;
        }
      }
    }

    list.add(<String, dynamic>{
      'filename': p.basename(entity.path),
      'sizeInBytes': stat.size,
      'hash': hash,
    });
  }
  return list;
}
