// LLMInference — bridge Dart ke C-API tacit_llama (llama.cpp) via FFI.
//
// Arsitektur:
//   - Native inference dijalankan di worker isolate agar UI tidak terblokir
//     selama generasi (tacit_generate_stream bersifat blocking & sinkron).
//   - Token streaming dikirim native -> Dart via NativeCallable.isolateLocal
//     (dipanggil sinkron dari thread yang sama dengan native call), lalu
//     diteruskan ke isolate utama lewat SendPort.
//   - Backend + model di-load sekali saat initialize(); kalau file .gguf
//     belum ada, initialize() return false dan caller boleh pakai fallback.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show log;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../utils/gguf_validator.dart';
import '../utils/model_loader.dart';
import '../utils/thinking_utils.dart' show stripSpecialTokens;
import 'tacit_llama_bindings.g.dart';

/// Cross-platform DynamicLibrary loader untuk tacit_llama native library.
///
/// Di Linux: coba SONAME selama proses (ternavigasi via RPATH bundel) dulu;
/// kalau gagal, jatuh ke pencarian relatif-executable — `lib/` bundel dan
/// direktori yang sama dengan binary — agar `flutter run -d linux` maupun
/// instalasi manual tetap menemukan `libtacit_llama.so`.
DynamicLibrary openTacitLlamaLibrary() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libtacit_llama.so');
  } else if (Platform.isLinux) {
    try {
      return DynamicLibrary.open('libtacit_llama.so');
    } catch (_) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final bundleLib = p.join(exeDir, 'lib', 'libtacit_llama.so');
      if (File(bundleLib).existsSync()) {
        return DynamicLibrary.open(bundleLib);
      }
      final sameDirLib = p.join(exeDir, 'libtacit_llama.so');
      if (File(sameDirLib).existsSync()) {
        return DynamicLibrary.open(sameDirLib);
      }
      rethrow;
    }
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('tacit_llama.dll');
  } else if (Platform.isIOS || Platform.isMacOS) {
    return DynamicLibrary.process();
  }
  throw UnsupportedError('Platform ${Platform.operatingSystem} is not supported.');
}

/// Prompt sistem default berbahasa Indonesia untuk asisten teknisi.
const String _kDefaultSystemPrompt =
    'Kamu adalah asisten teknisi maintenance pabrik. Jawab singkat, padat, '
    'dan langsung praktis. Jika menjawab dari SOP atau log mesin, sebutkan '
    'sumbernya. Jangan menebak fakta yang tidak ada di sumber.';

/// Stop-sequence bawaan (token kontrol Qwen/llama.cpp) yang menghentikan
/// generasi dan disanitasi dari output TACIT TADIR.
///
/// Dipakai dua lapis: worker native mendeteksi token ini pada aliran piece
/// (callback mengembalikan nonzero -> native berhenti bersih, rc kembali 0),
/// dan lapisan Dart memotong/membuang sisa token yang lolos dari teks.
const List<String> kDefaultStopTokens = [
  '<|im_end|>',
  '<|im_start|>',
  '<|im_end_of_text|>',
  '<|endoftext|>',
  '</s>',
];

/// Awalan stop-sequence ChatML yang dibolehkan belum tertutup `>` (token
/// parsial). Dipakai supaya generasi/deteksi berhenti begitu token kontrol
/// MULAI muncul (`<|im_end`, `<|im_start`, `<|im_end_of_text`, `<|endoftext`),
/// bukan menunggu versi utuh yang bisa terpotong di ujung aliran.
const List<String> kStopTokenPrefixes = [
  '<|im_end',
  '<|im_start',
  '<|im_end_of_text',
  '<|endoftext',
];

/// Daftar stop-sequence efektif: versi utuh [kDefaultStopTokens] digabung
/// dengan awalan parsial [kStopTokenPrefixes] (unik).
List<String> effectiveStopTokens([List<String> stops = kDefaultStopTokens]) {
  return List<String>.unmodifiable({...stops, ...kStopTokenPrefixes});
}

/// Panjang token terpanjang di [effectiveStopTokens] (`<|endoftext|>` = 13).
/// Dipakai sebagai ukuran buffer "tail" agar stop-sequence yang terpotong di
/// antara dua piece generasi tetap terdeteksi saat piece berikutnya tiba.
const int kMaxStopTokenLen = 13;

