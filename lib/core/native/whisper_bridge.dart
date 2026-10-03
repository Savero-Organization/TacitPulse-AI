// whisper_bridge.dart — bridge Dart ke C-API tacit_whisper (whisper.cpp).
//
// Arsitektur (mengikuti LLMInference / llama_bridge):
//   - Transkripsi (whisper_full, blocking) berjalan di worker isolate
//     terdedikasi supaya UI tidak terblokir.
//   - Native handle (Pointer<tacit_whisper_context>) hanya hidup di worker;
//     isolate utama tidak pernah menyentuh FFI langsung.
//   - Handle native WAJIB dilepas lewat tacit_whisper_free() saat shutdown —
//     tanpa itu model ggml-base.bin bocor per load.
//
// Audio input: 16 kHz, mono, IEEE 754 float (List<double> -> Float32List).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'tacit_whisper_bindings.g.dart';

/// Cross-platform DynamicLibrary loader untuk tacit_whisper native library.
/// Mirror dari openTacitLlamaLibrary di llm_inference.dart.
DynamicLibrary openTacitWhisperLibrary() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libtacit_whisper.so');
  } else if (Platform.isLinux) {
    try {
      return DynamicLibrary.open('libtacit_whisper.so');
    } catch (_) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final bundleLib = p.join(exeDir, 'lib', 'libtacit_whisper.so');
      if (File(bundleLib).existsSync()) {
        return DynamicLibrary.open(bundleLib);
      }
      final sameDirLib = p.join(exeDir, 'libtacit_whisper.so');
      if (File(sameDirLib).existsSync()) {
        return DynamicLibrary.open(sameDirLib);
      }
      rethrow;
    }
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('tacit_whisper.dll');
  } else if (Platform.isIOS || Platform.isMacOS) {
    return DynamicLibrary.process();
  }
  throw UnsupportedError(
    'Platform ${Platform.operatingSystem} is not supported.',
  );
}

/// Error generasi dari native (via tacit_whisper_last_error).
class WhisperException implements Exception {
  WhisperException(this.message);

  final String message;

  @override
  String toString() => 'WhisperException: $message';
}

/// Satu segmen transkripsi dengan offset waktu.
///
/// `t0`/`t1` memakai satuan waktu whisper.cpp (tick 10 ms), sama persis
/// dengan nilai `whisper_full_get_segment_t0/t1`.
class WhisperSegment {
  const WhisperSegment({
    required this.text,
    required this.t0,
    required this.t1,
  });

  final String text;
  final int t0;
  final int t1;

  @override
  bool operator ==(Object other) =>
      other is WhisperSegment &&
      other.text == text &&
      other.t0 == t0 &&
      other.t1 == t1;

  @override
  int get hashCode => Object.hash(text, t0, t1);

  @override
  String toString() => 'WhisperSegment(t0: $t0, t1: $t1, text: $text)';
}

/// Handle kuat atas konteks whisper.cpp native.
///
/// Pola single-worker per instance: satu [WhisperBridge] = satu worker
/// isolate = satu konteks native. Hubungi ulang [init] setelah [dispose]
/// untuk memuat ulang model.
class WhisperBridge {
  Isolate? _worker;
  SendPort? _requests;
  bool _disposed = false;

  /// Jalur model yang berhasil di-load (untuk diagnosis).
  String? modelPath;

