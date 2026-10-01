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
import 'dart:developer' show log;
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
/// Melempar [ArgumentError] bila `text` kosong / whitespace-only (fast-fail
/// sebelum dispatch ke worker),
/// [StateError] bila model embedding belum ada di device (panggil
/// `ModelManager.ensureEmbeddingModelReady()` / `ensureEmbeddingModel()` dulu),
/// atau [LLMInferenceException] bila native gagal / worker tidak merespons.
///
/// Aman dipanggil bersamaan dengan generate chat (handle & isolate terpisah);
/// request embedding sendiri diproses berurutan (serialized).
Future<List<double>> getEmbedding(String text) async {
  if (text.trim().isEmpty) {
    throw ArgumentError.value(text, 'text', 'teks kosong');
  }
  final raw = await _EmbeddingWorker.instance.embed(text);
  return l2Normalize(raw);
}

/// Atur timeout worker embedding untuk tes (parameter `null` = biarkan).
/// Jembatan test-only: kelas `_EmbeddingWorker` privat, jadi field timeout-nya
/// tidak bisa dijangkau langsung dari luar library ini.
@visibleForTesting
void setEmbeddingTimeouts({Duration? init, Duration? request}) {
  final worker = _EmbeddingWorker.instance;
  if (init != null) worker.initTimeout = init;
  if (request != null) worker.requestTimeout = request;
}

/// Entry point worker isolate yang sedang ditimpa untuk tes; `null` = pakai
/// [_embedWorkerMain] yang asli. Production tidak pernah mengubahnya.
void Function(List<Object?> args)? _workerMainOverride;

/// Jembatan test-only: ganti entry point worker isolate dengan fake.
///
/// Ini satu-satunya cara menguji lifecycle worker tanpa `libtacit_llama.so` +
/// model GGUF asli: `init` hanya sukses kalau native backend benar-benar bisa
/// dibuka dan model ter-load, sedangkan bug yang diuji justru terjadi
/// SETELAH `init` sukses. Production selalu `null` — panggil dengan `null` lagi
/// di tearDown.
@visibleForTesting
void setEmbeddingWorkerMainForTest(void Function(List<Object?> args)? main) {
  _workerMainOverride = main;
}

/// Matikan worker embedding yang masih hidup lalu kembalikan state worker ke
/// kosong, supaya test berikutnya mulai bersih.
///
/// Jembatan test-only: [_EmbeddingWorker] adalah singleton tanpa `dispose()`
/// publik, jadi test yang menyuntikkan worker palsu akan mencemari test lain
/// di file yang sama — worker palsu yang masih hidup akan dipakai panggilan
/// `getEmbedding` berikutnya dan test yang mengharapkan kegagalan jadi lolos.
@visibleForTesting
Future<void> resetEmbeddingWorkerForTest() =>
    _EmbeddingWorker.instance.shutdownForTest();

/// Timeout menunggu ack `shutdown-ok` pada handshake shutdown worker.
///
/// Untuk satu embedding BERT 512 token di perangkat mobile kelas bawah bisa
/// butuh 2–4 detik di async native. Batas 2 detik terlalu rapat sehingga
/// shutdown sering mendarat di `TimeoutException` lalu langsung
/// `Isolate.kill(priority: Isolate.immediate)` pada worker yang justru sedang
/// menyelesaikan pekerjaan — free model/backend native terputus di tengah jalan.
/// 5 detik memberi buffer yang cukup tanpa menahan app terlalu lama.
const Duration _kShutdownAckTimeout = Duration(seconds: 5);

/// Pekerja isolate terdedikasi untuk embedding model.
class _EmbeddingWorker {
  _EmbeddingWorker._();

  static final _EmbeddingWorker instance = _EmbeddingWorker._();

  Isolate? _isolate;
  SendPort? _requests;
  Completer<SendPort>? _starting;