/// Index kemunculan pertama dari stop-sequence mana pun dalam [text],
/// atau `-1` apabila tidak ada.
int firstStopTokenIndex(String text, List<String> stops) {
  final maxLen = text.length;
  if (maxLen == 0) return -1;
  for (var i = 0; i < maxLen; i++) {
    for (final s in stops) {
      if (i + s.length <= maxLen && text.startsWith(s, i)) return i;
    }
  }
  return -1;
}

/// Memotong [text] tepat sebelum stop-sequence/awalan parsial pertama
/// (bila ditemukan) — termasuk token parsial seperti `<|im_end`.
String truncateAtStopTokens(
  String text, {
  List<String> stops = kDefaultStopTokens,
}) {
  final i = firstStopTokenIndex(text, effectiveStopTokens(stops));
  return i < 0 ? text : text.substring(0, i);
}

/// Error generasi yang membawa pesan diagnostik dari native.
class LLMInferenceException implements Exception {
  LLMInferenceException(this.message);

  final String message;

  @override
  String toString() => 'LLMInferenceException: $message';
}

class LLMInference {
  LLMInference._();

  /// Singleton yang dipakai app.
  static final LLMInference instance = LLMInference._();

  /// Nama default model GGUF (Qwen 3.5-0.8B Q4_K_M) di folder models
  /// dalam dokumen aplikasi.
  static const String defaultModelFile = 'qwen3.5-0.8b-q4_k_m.gguf';

  Isolate? _worker;
  SendPort? _requests;
  ReceivePort? _control;
  bool _ready = false;
  String? _startupError;
  String? _modelPath;
  bool _modelFileExists = false;

  /// True kalau backend native sudah siap dan model sudah ter-load.
  bool get isReady => _ready;

  /// True kalau file .gguf benar-benar ada di disk.
  bool get isModelOnDisk => _modelFileExists;

  /// Pesan error saat startup, atau null.
  String? get startupError => _startupError;

  /// Jalur lengkap model yang dipakai.
  String? get modelPath => _modelPath;

  /// Menghentikan generasi yang sedang berjalan.
  void stopGeneration() {
    if (_requests != null) {
      _requests!.send({'cmd': 'abort'});
    }
  }

  /// Reset KV cache (clear context) untuk memulai percakapan baru.
  Future<void> resetContext() async {
    if (!_ready || _requests == null) return;
    final reply = ReceivePort();
    _requests!.send({'cmd': 'reset', 'reply': reply.sendPort});
    await reply.first;
    reply.close();
  }

  /// Memulai worker isolate + membuka library + init backend + load model.
  /// Aman dipanggil berulang; hanya sekali dieksekusi bila _worker sudah ada.
  ///
  /// Tidak pernah melempar saat model belum ada: resolusi path berlapis tidak
  /// menemukan model → return `false`, dan caller bisa menampilkan model
  /// picker / downloader sheet (bukan crash / error resolusi model).
  Future<bool> initialize({String? modelFile}) async {
    if (_worker != null) return _ready;

    final path =
        await ModelManager.resolveModelPath(modelFile ?? defaultModelFile);
    if (path == null) {
      _startupError =
          'Model (${modelFile ?? defaultModelFile}) belum tersedia di device. '
          'Pilih file .gguf (${GgufValidator.targetModelLabel}) dari penyimpanan '
          'atau sinkronkan via mesh.';
      return false;
    }

    _modelPath = path;
    _modelFileExists = await File(path).exists();
    if (!_modelFileExists) {
      _startupError = 'Model belum ada: $path';
      return false;
    }

    final done = Completer<bool>();
    _control = ReceivePort();
    try {
      _worker = await Isolate.spawn(_workerMain, [path, _control!.sendPort]);
    } catch (e) {
      _startupError = 'Gagal spawn worker isolate: $e';
      _control!.close();
      _control = null;
      return false;
    }

    _control!.listen((item) {
      if (item is! Map || item['type'] != 'init') return;
      _ready = item['ok'] == true;
      _requests = item['port'] as SendPort?;
      _startupError = item['error'] as String?;
      _control!.close();
      _control = null;
      if (!done.isCompleted) done.complete(_ready);
    });

    return done.future;
  }