  /// Muat model whisper (`ggml-base.bin`) dari disk.
  ///
  /// Melempar [FileSystemException] bila [modelPath] tidak ada — divalidasi
  /// sebelum native dipanggil — atau [WhisperException] bila native gagal.
  Future<void> init(String modelPath) async {
    if (_worker != null) {
      throw StateError('WhisperBridge sudah di-init; dispose() dulu.');
    }
    _disposed = false;
    if (!File(modelPath).existsSync()) {
      throw FileSystemException('Model whisper tidak ditemukan', modelPath);
    }

    final control = ReceivePort();
    try {
      _worker = await Isolate.spawn(_whisperWorkerMainOverride ?? _whisperWorkerMain, [
        modelPath,
        control.sendPort,
      ]);
    } catch (e) {
      control.close();
      throw WhisperException('Gagal spawn worker isolate: $e');
    }

    final done = Completer<void>();
    control.listen((Object? item) {
      if (item is! Map || item['type'] != 'init') return;
      control.close();
      if (item['ok'] == true) {
        _requests = item['port'] as SendPort;
        this.modelPath = modelPath;
        if (!done.isCompleted) done.complete();
      } else {
        _worker?.kill(priority: Isolate.immediate);
        _worker = null;
        if (!done.isCompleted) {
          done.completeError(
            WhisperException(
              item['error'] as String? ?? 'gagal init worker whisper',
            ),
          );
        }
      }
    });
    return done.future;
  }

  Future<_WhisperResult> _run(
    List<double> pcm16kSamples,
    String language,
  ) async {
    final requests = _requests;
    if (requests == null || _disposed) {
      throw StateError('WhisperBridge belum di-init atau sudah di-dispose');
    }
    if (pcm16kSamples.isEmpty) {
      throw ArgumentError.value(pcm16kSamples, 'pcm16kSamples', 'kosong');
    }
    final reply = ReceivePort();
    requests.send({
      'cmd': 'transcribe',
      'pcm': pcm16kSamples,
      'language': language,
      'reply': reply.sendPort,
    });
    try {
      await for (final Object? item in reply) {
        if (item is! Map) continue;
        if (item['type'] == 'result') {
          final segs = (item['segments'] as List)
              .cast<Map>()
              .map(
                (m) => WhisperSegment(
                  text: m['text'] as String,
                  t0: m['t0'] as int,
                  t1: m['t1'] as int,
                ),
              )
              .toList(growable: false);
          return _WhisperResult(segs);
        }
        if (item['type'] == 'error') {
          throw WhisperException(
            item['message'] as String? ?? 'gagal transkripsi',
          );
        }
      }
    } finally {
      reply.close();
    }
    throw WhisperException('worker whisper berhenti tanpa balasan');
  }

  /// Transkripsi satu buffer PCM menjadi teks tergabung.
  Future<String> transcribe(
    List<double> pcm16kSamples, {
    String language = 'id',
  }) async {
    final result = await _run(pcm16kSamples, language);
    return result.segments
        .map((s) => s.text)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Transkripsi menjadi daftar segmen ber-timestamp.
  Future<List<WhisperSegment>> transcribeSegments(
    List<double> pcm16kSamples, {
    String language = 'id',
  }) async {
    final result = await _run(pcm16kSamples, language);
    return result.segments;
  }

  /// Bebaskan handle worker + konteks native. Aman dipanggil berulang.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final requests = _requests;
    final worker = _worker;
    _requests = null;
    _worker = null;
    if (requests != null) {
      final ack = ReceivePort();
      try {
        requests.send({'cmd': 'shutdown', 'reply': ack.sendPort});
        await for (final Object? item
            in ack.timeout(const Duration(seconds: 5))) {
          if (item is Map && item['type'] == 'shutdown-ok') break;
        }
      } on TimeoutException {
        // worker stuck -> kill fallback di bawah
      } finally {
        ack.close();
      }
    }
    worker?.kill(priority: Isolate.immediate);
  }

  // Entry point worker yang bisa ditimpa untuk tes.
  static void Function(List<Object?> args)? _whisperWorkerMainOverride;

  /// Jembatan test-only: ganti entry point worker isolate dengan fake.
  /// Panggil dengan `null` di tearDown.
  static void setWorkerMainForTest(void Function(List<Object?> args)? main) {
    _whisperWorkerMainOverride = main;
  }
}

class _WhisperResult {
  const _WhisperResult(this.segments);
  final List<WhisperSegment> segments;
}

// ---------------------------------------------------------------------------
// Worker isolate — memegang binding + konteks whisper native.
// ---------------------------------------------------------------------------