  /// Kanal [ReceivePort] yang menempel ke isolate worker selama SELURUH umur
  /// hidup worker — bukan hanya selama handshake `init`.
  ///
  /// Port ini menerima dua jenis traffic yang dibedakan tipenya:
  ///   1. balasan `init` dari `mainPort` worker (`Map` dengan `type == 'init'`),
  ///      hanya selama [_ensureStarted] masih berjalan;
  ///   2. event isolate yang didaftarkan lewat `Isolate.addOnExitListener` /
  ///      `addErrorListener` — `null` untuk exit, `[error, stack]` (List) untuk
  ///      crash.
  ///
  /// Kenapa port ini tidak ditutup begitu `init` selesai (bug yang diperbaiki):
  /// begitu ditutup, isolate yang mati belakangan — OOM native atau unhandled
  /// exception saat `embed` — melapor ke port yang sudah tutup lalu dibuang
  /// diam-diam. Akibatnya [_requests] & [_isolate] tetap non-null padahal worker
  /// sudah tidak ada, sehingga panggilan `embed()` berikutnya memakai
  /// `SendPort` mati dan menggantung sampai [requestTimeout] (30 detik).
  /// Selama port ini bertahan, kematian worker selalu terlihat dan state
  /// selalu di-reset.
  ReceivePort? _lifecyclePort;

  /// Isolate yang sedang diawasi [_lifecyclePort]. Dipakai sebagai token
  /// identity supaya event dari worker lama tidak mengosongkan state worker
  /// baru yang sudah di-spawn (mis. respawn setelah crash atau shutdown).
  Isolate? _watchedIsolate;

  /// Daftarkan listener exit/error isolate ke [port] yang bertahan seumur
  /// worker. Satu isolate hanya boleh punya SATU error listener dan SATU exit
  /// listener (pendaftaran baru menggantikan yang lama), jadi keduanya sengaja
  /// diarahkan ke port yang sama dan port itu tidak pernah diganti port lain
  /// selama worker hidup.
  void _attachLifecycle(Isolate isolate, ReceivePort port) {
    _detachLifecycle();
    _lifecyclePort = port;
    _watchedIsolate = isolate;
    isolate.addErrorListener(port.sendPort);
    isolate.addOnExitListener(port.sendPort);
  }

  /// Lepas port pemantau + token identity (aman dipanggil berulang, juga dari
  /// dalam handler port itu sendiri).
  void _detachLifecycle() {
    _lifecyclePort?.close();
    _lifecyclePort = null;
    _watchedIsolate = null;
  }

  /// Port balasan request `embed` yang masih menunggu jawaban worker.
  ///
  /// Semua port di sini milik isolate yang baru saja mati, jadi tanpa pemberi
  /// tahu, `embed()` yang sedang berjalan menggantung penuh [requestTimeout]
  /// (30 detik). Saat worker mati, death handler mengirim error ke
  /// masing-masing port supaya caller gagal cepat alih-alih menunggu timeout.
  final Set<SendPort> _inflight = <SendPort>{};

  /// Batalkan semua request `embed` yang masih menggantung karena worker mati.
  void _failInflight(String reason) {
    if (_inflight.isEmpty) return;
    final orphans = List<SendPort>.of(_inflight);
    _inflight.clear();
    for (final orphan in orphans) {
      // Port yang sudah ditutup (request yang baru saja selesai) diam-diam
      // menjadi no-op di `SendPort.send`.
      orphan.send({
        'type': 'error',
        'message': 'worker embedding $reason saat request sedang berjalan',
      });
    }
  }

  /// Timeout tunggu pesan `init` (load GGUF ~126 MB dilakukan sinkron di
  /// worker) — sengaja longgar; bisa dipendekkan via [setEmbeddingTimeouts].
  @visibleForTesting
  Duration initTimeout = const Duration(seconds: 60);

  /// Timeout tunggu balasan per-request `embed` di [embed].
  @visibleForTesting
  Duration requestTimeout = const Duration(seconds: 30);

  /// [resetEmbeddingWorkerForTest] saja yang memanggil ini — cukup [_shutdown]
  /// karena dipanggil setelah test selesai, bukan di tengah init.
  Future<void> shutdownForTest() => _shutdown();

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

