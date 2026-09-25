// llama_bridge.dart — bridge Dart ke C-API tacit_llama khusus EMBEDDING.
//
// Kontrak lintas-branch (GABUT-23 pipeline, GABUT-25 viewer) — JANGAN ubah:
//   Future<List<double>> getEmbedding(String text)  // L2-normalized, 384 dim
//
// Desain (KISS, dipilih dari dua opsi):
//   - Model embedding (multilingual-e5-small.gguf) adalah model TERPISAH dari
//     model chat, jadi memakai handle terdedikasi di worker isolate sendiri
//     (pola sama dengan LLMInference, bukan nambah command di sana).
//   - Keamanan konkurensi: tiap request 'embed' diproses berurutan di satu
//     isolate (serialized), dan handle native berbeda dari handle chat →
//     mutex per-handle di tacit_llama.cpp + llama_context terpisah → aman
//     dipanggil sementara LLMInference sedang generate.
//   - Model di-load sekali (lazy) dan dipertahankan sepanjang umur app;
//     upgrade path bila perlu: dispose() + reload on demand.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/model_loader.dart';
import 'llm_inference.dart' show LLMInferenceException, openTacitLlamaLibrary;
import 'tacit_llama_bindings.g.dart';

/// Normalisasi L2 sebuah vektor — hasilnya siap dipakai cosine similarity di
/// SQLite. Guard norm-0 / non-finite: vektor dikembalikan apa adanya (vektor
/// nol tetap nol) supaya tidak pernah ada NaN yang bocor ke index.
///
/// Dipanggil HANYA dari [getEmbedding] tepat sebelum return — inilah satu-satunya
/// jalur keluar, jadi normalisasi tidak bisa terlewat oleh pemanggil.
@visibleForTesting
List<double> l2Normalize(List<double> vector) {
  var sumSquares = 0.0;
  for (final value in vector) {
    sumSquares += value * value;
  }
  final norm = math.sqrt(sumSquares);
  if (!norm.isFinite || norm == 0.0) {
    return List<double>.of(vector); // zero-norm: kembalikan salinan (nol → nol)
  }
  return [for (final value in vector) value / norm];
}

/// Embedding teks UTF-8 via model `multilingual-e5-small.gguf` on-device.
///
/// Returns vektor L2-normalized (siap cosine similarity) dengan dimensi 384.
/// Melempar [StateError] bila model embedding belum ada di device (panggil
/// `ModelManager.ensureEmbeddingModelReady()` / `ensureEmbeddingModel()` dulu),
/// atau [LLMInferenceException] bila native gagal.
///
/// Aman dipanggil bersamaan dengan generate chat (handle & isolate terpisah);
/// request embedding sendiri diproses berurutan (serialized).
Future<List<double>> getEmbedding(String text) async {
  final raw = await _EmbeddingWorker.instance.embed(text);
  return l2Normalize(raw);
}

/// Pekerja isolate terdedikasi untuk embedding model.
class _EmbeddingWorker {
  _EmbeddingWorker._();

  static final _EmbeddingWorker instance = _EmbeddingWorker._();

  Isolate? _isolate;
  SendPort? _requests;
  Completer<SendPort>? _starting;

  /// Spawn worker + load model embedding (sekali, lazy). Pemanggil yang datang
  /// selama init berjalan menunggu future yang sama (serialized, tidak dobel).
  Future<SendPort> _ensureStarted() async {
    final existing = _requests;
    if (existing != null) return existing;
    final pending = _starting;
    if (pending != null) return pending.future;

    final starting = Completer<SendPort>();
    _starting = starting;
    try {
      final path = await ModelManager.findModel(
        ModelManager.embeddingModelName,
      );
      if (path == null) {
        throw StateError(
          'Model embedding ${ModelManager.embeddingModelName} belum ada di '
          'device — jalankan ModelManager.ensureEmbeddingModel() / '
          'ensureEmbeddingModelReady() dulu.',
        );
      }

      final control = ReceivePort();
      _isolate = await Isolate.spawn(_embedWorkerMain, [path, control.sendPort]);

      await for (final Object? item in control) {
        if (item is! Map || item['type'] != 'init') continue;
        if (item['ok'] != true) {
          throw LLMInferenceException(
            item['error'] as String? ?? 'gagal init worker embedding',
          );
        }
        _requests = item['port'] as SendPort;
        break;
      }
      control.close();
      final started = _requests;
      if (started == null) {
        throw LLMInferenceException(
          'worker embedding berhenti sebelum init selesai',
        );
      }
      starting.complete(started);
    } catch (error, stack) {
      await _shutdown();
      starting.completeError(error, stack);
    } finally {
      _starting = null;
    }
    return starting.future;
  }

