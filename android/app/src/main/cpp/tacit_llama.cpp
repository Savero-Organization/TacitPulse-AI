// tacit_llama.cpp
// Thin C-API wrapper over llama.cpp for TacitPulse AI.

#include "tacit_llama.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "llama.h"

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "TacitPulse_Native", __VA_ARGS__)
#else
#define LOGI(...) fprintf(stderr, "[TacitPulse_Native] " __VA_ARGS__)
#endif

// Opaque type declared in tacit_llama.h.
struct tacit_model {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    const llama_vocab * vocab = nullptr;
    llama_token eos = -1;
    llama_token eot = -1;
    std::mutex mtx;
};

namespace {

// Human-readable error for the calling thread.
thread_local char g_last_error[1024];

void set_error(const char * message) {
    snprintf(g_last_error, sizeof(g_last_error), "%s", message);
}

// Guards llama backend init so it happens exactly once per process,
// no matter which entry point (tacit_init_backend / tacit_init_context) runs first.
std::mutex g_backend_mtx;
bool g_backend_initialized = false;

// Max generation context.
constexpr uint32_t kDefaultNContext = 4096;

// Creates the model handle (loads GGUF + creates inference context).
// Used by tacit_model_load and tacit_init_context.
tacit_model * model_load_internal(const char * model_path) {
    if (model_path == nullptr || model_path[0] == '\0') {
        set_error("model_path is empty");
        return nullptr;
    }

    auto * h = new (std::nothrow) tacit_model;
    if (h == nullptr) {
        set_error("out of memory");
        return nullptr;
    }

    h->model = llama_model_load_from_file(model_path, llama_model_default_params());
    if (h->model == nullptr) {
        set_error("failed to load GGUF model");
        delete h;
        return nullptr;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = kDefaultNContext;

    h->ctx = llama_init_from_model(h->model, cparams);
    if (h->ctx == nullptr) {
        set_error("failed to create inference context");
        llama_model_free(h->model);
        delete h;
        return nullptr;
    }

    h->vocab = llama_model_get_vocab(h->model);
    if (h->vocab == nullptr) {
        set_error("model has no vocabulary");
        llama_free(h->ctx);
        llama_model_free(h->model);
        delete h;
        return nullptr;
    }

    h->eos = llama_vocab_eos(h->vocab);
    h->eot = llama_vocab_eot(h->vocab);

    LOGI("model loaded: %s", model_path);
    return h;
}

} // namespace

namespace {

// Tokenizes prompt text.
bool tokenize(const llama_vocab * vocab, const char * text, std::vector<llama_token> & out) {
    const int32_t len = static_cast<int32_t>(strlen(text));

    int32_t n = llama_tokenize(vocab, text, len, nullptr, 0, /*add_special=*/true, /*parse_special=*/false);
    if (n < 0) {
        n = -n; // requested buffer size
    }
    if (n <= 0) {
        return false;
    }

    out.resize(static_cast<size_t>(n));
    const int32_t got = llama_tokenize(vocab, text, len, out.data(), n, true, false);
    if (got < 0) {
        return false;
    }
    out.resize(static_cast<size_t>(got));
    return !out.empty();
}

// Builds a sampler chain for the requested temperature per call.
llama_sampler * build_sampler(float temperature) {
    llama_sampler * chain = llama_sampler_chain_init(llama_sampler_chain_default_params());

    if (temperature <= 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    } else {
        const uint32_t seed = static_cast<uint32_t>(
            std::chrono::system_clock::now().time_since_epoch().count());
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed));
    }
    return chain;
}