      // Satu port untuk kanal `init` sekaligus pemantau exit/error worker.
      // Sengaja TIDAK di-close di akhir init — itu inti fix lifecycle di sini.
      final port = ReceivePort();
      final initDone = Completer<void>();
      // Hasil handshake dititipkan di closure, bukan lewat `completeError`:
      // pesan init yang telat tiba setelah [initTimeout] sudah tidak ada yang
      // menunggu, dan `completeError` di sana akan jadi unhandled async error.
      SendPort? startedPort;
      String? initError;
      String? deathReason;

      final isolate = await Isolate.spawn(
        _workerMainOverride ?? _embedWorkerMain,
        [path, port.sendPort],
      );
      _isolate = isolate;
      _attachLifecycle(isolate, port);

      port.listen((Object? event) {
        if (event is Map && event['type'] == 'init') {
          if (event['ok'] == true) {
            startedPort = event['port'] as SendPort?;
          } else {
            initError =
                event['error'] as String? ?? 'gagal init worker embedding';
          }
          if (!initDone.isCompleted) initDone.complete();
          return;
        }
        // Di luar handshake init: `null` = exit-listener, `List` =
        // error-listener. Dua-duanya berarti worker tidak akan pernah sadar
        // kembali dan setiap `SendPort` miliknya sudah tidak berlaku.
        deathReason = event is List
            ? (event.isEmpty ? 'crash tanpa pesan' : 'crash (${event.first})')
            : 'berhenti';
        if (!initDone.isCompleted) initDone.complete();
        // Reset state hanya kalau isolate yang mengirim event ini masih worker
        // yang aktif; kalau sudah digantikan, event basi ini tidak boleh
        // menumpang mengosongkan state worker baru.
        if (identical(_watchedIsolate, isolate)) {
          _detachLifecycle();
          _requests = null;
          _isolate = null;
          _failInflight(deathReason!);
          log('[llama_bridge] worker embedding $deathReason — state direset');
        }
      });

      try {
        await initDone.future.timeout(initTimeout);
      } on TimeoutException {
        throw LLMInferenceException(
          'init worker embedding tidak merespons dalam '
          '${initTimeout.inSeconds} detik',
        );
      }

      // Urutan penting. Pesan init (ok:false) diperiksa lebih dulu: worker
      // yang gagal lalu `return` akan mengirim pesan itu DAN memicu exit, dan
      // pesan pertama itulah yang menjelaskan sebab aslinya — exit hanya
      // memberi tahu worker berhenti tanpa konteks. Kalau worker mati tanpa
      // pesan init (OOM/segfault saat load model), `initError` null dan
      // `deathReason` yang dipakai — termasuk kasus init-ok yang telat
      // diterima lalu worker mati, yang tetap ditolak karena port-nya sudah
      // tidak berlaku.
      final failure = initError;
      if (failure != null) {
        throw LLMInferenceException(failure);
      }
      final death = deathReason;
      if (death != null) {
        throw LLMInferenceException(
          'worker embedding $death sebelum init selesai',
        );
      }
      final started = startedPort;
      if (started == null) {
        throw LLMInferenceException(
          'worker embedding berhenti sebelum init selesai',
        );
      }
      // Ada race kecil: worker bisa mati di antara balasan `init` dan baris
      // ini, sehingga `SendPort` di atas sudah tidak berlaku. Identity guard
      // menutupnya — tanpa ini state mati akan dipasang ulang oleh `_requests`.
      if (!identical(_watchedIsolate, isolate)) {
        throw LLMInferenceException(
          'worker embedding berhenti sebelum init selesai',
        );
      }
      _requests = started;
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
    // Daftar SEBELUM kirim: kalau worker mati sesaat setelah ini, death
    // handler tetap harus menemukan port ini supaya tidak ada yang hang.
    _inflight.add(reply.sendPort);
    requests.send({'cmd': 'embed', 'text': text, 'reply': reply.sendPort});
    try {
      await for (final Object? item in reply.timeout(requestTimeout)) {
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
    } on TimeoutException {
      throw LLMInferenceException(
        'worker embedding tidak merespons dalam '
        '${requestTimeout.inSeconds} detik',
      );
    } finally {
      _inflight.remove(reply.sendPort);
      reply.close();
    }
    throw LLMInferenceException('worker embedding berhenti tanpa balasan');
  }

