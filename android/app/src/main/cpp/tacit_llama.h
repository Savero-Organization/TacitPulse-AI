// tacit_llama.h
// Simple C-API bridge over llama.cpp for Dart FFI.

// Recommended (one-shot) Dart flow via package:ffi:
//   final lib = DynamicLibrary.open('libtacit_llama.so');
//   final model = tacit_init_context(ggufPath);  // backend + model + context
//   final text  = tacit_generate(model, prompt, 512, 0.8f);
//   tacit_free_string(text);
//   tacit_model_free(model);
//   tacit_free_backend();
//
// tacit_init_backend() / tacit_model_load() are kept public as the split,
// low-level sequence (advanced/manual init, e.g. several models sharing one
// backend init). The Dart worker currently calls tacit_init_context()
// exclusively, so those two functions are intentionally unused from Dart.

#ifndef TACIT_LLAMA_H
#define TACIT_LLAMA_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a loaded model plus its inference context.
typedef struct tacit_model tacit_model;

/// Initializes the llama.cpp backend. Idempotent: the mutex-guarded
/// once-per-process flag makes repeat calls a no-op, whichever entry point
/// (this function or tacit_init_context) runs first.
/// Kept public for manual/advanced init; tacit_init_context() covers it in
/// the one-shot flow. llama_backend_free must be called before process exit.
bool tacit_init_backend(void);

/// Releases any state allocated by tacit_init_backend.
void tacit_free_backend(void);

/// Loads a GGUF model from a filesystem path.
/// Part of the split init sequence; tacit_init_context() calls this
/// internally, so callers normally don't need it directly.
/// Returns a handle, or NULL on failure.
tacit_model * tacit_model_load(const char * model_path);

/// One-shot initialization: llama.cpp backend + GGUF model + inference context,
/// all in a single call. Returns a handle usable by tacit_generate /
/// tacit_generate_stream, or NULL on failure (query tacit_last_error).
tacit_model * tacit_init_context(const char * model_path);

/// Unloads the model and frees its context.
void tacit_model_free(tacit_model * model);

/// Clears the KV cache and wipes the cache buffers.
/// Used by the Dart worker after every generation (the app re-prompts full
/// history each turn, so stale KV only wastes memory while idle).
/// Returns 0 on success, -1 on failure.
int tacit_reset(tacit_model * model);

/// Runs one synchronous completion.
/// prompt: UTF-8 text.
/// max_tokens: maximum number of tokens to generate.
/// temperature: 0.0f = greedy; > 0.0f = sampling.
/// Returns a malloc-allocated UTF-8 string (free with tacit_free_string),
/// or NULL on failure (query tacit_last_error).
char * tacit_generate(tacit_model * model,
                      const char * prompt,
                      int32_t max_tokens,
                      float temperature);

/// Piece callback for tacit_eval_prompt and tacit_generate_stream.
/// Called once per token piece with a null-terminated UTF-8 string.
/// Return non-zero to abort early.
/// Guarantee: pieces always contain valid UTF-8 (llama_token_to_piece
/// returns UTF-8 bytes per the llama.cpp API contract).
typedef int (*TokenCallback)(const char * piece, void * user_data);

/// Legacy alias kept so tacit_generate_stream callers keep compiling.
typedef TokenCallback tacit_piece_cb;

/// Streaming completion.
/// piece is delivered through cb.
/// Returns 0 on success, non-zero on failure/abort.
int tacit_generate_stream(tacit_model * model,
                          const char * prompt,
                          int32_t max_tokens,
                          float temperature,
                          tacit_piece_cb cb,
                          void * user_data);

/// Frees a string returned by tacit_generate. NULL is fine.
void tacit_free_string(char * s);

/// Evaluates a prompt into the model context (KV cache) without generating
/// new tokens. callback fires once per prompt token with its text piece and
/// may return non-zero to abort early. Returns 0 on success, -1 on error.
int tacit_eval_prompt(tacit_model * model,
                      const char * prompt,
                      TokenCallback callback,
                      void * user_data);

/// Returns a null-terminated description, NULL if there was no error.
const char * tacit_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // TACIT_LLAMA_H