  /// Generasi streaming. Yield satu `string` per token piece.
  ///
  /// Prompt otomatis dibungkus template chat Qwen. Kalau [isReady] false
  /// (model belum siap) stream langsung selesai — caller boleh memakai mock
  /// sebagai fallback.
  ///
  /// [contextDocs]: blok referensi RAG (hasil [IntentRouter]) yang diinjeksikan
  /// ke prompt sistem; kosong bila tidak ada context.
  Stream<String> generateStream(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    String? systemPrompt,
    String? contextDocs = '',
  }) async* {
    if (!_ready || _requests == null) return;

    final reply = ReceivePort();
    _requests!.send({
      'cmd': 'generate_stream',
      'prompt': _buildChatPrompt(
        systemPrompt ?? _kDefaultSystemPrompt,
        prompt,
        contextDocs: contextDocs,
      ),
      'maxTokens': maxTokens,
      'temperature': temperature,
      'stops': kDefaultStopTokens,
      'reply': reply.sendPort,
    });

    try {
      await for (final Object? item in reply) {
        if (item is! Map) continue;
        final type = item['type'];
        if (type == 'piece') {
          final text = item['text'] as String?;
          if (text == null) continue;
          // Jaring pengaman kedua: buang special token yang masih tersisa
          // (tanpa trim — menghilangkan spasi per-piece merusak penggabungan
          // kalimat di ChatCubit).
          final cleaned = stripSpecialTokens(text);
          if (cleaned.isNotEmpty) yield cleaned;
        } else if (type == 'done') {
          break;
        } else if (type == 'error') {
          final message =
              item['message'] as String? ?? 'gagal generasi (tanpa pesan)';
          log('[LLMInference] generateStream error: $message');
          // Dilontarkan sebagai stream error supaya caller (ChatCubit)
          // bisa menangkapnya via onError — pesan tidak lagi dibuang diam-diam.
          throw LLMInferenceException(message);
        }
      }
    } finally {
      reply.close();
    }
  }

  /// Generasi satu jawaban lengkap (non-stream).
  ///
  /// Returns null HANYA kalau model belum siap / worker belum ada (sama
  /// seperti generateStream yang tidak meng-emit apa-apa). Kalau native
  /// gagal di tengah jalan, melempar [LLMInferenceException] — konsisten
  /// dengan [generateStream].
  Future<String?> generate(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    String? systemPrompt,
    String? contextDocs = '',
  }) async {
    if (!_ready || _requests == null) return null;

    final reply = ReceivePort();
    _requests!.send({
      'cmd': 'generate',
      'prompt': _buildChatPrompt(
        systemPrompt ?? _kDefaultSystemPrompt,
        prompt,
        contextDocs: contextDocs,
      ),
      'maxTokens': maxTokens,
      'temperature': temperature,
      'stops': kDefaultStopTokens,
      'reply': reply.sendPort,
    });

    try {
      await for (final Object? item in reply) {
        if (item is! Map) continue;
        if (item['type'] == 'result') return item['text'] as String?;
        if (item['type'] == 'error') {
          final message =
              item['message'] as String? ?? 'gagal generasi (tanpa pesan)';
          log('[LLMInference] generate error: $message');
          throw LLMInferenceException(message);
        }
      }
    } finally {
      reply.close();
    }
    // Worker berhenti membalas tanpa result/error.
    throw LLMInferenceException(
      'generate selesai tanpa result atau error dari worker',
    );
  }

  /// Menutup worker: native membebaskan model + backend lalu isolate keluar.
  Future<void> dispose() async {
  if (_worker != null) {
    _requests?.send({'cmd': 'shutdown'});
    // Berikan jeda untuk gracefully shutdown native C++ memory
    await Future.delayed(const Duration(milliseconds: 100));
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
  }
  _requests = null;
  _control?.close();
  _control = null;
  _ready = false;
}

  /// Prompt chat Qwen 3.x: format im_start / im_end.
  /// [contextDocs] (hasil routing RAG) disisipkan sebagai blok referensi
  /// di prompt sistem — kosong bila tidak ada context.
  String _buildChatPrompt(String system, String user, {String? contextDocs}) {
    final context = contextDocs == null || contextDocs.isEmpty
        ? ''
        : '\n\nReferensi dokumen (gunakan bila relevan):\n$contextDocs';
    return '<|im_start|>system\n$system$context<|im_end|>\n'
        '<|im_start|>user\n$user<|im_end|>\n'
        '<|im_start|>assistant\n';
  }
}