void _whisperWorkerMain(List<Object?> args) {
  final modelPath = args[0] as String;
  final SendPort mainPort = args[1] as SendPort;

  TacitWhisperBindings bindings;
  try {
    bindings = TacitWhisperBindings(openTacitWhisperLibrary());
  } catch (e) {
    mainPort.send({
      'type': 'init',
      'ok': false,
      'error': 'Gagal membuka library native: $e',
    });
    return;
  }

  final pathPtr = modelPath.toNativeUtf8();
  final Pointer<tacit_whisper_context> ctx;
  try {
    ctx = bindings.tacit_whisper_init(pathPtr.cast<Char>());
  } finally {
    malloc.free(pathPtr);
  }
  if (ctx == nullptr) {
    mainPort.send({
      'type': 'init',
      'ok': false,
      'error': _nativeError(bindings) ?? 'tacit_whisper_init gagal',
    });
    return;
  }

  final requests = ReceivePort();
  mainPort.send({'type': 'init', 'ok': true, 'port': requests.sendPort});

  requests.listen((Object? msg) {
    if (msg is! Map) return;
    try {
      switch (msg['cmd']) {
        case 'transcribe':
          final reply = msg['reply'] as SendPort;
          final pcm = (msg['pcm'] as List).cast<double>();
          final language = (msg['language'] as String?) ?? 'id';
          final samples = Float32List.fromList(pcm);
          final pcmPtr = calloc<Float>(samples.length);
          try {
            pcmPtr.asTypedList(samples.length).setAll(0, samples);
            final langPtr = language.toNativeUtf8();
            int rc;
            try {
              rc = bindings.tacit_whisper_transcribe(
                ctx,
                pcmPtr,
                samples.length,
                langPtr.cast<Char>(),
              );
            } finally {
              malloc.free(langPtr);
            }
            if (rc != 0) {
              reply.send({
                'type': 'error',
                'message': _nativeError(bindings) ??
                    'tacit_whisper_transcribe rc=$rc',
              });
              break;
            }
            final n = bindings.tacit_whisper_full_n_segments(ctx);
            final segments = <Map<String, Object>>[];
            for (var i = 0; i < n; i++) {
              final textPtr =
                  bindings.tacit_whisper_full_get_segment_text(ctx, i);
              final text = textPtr == nullptr
                  ? ''
                  : textPtr.cast<Utf8>().toDartString();
              segments.add({
                'text': text,
                't0': bindings.tacit_whisper_full_get_segment_t0(ctx, i),
                't1': bindings.tacit_whisper_full_get_segment_t1(ctx, i),
              });
            }
            reply.send({'type': 'result', 'segments': segments});
          } catch (e) {
            reply.send({'type': 'error', 'message': '$e'});
          } finally {
            calloc.free(pcmPtr);
          }
        case 'shutdown':
          bindings.tacit_whisper_free(ctx);
          final ackPort = msg['reply'];
          if (ackPort is SendPort) {
            ackPort.send({'type': 'shutdown-ok'});
          }
          requests.close();
        default:
          final unknownReply = msg['reply'];
          if (unknownReply is SendPort) {
            unknownReply.send({
              'type': 'error',
              'message': 'cmd tidak dikenal: ${msg['cmd']}',
            });
          }
      }
    } catch (e) {
      final errorReply = msg['reply'];
      if (errorReply is SendPort) {
        errorReply.send({'type': 'error', 'message': '$e'});
      }
    }
  });
}

/// Pesan error native terakhir (thread_local; aman di worker yang sama).
String? _nativeError(TacitWhisperBindings bindings) {
  final ptr = bindings.tacit_whisper_last_error();
  if (ptr == nullptr) return null;
  final utf8Ptr = ptr.cast<Utf8>();
  final bytes = utf8Ptr.cast<Uint8>().asTypedList(utf8Ptr.length);
  return utf8.decode(bytes, allowMalformed: true);
}