// Core generation loop.
bool generate_int(tacit_model * h,
                  const char * prompt,
                  int32_t max_tokens,
                  float temperature,
                  tacit_piece_cb piece_cb,
                  void * user_data,
                  std::string & output,
                  std::string & error) {
    if (h == nullptr || h->model == nullptr || h->ctx == nullptr) {
        error = "model handle is not loaded";
        return false;
    }

    std::vector<llama_token> prompt_tokens;
    if (!tokenize(h->vocab, prompt, prompt_tokens)) {
        error = "failed to tokenize the prompt";
        return false;
    }

    // Process the whole prompt in one batch.
    llama_batch batch = llama_batch_get_one(prompt_tokens.data(), static_cast<int32_t>(prompt_tokens.size()));
    const int32_t batch_rc = llama_decode(h->ctx, batch);
    if (batch_rc != 0) {
        error = batch_rc == 1
                    ? "llama_decode: KV cache full (increase context size)"
                    : "llama_decode(prompt) failed";
        return false;
    }

    llama_sampler * sampler = build_sampler(temperature);
    llama_sampler_reset(sampler);

    int32_t n_generated = 0;
    bool stopped = false;
    while (n_generated < max_tokens) {
        const llama_token sampled = llama_sampler_sample(sampler, h->ctx, -1);
        llama_sampler_reset(sampler); // required before sampling the next token
        llama_token id = sampled; // llama_batch_get_one needs a non-const token pointer

        // Stop on end-of-sequence / end-of-turn tokens when the model defines them.
        if ((id == h->eos && h->eos >= 0) || (id == h->eot && h->eot >= 0)) {
            break;
        }
        if (id < 0 || id >= llama_vocab_n_tokens(h->vocab)) {
            break; // sampled an out-of-range token, nothing sensible left to do
        }

        // Token id -> text piece.
        std::string piece;
        {
            char stack_buf[64];
            int32_t plen = llama_token_to_piece(h->vocab, id, stack_buf, sizeof(stack_buf), 0, false);
            if (plen < 0) {
                std::vector<char> big(static_cast<size_t>(-plen + 1));
                plen = llama_token_to_piece(h->vocab, id, big.data(), static_cast<int32_t>(big.size()), 0, false);
                if (plen > 0) {
                    piece.assign(big.data(), static_cast<size_t>(plen));
                }
            } else if (plen > 0) {
                piece.assign(stack_buf, static_cast<size_t>(plen));
            }
        }

        if (!piece.empty()) {
            if (!output.empty()) {
                output += piece;
            } else {
                output = piece;
            }
            if (piece_cb != nullptr && piece_cb(piece.c_str(), user_data) != 0) {
                stopped = true; // caller asked to abort
            }
        }

        if (stopped) {
            break;
        }

        // Feed the sampled token back into the context. Positions are tracked
        // automatically by llama_decode for batches from llama_batch_get_one.
        llama_batch next = llama_batch_get_one(&id, 1);
        const int32_t next_rc = llama_decode(h->ctx, next);
        if (next_rc != 0) {
            error = next_rc == 1
                        ? "llama_decode: KV cache full (increase context size)"
                        : "llama_decode(token) failed";
            llama_sampler_free(sampler);
            return false;
        }
        ++n_generated;
    }

    llama_sampler_free(sampler);
    return true;
}

}

extern "C" {

bool tacit_init_backend(void) {
    std::lock_guard<std::mutex> lock(g_backend_mtx);
    if (!g_backend_initialized) {
        llama_backend_init();
        g_backend_initialized = true;
        LOGI("llama.cpp backend for TacitPulse AI initialized successfully!");
    }
    return true;
}

void tacit_free_backend(void) {
    std::lock_guard<std::mutex> lock(g_backend_mtx);
    if (g_backend_initialized) {
        llama_backend_free();
        g_backend_initialized = false;
        LOGI("llama.cpp backend freed.");
    }
}

tacit_model * tacit_model_load(const char * model_path) {
    return model_load_internal(model_path);
}

// One-shot init: llama backend + GGUF model + inference context.
// Returns a handle usable by tacit_generate / tacit_generate_stream,
// or NULL on failure (query tacit_last_error).
tacit_model * tacit_init_context(const char * model_path) {
    {
        std::lock_guard<std::mutex> lock(g_backend_mtx);
        if (!g_backend_initialized) {
            llama_backend_init();
            g_backend_initialized = true;
            LOGI("llama.cpp backend initialized via tacit_init_context.");
        }
    }
    return model_load_internal(model_path);
}

void tacit_model_free(tacit_model * model) {
    if (model == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(model->mtx);
    llama_free(model->ctx);
    llama_model_free(model->model);
    delete model;
}

int tacit_reset(tacit_model * model) {
    if (model == nullptr) {
        set_error("model handle is null");
        return -1;
    }
    std::lock_guard<std::mutex> lock(model->mtx);
    llama_memory_clear(llama_get_memory(model->ctx), /*data=*/false);
    return 0;
}

char * tacit_generate(tacit_model * model,
                      const char * prompt,
                      int32_t max_tokens,
                      float temperature) {
    if (model == nullptr || prompt == nullptr) {
        set_error("null model or prompt");
        return nullptr;
    }
    if (max_tokens <= 0) {
        return static_cast<char *>(malloc(1)); // empty string
    }

    std::string output;
    std::string error;
    {
        std::lock_guard<std::mutex> lock(model->mtx);
        const bool ok = generate_int(model, prompt, max_tokens, temperature, nullptr, nullptr, output, error);
        if (!ok) {
            set_error(error.c_str());
            return nullptr;
        }
    }

    char * result = static_cast<char *>(malloc(output.size() + 1));
    if (result == nullptr) {
        set_error("out of memory");
        return nullptr;
    }
    memcpy(result, output.c_str(), output.size());
    result[output.size()] = '\0';
    return result;
}

int tacit_generate_stream(tacit_model * model,
                          const char * prompt,
                          int32_t max_tokens,
                          float temperature,
                          tacit_piece_cb cb,
                          void * user_data) {
    if (model == nullptr || prompt == nullptr || cb == nullptr) {
        set_error("null model, prompt or callback");
        return -1;
    }

    std::string output;
    std::string error;
    std::lock_guard<std::mutex> lock(model->mtx);
    if (!generate_int(model, prompt, max_tokens, temperature, cb, user_data, output, error)) {
        set_error(error.c_str());
        return -1;
    }
    return 0;
}

void tacit_free_string(char * s) {
    free(s);
}

const char * tacit_last_error(void) {
    return g_last_error[0] == '\0' ? nullptr : g_last_error;
}

} // extern "C"
