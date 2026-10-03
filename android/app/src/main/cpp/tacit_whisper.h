// tacit_whisper.h
// Simple opaque C-API bridge over whisper.cpp for Dart FFI.

#ifndef TACIT_WHISPER_H
#define TACIT_WHISPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a loaded whisper.cpp model context.
typedef struct tacit_whisper_context tacit_whisper_context;

/// Loads a whisper.cpp model (e.g. ggml-base.bin) from a filesystem path.
/// Returns a handle, or NULL on failure (query tacit_whisper_last_error).
/// The caller must release it with tacit_whisper_free().
tacit_whisper_context * tacit_whisper_init(const char * model_path);

/// Releases the model context. NULL is fine.
void tacit_whisper_free(tacit_whisper_context * ctx);

/// Runs one synchronous full transcription over a 16 kHz mono Float32 PCM
/// buffer. `language` is an ISO-639 code ("id", "en", ...); pass NULL or an
/// empty string to let whisper.cpp auto-detect the spoken language (the Dart
/// bridge defaults to "id" for technician voice notes).
/// Returns 0 on success, non-zero on failure (query tacit_whisper_last_error).
/// Thread-safety: serialized per handle; safe while another handle runs.
int tacit_whisper_transcribe(tacit_whisper_context * ctx,
                             const float * pcm_data,
                             int n_samples,
                             const char * language);

/// Number of segments produced by the last successful tacit_whisper_transcribe
/// call, or 0 when there is no context / no result yet.
int tacit_whisper_full_n_segments(tacit_whisper_context * ctx);

/// Segment text pointer owned by the native context; valid until the next
/// tacit_whisper_transcribe call on the same handle. Returns NULL on error.
const char * tacit_whisper_full_get_segment_text(tacit_whisper_context * ctx,
                                                 int i_segment);

/// Segment start offset in whisper.cpp time units (10 ms ticks), matching the
/// upstream whisper_full_get_segment_t0 semantics.
int64_t tacit_whisper_full_get_segment_t0(tacit_whisper_context * ctx,
                                          int i_segment);

/// Segment end offset in whisper.cpp time units (10 ms ticks).
int64_t tacit_whisper_full_get_segment_t1(tacit_whisper_context * ctx,
                                          int i_segment);

/// Human-readable description of the last error on this thread, or NULL.
const char * tacit_whisper_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // TACIT_WHISPER_H
