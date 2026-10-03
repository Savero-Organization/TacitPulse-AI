// tacit_whisper.cpp
// Thin C-API wrapper over whisper.cpp for Tacit Pulse AI.

#include "tacit_whisper.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#include "whisper.h"

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "TacitPulse_Native", __VA_ARGS__)
#else
#define LOGI(...) fprintf(stderr, "[TacitPulse_Native] " __VA_ARGS__)
#endif

struct tacit_whisper_context {
    whisper_context * ctx = nullptr;
    std::mutex mtx;
};

namespace {

// Human-readable error for the calling thread.
thread_local char g_last_error[1024];

void clear_error() {
    g_last_error[0] = '\0';
}

void set_error(const char * message) {
    if (message == nullptr || message[0] == '\0') {
        g_last_error[0] = '\0';
        return;
    }
    snprintf(g_last_error, sizeof(g_last_error), "%s", message);
}

} // namespace

extern "C" {

tacit_whisper_context * tacit_whisper_init(const char * model_path) {
    try {
        clear_error();
        if (model_path == nullptr || model_path[0] == '\0') {
            set_error("model_path is empty");
            return nullptr;
        }

        auto * h = new (std::nothrow) tacit_whisper_context;
        if (h == nullptr) {
            set_error("out of memory");
            return nullptr;
        }

        whisper_context_params cparams = whisper_context_default_params();
        h->ctx = whisper_init_from_file_with_params(model_path, cparams);
        if (h->ctx == nullptr) {
            set_error("failed to load whisper model");
            delete h;
            return nullptr;
        }
        return h;
    } catch (...) {
        set_error("exception in tacit_whisper_init");
        return nullptr;
    }
}

void tacit_whisper_free(tacit_whisper_context * ctx) {
    try {
        clear_error();
        if (ctx == nullptr) {
            return;
        }
        if (ctx->ctx != nullptr) {
            whisper_free(ctx->ctx);
        }
        delete ctx;
    } catch (...) {
        set_error("exception in tacit_whisper_free");
    }
}

int tacit_whisper_transcribe(tacit_whisper_context * ctx,
                             const float * pcm_data,
                             int n_samples,
                             const char * language) {
    try {
        clear_error();
        if (ctx == nullptr || ctx->ctx == nullptr) {
            set_error("invalid context");
            return -1;
        }
        if (pcm_data == nullptr || n_samples <= 0) {
            set_error("empty audio buffer");
            return -2;
        }

        std::lock_guard<std::mutex> lock(ctx->mtx);

        whisper_full_params params =
            whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = std::max(
            1u,
            std::min(4u, std::thread::hardware_concurrency()));
        params.print_progress = false;
        params.print_realtime = false;
        params.print_special = false;
        params.print_timestamps = false;
        params.single_segment = false;
        params.translate = false;
        // NULL/empty language -> whisper.cpp auto-detect; the Dart bridge
        // passes an explicit ISO-639 code (default "id").
        params.language =
            (language != nullptr && language[0] != '\0') ? language : nullptr;
        params.no_context = true;

        const int rc = whisper_full(ctx->ctx, params, pcm_data, n_samples);
        if (rc != 0) {
            set_error("whisper_full failed");
            return rc;
        }
        return 0;
    } catch (...) {
        set_error("exception in tacit_whisper_transcribe");
        return -3;
    }
}

int tacit_whisper_full_n_segments(tacit_whisper_context * ctx) {
    try {
        clear_error();
        if (ctx == nullptr || ctx->ctx == nullptr) {
            return 0;
        }
        std::lock_guard<std::mutex> lock(ctx->mtx);
        return whisper_full_n_segments(ctx->ctx);
    } catch (...) {
        set_error("exception in tacit_whisper_full_n_segments");
        return 0;
    }
}

const char * tacit_whisper_full_get_segment_text(tacit_whisper_context * ctx,
                                                 int i_segment) {
    try {
        clear_error();
        if (ctx == nullptr || ctx->ctx == nullptr) {
            return nullptr;
        }
        std::lock_guard<std::mutex> lock(ctx->mtx);
        return whisper_full_get_segment_text(ctx->ctx, i_segment);
    } catch (...) {
        set_error("exception in tacit_whisper_full_get_segment_text");
        return nullptr;
    }
}

int64_t tacit_whisper_full_get_segment_t0(tacit_whisper_context * ctx,
                                          int i_segment) {
    try {
        clear_error();
        if (ctx == nullptr || ctx->ctx == nullptr) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(ctx->mtx);
        return whisper_full_get_segment_t0(ctx->ctx, i_segment);
    } catch (...) {
        set_error("exception in tacit_whisper_full_get_segment_t0");
        return -1;
    }
}

int64_t tacit_whisper_full_get_segment_t1(tacit_whisper_context * ctx,
                                          int i_segment) {
    try {
        clear_error();
        if (ctx == nullptr || ctx->ctx == nullptr) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(ctx->mtx);
        return whisper_full_get_segment_t1(ctx->ctx, i_segment);
    } catch (...) {
        set_error(
            "exception in tacit_whisper_full_get_segment_t1");
        return -1;
    }
}

const char * tacit_whisper_last_error(void) {
    return g_last_error[0] == '\0' ? nullptr : g_last_error;
}

} // extern "C"