// ---------------------------------------------------------------------------
// Worker isolate — berjalan di thread terpisah, memegang binding + model.
// ---------------------------------------------------------------------------

void _workerMain(List<Object?> args) {
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

  // tacit_init_context = backend + load model + create context, satu call native.
  final Pointer<tacit_model> model = _loadModel(bindings, modelPath);
  if (model == nullptr) {
    final error = _nativeError(bindings) ?? 'tacit_init_context gagal';
    bindings.tacit_free_backend();
    mainPort.send({'type': 'init', 'ok': false, 'error': error});
    return;
  }

  bool isAborted = false;

  final requests = ReceivePort();
  mainPort.send({'type': 'init', 'ok': true, 'port': requests.sendPort});

  requests.listen((Object? msg) {
    if (msg is! Map) return;
    switch (msg['cmd']) {
      case 'generate_stream':
        isAborted = false;
        _workerGenerateStream(bindings, model, msg, () => isAborted);
      case 'generate':
        isAborted = false;
        _workerGenerate(bindings, model, msg);
      case 'abort':
        isAborted = true;
      case 'reset':
        final reply = msg['reply'] as SendPort?;
        bindings.tacit_reset(model);
        reply?.send({'type': 'reset_done'});
      case 'shutdown':
        bindings.tacit_model_free(model);
        bindings.tacit_free_backend();
        requests.close();
    }
  });
}

Pointer<tacit_model> _loadModel(TacitLlamaBindings bindings, String path) {
  final pathPtr = path.toNativeUtf8();
  try {
    return bindings.tacit_init_context(pathPtr.cast<Char>());
  } finally {
    malloc.free(pathPtr);
  }
}

void _workerGenerateStream(
  TacitLlamaBindings bindings,
  Pointer<tacit_model> model,
  Map<Object?, Object?> msg,
  bool Function() isAborted,
) {
  final reply = msg['reply'] as SendPort;
  final prompt = msg['prompt'] as String;
  final maxTokens = (msg['maxTokens'] as num?)?.toInt() ?? 512;
  final temperature = ((msg['temperature'] as num?) ?? 0.7).toDouble();
  final stops = effectiveStopTokens(
    (msg['stops'] as List?)?.cast<String>() ?? kDefaultStopTokens,
  );

  final promptPtr = prompt.toNativeUtf8();
  NativeCallable<TokenCallbackFunction>? callable;

  // Buffer ujung-ujung terakhir aliran agar stop-sequence yang terpotong di
  // antara dua piece (token generasi terbagi) tetap terdeteksi dari sini.
  String stopTail = '';
  final int keepTailLen = kMaxStopTokenLen - 1;

  try {
    // Tugaskan ke variabel 'callable' di luar (tanpa kata kunci 'final')
    callable = NativeCallable<TokenCallbackFunction>.isolateLocal((
      Pointer<Char> piece,
      Pointer<Void> _,
    ) {
      if (isAborted()) {
        return 1; // Signal native to stop generation
      }
      try {
        final pieceText = _utf8String(piece);
        if (pieceText.isEmpty) return 0;

        // Deteksi stop-sequence pada tail terakhir + piece saat ini.
        final candidate = stopTail + pieceText;
        final hitIndex = firstStopTokenIndex(candidate, stops);
        if (hitIndex < 0) {
          reply.send({
            'type': 'piece',
            'text': stripSpecialTokens(pieceText),
          });
          stopTail = candidate.length > keepTailLen
              ? candidate.substring(candidate.length - keepTailLen)
              : candidate;
          return 0;
        }

        // Stop-sequence tertangkap: kirim string sebelum token (bila ada),
        // lalu abort native -> generate_int berhenti bersih (rc kembali 0).
        final cutInPiece = hitIndex - stopTail.length;
        if (cutInPiece > 0) {
          final prefix = stripSpecialTokens(
            pieceText.substring(0, cutInPiece),
          );
          if (prefix.isNotEmpty) {
            reply.send({'type': 'piece', 'text': prefix});
          }
        }
        return 1;
      } catch (_) {
        return 1; // gagal kirim ke Dart -> abort
      }
    }, exceptionalReturn: 1);

    final rc = bindings.tacit_generate_stream(
      model,
      promptPtr.cast<Char>(),
      maxTokens,
      temperature,
      callable.nativeFunction,
      nullptr,
    );

    if (rc != 0) {
      reply.send({
        'type': 'error',
        'message': _nativeError(bindings) ?? 'tacit_generate_stream rc=$rc',
      });
    } else {
      reply.send({'type': 'done'});
    }
  } catch (e) {
    reply.send({'type': 'error', 'message': '$e'});
  } finally {
    // Ditutup HANYA SETELAH fungsi native C++ tacit_generate_stream selesai mengeksekusi seluruh loop
    callable?.close();
    malloc.free(promptPtr);
    // KV cache tidak dipertahankan antar turn: setiap generasi mem-prompt
    // ulang riwayat penuh, jadi cache yang lama hanya menahan RAM + posisi
    // basi. Kosongkan (data wipe) begitu generasi selesai.
    bindings.tacit_reset(model);
  }
}

