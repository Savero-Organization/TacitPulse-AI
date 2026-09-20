// tacit_llama.h
// Simple C-API bridge over llama.cpp for Dart FFI.

// Typical Dart flow (via package:ffi):
//   final lib = DynamicLibrary.open('libtacit_llama.so');
//   tacit_init_backend();
//   final model = tacit_model_load(ggufPath);
//   final text  = tacit_generate(model, prompt, 512, 0.8f);
//   tacit_free_string(text);
//   tacit_model_free(model);
//   tacit_free_backend();

#ifndef TACIT_LLAMA_H
#define TACIT_LLAMA_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a loaded model plus its inference context.
typedef struct tacit_model tacit_model;

// Initializes the llama.cpp backend.
// function. llama_backend_free must be called before process exit.
bool tacit_init_backend(void);

// Releases any state allocated by tacit_init_backend.
void tacit_free_backend(void);

// Loads a GGUF model from a filesystem path.
// Returns a handle, or NULL on failure.
tacit_model * tacit_model_load(const char * model_path);

// One-shot initialization: llama.cpp backend + GGUF model + inference context,
// all in a single call. Returns a handle usable by tacit_generate /
// tacit_generate_stream, or NULL on failure (query tacit_last_error).
tacit_model * tacit_init_context(const char * model_path);

// Unloads the model and frees its context.
void tacit_model_free(tacit_model * model);

// Clears the KV cache.
// Returns 0 on success, -1 on failure.
int tacit_reset(tacit_model * model);

// Runs one synchronous completion.
// prompt: UTF-8 text.
// max_tokens: maximum number of tokens to generate.
// temperature: 0.0f = greedy; > 0.0f = sampling.
// Returns a malloc-allocated UTF-8 string (free with tacit_free_string),
// or NULL on failure (query tacit_last_error).
char * tacit_generate(tacit_model * model,
                      const char * prompt,
                      int32_t max_tokens,
                      float temperature);

// Piece callback for tacit_generate_stream.
// Called once per generated token piece with a null-terminated UTF-8 string.
// Return non-zero to abort generation early.
typedef int (*tacit_piece_cb)(const char * piece, void * user_data);

// Streaming completion.
// piece is delivered through cb.
// Returns 0 on success, non-zero on failure/abort.
int tacit_generate_stream(tacit_model * model,
                          const char * prompt,
                          int32_t max_tokens,
                          float temperature,
                          tacit_piece_cb cb,
                          void * user_data);

// Frees a string returned by tacit_generate. NULL is fine.
void tacit_free_string(char * s);

// Returns a null-terminated description, NULL if there was no error.
const char * tacit_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // TACIT_LLAMA_H