  /// Shutdown handshake: minta worker berhenti, tunggu ack (worker yang stuck
  /// di blocking native init tak pernah bisa ack → jatuh ke kill), lalu kill
  /// isolate sebagai fallback yang selalu aman.
  Future<void> _shutdown() async {
    final requests = _requests;
    final isolate = _isolate;
    _requests = null;
    _isolate = null;
    // Tutup port pemantau di sini, bukan hanya di handler exit: jalur shutdown
    // eksplisit mematikan isolate tanpa pernah menerima event exit-nya (port
    // justru ditutup sebelum kill), jadi tanpa baris ini port akan menggantung
    // sampai isolate mati. Di-detach sebelum handshake agar pesan shutdown dan
    // event exit tidak saling berebut handler.
    _detachLifecycle();
    if (requests != null) {
      final ack = ReceivePort();
      try {
        requests.send({'cmd': 'shutdown', 'reply': ack.sendPort});
        // Buffer [_kShutdownAckTimeout] (5 detik), bukan 2: worker bisa sedang
        // menyelesaikan embedding native yang butuh 2–4 detik di perangkat
        // lambat, dan kill di tengah pekerjaan merusak free model/backend.
        await for (final Object? item in ack.timeout(_kShutdownAckTimeout)) {
          if (item is Map && item['type'] == 'shutdown-ok') break;
        }
      } on TimeoutException {
        // tak ada ack → lanjut ke kill di bawah (fallback disengaja).
      } finally {
        ack.close();
      }
    }
    isolate?.kill(priority: Isolate.immediate);
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

  try {
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
      try {
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
              if (rc != dim) {
                reply.send({
                  'type': 'error',
                  'message': _nativeError(bindings) ??
                      'tacit_get_embedding rc=$rc (dim=$dim)',
                });
              } else {
                reply.send({
                  'type': 'embedding',
                  'vector': out.asTypedList(dim).toList(growable: false),
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
            final ackPort = msg['reply'];
            if (ackPort is SendPort) {
              ackPort.send({'type': 'shutdown-ok'});
            }
            requests.close();
          default:
            // Cmd tak dikenal: balas error bila ada port reply, abaikan bila tidak.
            final unknownReply = msg['reply'];
            if (unknownReply is SendPort) {
              unknownReply.send({
                'type': 'error',
                'message': 'cmd tidak dikenal: ${msg['cmd']}',
              });
            }
        }
      } catch (e) {
        // Jangan biarkan exception lolos: isolate mati = main-side hang.
        final errorReply = msg['reply'];
        if (errorReply is SendPort) {
          errorReply.send({'type': 'error', 'message': '$e'});
        }
      }
    });
  } catch (e) {
    // Setup worker gagal setelah model ter-load → laporkan init gagal (best effort).
    mainPort.send({'type': 'init', 'ok': false, 'error': '$e'});
  }
}

/// Pesan error native terakhir (thread_local; aman di worker yang sama).
///
/// Bergantung pada NUL-termination buffer: `Utf8.length` memindai sampai byte
/// `'\0'` — native menjaminnya lewat penulisan via `snprintf` (selalu
/// NUL-terminated). Kekurangan: buffer native tidak pernah di-clear pada path
/// sukses, jadi pesan basi (stale) bisa terbaca bila sebuah path error
/// tercapai tanpa `set_error` menulis ulang buffer.
String? _nativeError(TacitLlamaBindings bindings) {
  final ptr = bindings.tacit_last_error();
  if (ptr == nullptr) return null;
  // Toleran byte malformed (→ U+FFFD) seperti _utf8String di llm_inference.
  final utf8Ptr = ptr.cast<Utf8>();
  final bytes = utf8Ptr.cast<Uint8>().asTypedList(utf8Ptr.length);
  return utf8.decode(bytes, allowMalformed: true);
}