  Future<List<double>> embed(String text) async {
    final requests = await _ensureStarted();
    final reply = ReceivePort();
    requests.send({'cmd': 'embed', 'text': text, 'reply': reply.sendPort});
    try {
      await for (final Object? item in reply) {
        if (item is! Map) continue;
        if (item['type'] == 'embedding') {
          return (item['vector'] as List).cast<double>();
        }
        if (item['type'] == 'error') {
          throw LLMInferenceException(
            item['message'] as String? ?? 'gagal menghitung embedding',
          );
        }
      }
    } finally {
      reply.close();
    }
    throw LLMInferenceException('worker embedding berhenti tanpa balasan');
  }

  Future<void> _shutdown() async {
    _requests?.send({'cmd': 'shutdown'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _requests = null;
  }
}

// ---------------------------------------------------------------------------
// Worker isolate — memegang binding + handle model embedding sendiri.
// ---------------------------------------------------------------------------

void _embedWorkerMain(List<Object?> args) {
  final modelPath = args[0] as String;
  final SendPort mainPort = args[1] as SendPort;

  TacitLlamaBindings bindings;
  try {
    bindings = TacitLlamaBindings(openTacitLlamaLibrary());
  } catch (e) {
    mainPort.send({
      'type': 'init',
      'ok': false,
      'error': 'Gagal membuka library native: $e',
    });
    return;
  }

  final pathPtr = modelPath.toNativeUtf8();
  final Pointer<tacit_model> model;
  try {
    model = bindings.tacit_init_context(pathPtr.cast<Char>());
  } finally {
    malloc.free(pathPtr);
  }
  if (model == nullptr) {
    mainPort.send({
      'type': 'init',
      'ok': false,
      'error': _nativeError(bindings) ?? 'tacit_init_context gagal',
    });
    bindings.tacit_free_backend();
    return;
  }

  final dim = bindings.tacit_embedding_dim(model);
  if (dim <= 0) {
    mainPort.send({
      'type': 'init',
      'ok': false,
      'error': _nativeError(bindings) ?? 'tacit_embedding_dim tidak valid',
    });
    bindings.tacit_model_free(model);
    bindings.tacit_free_backend();
    return;
  }

  // Buffer output dipakai ulang tiap request (tanpa malloc churn per call).
  final out = calloc<Float>(dim);

  final requests = ReceivePort();
  mainPort.send({'type': 'init', 'ok': true, 'port': requests.sendPort});

  requests.listen((Object? msg) {
    if (msg is! Map) return;
    switch (msg['cmd']) {
      case 'embed':
        final reply = msg['reply'] as SendPort;
        final text = msg['text'] as String;
        final textPtr = text.toNativeUtf8();
        try {
          final rc = bindings.tacit_get_embedding(
            model,
            textPtr.cast<Char>(),
            out,
            dim,
          );
          if (rc <= 0) {
            reply.send({
              'type': 'error',
              'message': _nativeError(bindings) ?? 'tacit_get_embedding rc=$rc',
            });
          } else {
            reply.send({
              'type': 'embedding',
              'vector': out.asTypedList(rc).toList(growable: false),
            });
          }
        } catch (e) {
          reply.send({'type': 'error', 'message': '$e'});
        } finally {
          malloc.free(textPtr);
        }
      case 'shutdown':
        calloc.free(out);
        bindings.tacit_model_free(model);
        bindings.tacit_free_backend();
        requests.close();
    }
  });
}

/// Pesan error native terakhir (thread_local; aman di worker yang sama).
String? _nativeError(TacitLlamaBindings bindings) {
  final ptr = bindings.tacit_last_error();
  if (ptr == nullptr) return null;
  // Toleran byte malformed (→ U+FFFD) seperti _utf8String di llm_inference.
  final utf8Ptr = ptr.cast<Utf8>();
  final bytes = utf8Ptr.cast<Uint8>().asTypedList(utf8Ptr.length);
  return utf8.decode(bytes, allowMalformed: true);
}
