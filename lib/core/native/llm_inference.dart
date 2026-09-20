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
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../utils/model_loader.dart';
import 'tacit_llama_bindings.g.dart';

/// Nama library native yang dihasilkan CMake Android (libtacit_llama.so).
const String _kLibName = 'libtacit_llama.so';

/// Prompt sistem default berbahasa Indonesia untuk asisten teknisi.
const String _kDefaultSystemPrompt =
    'Kamu adalah asisten teknisi maintenance pabrik. Jawab singkat, padat, '
    'dan langsung praktis. Jika menjawab dari SOP atau log mesin, sebutkan '
    'sumbernya. Jangan menebak fakta yang tidak ada di sumber.';

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

  /// Memulai worker isolate + membuka library + init backend + load model.
  /// Aman dipanggil berulang; hanya sekali dieksekusi.
  Future<bool> initialize({String? modelFile}) async {
    if (_worker != null) return _ready;

    final path = await ModelLoader.getModelPath(modelFile ?? defaultModelFile);
    _modelPath = path;
    _modelFileExists = await File(path).exists();
    if (!_modelFileExists) {
      _startupError =
          'Model belum ada: $path\n'
          'Letakkan file .gguf di folder "models" di dokumen aplikasi.';
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
  Stream<String> generateStream(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    String? systemPrompt,
  }) async* {
    if (!_ready || _requests == null) return;

    final reply = ReceivePort();
    _requests!.send({
      'cmd': 'generate_stream',
      'prompt': _buildChatPrompt(systemPrompt ?? _kDefaultSystemPrompt, prompt),
      'maxTokens': maxTokens,
      'temperature': temperature,
      'reply': reply.sendPort,
    });

    try {
      await for (final Object? item in reply) {
        if (item is! Map) continue;
        final type = item['type'];
        if (type == 'piece') {
          final text = item['text'] as String?;
          if (text != null && text.isNotEmpty) yield text;
        } else if (type == 'done' || type == 'error') {
          break;
        }
      }
    } finally {
      reply.close();
    }
  }

  /// Generasi satu jawaban lengkap (non-stream). Null kalau gagal.
  Future<String?> generate(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    String? systemPrompt,
  }) async {
    if (!_ready || _requests == null) return null;

    final reply = ReceivePort();
    _requests!.send({
      'cmd': 'generate',
      'prompt': _buildChatPrompt(systemPrompt ?? _kDefaultSystemPrompt, prompt),
      'maxTokens': maxTokens,
      'temperature': temperature,
      'reply': reply.sendPort,
    });

    try {
      await for (final Object? item in reply) {
        if (item is! Map) continue;
        if (item['type'] == 'result') return item['text'] as String?;
        if (item['type'] == 'error') return null;
      }
    } finally {
      reply.close();
    }
    return null;
  }

  /// Menutup worker: native membebaskan model + backend lalu isolate keluar.
  Future<void> dispose() async {
    _requests?.send({'cmd': 'shutdown'});
    _worker = null;
    _requests = null;
    _control?.close();
    _control = null;
    _ready = false;
    _modelPath = null;
  }

  /// Prompt chat Qwen 3.x: format im_start / im_end.
  String _buildChatPrompt(String system, String user) {
    return '<|im_start|>system\n$system<|im_end|>\n'
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
    bindings = TacitLlamaBindings(DynamicLibrary.open(_kLibName));
  } catch (e) {
    mainPort.send({
      'type': 'init',
      'ok': false,
      'error': 'Gagal membuka $_kLibName: $e',
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

  final requests = ReceivePort();
  mainPort.send({'type': 'init', 'ok': true, 'port': requests.sendPort});

  requests.listen((Object? msg) {
    if (msg is! Map) return;
    switch (msg['cmd']) {
      case 'generate_stream':
        _workerGenerateStream(bindings, model, msg);
      case 'generate':
        _workerGenerate(bindings, model, msg);
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
) {
  final reply = msg['reply'] as SendPort;
  final prompt = msg['prompt'] as String;
  final maxTokens = (msg['maxTokens'] as num?)?.toInt() ?? 512;
  final temperature = ((msg['temperature'] as num?) ?? 0.7).toDouble();

  final promptPtr = prompt.toNativeUtf8();
  NativeCallable<TokenCallbackFunction>? callable;
  try {
    // isolateLocal: callback harus dipanggil dari thread yang sama dengan
    // native call — persis skenario kita (blocking call di isolate ini).
    // Return non-zero dari callback = minta native menghentikan generasi.
    callable = NativeCallable<TokenCallbackFunction>.isolateLocal((
      Pointer<Char> piece,
      Pointer<Void> _,
    ) {
      try {
        reply.send({
          'type': 'piece',
          'text': piece.cast<Utf8>().toDartString(),
        });
        return 0;
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
    callable?.close();
    malloc.free(promptPtr);
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
      final text = out.cast<Utf8>().toDartString();
      bindings.tacit_free_string(out);
      reply.send({'type': 'result', 'text': text});
    }
  } catch (e) {
    reply.send({'type': 'error', 'message': '$e'});
  } finally {
    malloc.free(promptPtr);
  }
}

/// Mengambil pesan error terakhir dari native (thread_local, aman dipanggil
/// dari isolate worker yang sama).
String? _nativeError(TacitLlamaBindings bindings) {
  final ptr = bindings.tacit_last_error();
  if (ptr == nullptr) return null;
  return ptr.cast<Utf8>().toDartString();
}