void _workerGenerate(
  TacitLlamaBindings bindings,
  Pointer<tacit_model> model,
  Map<Object?, Object?> msg,
) {
  final reply = msg['reply'] as SendPort;
  final prompt = msg['prompt'] as String;
  final maxTokens = (msg['maxTokens'] as num?)?.toInt() ?? 512;
  final temperature = ((msg['temperature'] as num?) ?? 0.7).toDouble();
  final stops = effectiveStopTokens(
    (msg['stops'] as List?)?.cast<String>() ?? kDefaultStopTokens,
  );

  final promptPtr = prompt.toNativeUtf8();
  try {
    final out = bindings.tacit_generate(
      model,
      promptPtr.cast<Char>(),
      maxTokens,
      temperature,
    );
    if (out == nullptr) {
      reply.send({
        'type': 'error',
        'message': _nativeError(bindings) ?? 'tacit_generate gagal',
      });
    } else {
      final raw = _utf8String(out);
      bindings.tacit_free_string(out);
      // Potong di stop-sequence pertama lalu buang special token yang tersisa.
      final text = stripSpecialTokens(truncateAtStopTokens(raw, stops: stops));
      reply.send({'type': 'result', 'text': text});
    }
  } catch (e) {
    reply.send({'type': 'error', 'message': '$e'});
  } finally {
    malloc.free(promptPtr);
    // Sama seperti generate_stream: kosongkan KV cache setelah sekali jalan
    // supaya idle tidak menahan memori cache yang tidak terpakai.
    bindings.tacit_reset(model);
  }
}

/// Mengambil pesan error terakhir dari native (thread_local, aman dipanggil
/// dari isolate worker yang sama).
String? _nativeError(TacitLlamaBindings bindings) {
  final ptr = bindings.tacit_last_error();
  if (ptr == nullptr) return null;
  return _utf8String(ptr);
}

/// Decode string UTF-8 null-terminated dari native dengan toleransi malformed
/// byte (menjadi U+FFFD, tidak melempar). Native dijamin UTF-8 oleh llama.cpp
/// (llama_token_to_piece) — ini jaring pengaman kalau versi/konfigurasi
/// berubah; toDartString() bawaan ffi malah melempar FormatException.
String _utf8String(Pointer<Char> ptr) {
  if (ptr == nullptr) return '';
  // utf8Ptr.length sudah melakukan null-terminator scan (package:ffi
  // meng-loop while (bytes[i] != 0)) — batas baca selalu akurat, jadi
  // tidak perlu scan manual. Guard di atas hanya membuat helper ini aman
  // dipanggil sendirian (length melempar StateError kalau pointer null).
  final utf8Ptr = ptr.cast<Utf8>();
  final bytes = utf8Ptr.cast<Uint8>().asTypedList(utf8Ptr.length);
  return utf8.decode(bytes, allowMalformed: true);
}
