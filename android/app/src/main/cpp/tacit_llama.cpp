// tacit_llama.cpp
// Thin C-API wrapper over llama.cpp for TacitPulse AI.

#include "tacit_llama.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
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

    // Offload all layers to GPU/iGPU VRAM (CUDA / ROCm / Vulkan) when the
    // build has a compute device. With zero GPUs llama.cpp safely falls back
    // to CPU — n_gpu_layers is just an upper bound, not a hard requirement.
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 99;

    h->model = llama_model_load_from_file(model_path, mparams);
    if (h->model == nullptr) {
        set_error("failed to load GGUF model");
        delete h;
        return nullptr;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = kDefaultNContext;

    // CPU thread guard: cap at 4 threads with headroom for the OS/UI so CPU
    // fallback never starves the system interface. At least 1 thread always.
    const int sys_threads = static_cast<int>(std::thread::hardware_concurrency());
    const int safe_threads = std::max(1, std::min(4, sys_threads - 2));
    cparams.n_threads = safe_threads;
    cparams.n_threads_batch = safe_threads;
    LOGI("llama params: n_gpu_layers=%d, n_threads=%d (sys=%d)",
         mparams.n_gpu_layers, safe_threads, sys_threads);

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

// Token id -> its text piece (empty for special tokens).
std::string token_to_piece(const llama_vocab * vocab, llama_token id) {
    char stack_buf[64];
    int32_t plen = llama_token_to_piece(vocab, id, stack_buf, sizeof(stack_buf), 0, false);
    if (plen < 0) {
        // Bigger buffer needed; llama_token_to_piece returns the negated size.
        std::vector<char> big(static_cast<size_t>(-plen + 1));
        plen = llama_token_to_piece(vocab, id, big.data(), static_cast<int32_t>(big.size()), 0, false);
        if (plen > 0) {
            return std::string(big.data(), static_cast<size_t>(plen));
        }
    } else if (plen > 0) {
        return std::string(stack_buf, static_cast<size_t>(plen));
    }
    return std::string();
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
        const std::string piece = token_to_piece(h->vocab, id);

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

// Batas panjang input embedding (token) — jendela latih multilingual-e5-small.
// Teks lebih panjang dipotong (ceilings; upgrade path: chunk-and-average).
constexpr int kEmbeddingMaxTokens = 512;

// Core embedding path: tokenize -> decode -> pool (MEAN dari GGUF pooling
// metadata; fallback mean manual bila pooling NONE) ke buffer mentah.
// Mengembalikan dim (jumlah float) pada sukses, -1 pada error (pesan -> error).
int embed_int(tacit_model * h,
              const char * text,
              std::vector<float> & out,
              std::string & error) {
    if (h->model == nullptr || h->ctx == nullptr || h->vocab == nullptr) {
        error = "model handle is not loaded";
        return -1;
    }

    // Dimensi keluaran embedding (== n_embd untuk e5-small: 384).
    const int dim = static_cast<int>(llama_model_n_embd_out(h->model));
    if (dim <= 0) {
        error = "model has no embedding size";
        return -1;
    }

    std::vector<llama_token> tokens;
    if (!tokenize(h->vocab, text, tokens)) {
        error = "failed to tokenize the text";
        return -1;
    }
    if (static_cast<int>(tokens.size()) > kEmbeddingMaxTokens) {
        tokens.resize(static_cast<size_t>(kEmbeddingMaxTokens));
    }

    // Minta konteks menghitung embeddings untuk SEMUA token batch
    // (setara output_all di llama.cpp) — wajib sebelum decode.
    llama_set_embeddings(h->ctx, true);

    // State KV segar: sisa sequence sebelumnya tidak relevan untuk embedding
    // (contoh resmi examples/embedding juga clear sebelum decode).
    llama_memory_clear(llama_get_memory(h->ctx), /*data=*/true);

    // pos = NULL -> posisi dilacak otomatis (0..n-1); seq_id = NULL -> seq 0;
    // logits = NULL + embeddings -> semua token output (lihat llama.h).
    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int32_t>(tokens.size()));
    const int32_t rc = llama_decode(h->ctx, batch);
    if (rc != 0) {
        error = rc == 1
                    ? "llama_decode: KV cache full (increase context size)"
                    : "llama_decode(embedding) failed";
        return -1;
    }

    out.assign(static_cast<size_t>(dim), 0.0f);

    const float * pooled = nullptr;
    if (llama_pooling_type(h->ctx) != LLAMA_POOLING_TYPE_NONE) {
        pooled = llama_get_embeddings_seq(h->ctx, /*seq_id=*/0);
        if (pooled == nullptr) {
            error = "llama_get_embeddings_seq returned NULL";
            return -1;
        }
        memcpy(out.data(), pooled, sizeof(float) * static_cast<size_t>(dim));
    } else {
        // Fallback: model GGUF tanpa metadata pooling -> mean per token.
        int counted = 0;
        for (int32_t i = 0; i < static_cast<int32_t>(tokens.size()); ++i) {
            const float * embd = llama_get_embeddings_ith(h->ctx, i);
            if (embd == nullptr) {
                continue;
            }
            for (int d = 0; d < dim; ++d) {
                out[static_cast<size_t>(d)] += embd[d];
            }
            ++counted;
        }
        if (counted == 0) {
            error = "no token embeddings produced";
            return -1;
        }
        for (int d = 0; d < dim; ++d) {
            out[static_cast<size_t>(d)] /= static_cast<float>(counted);
        }
    }

    // Idle bersih: jangan menahan KV cache antar panggilan (seperti tacit_reset).
    llama_memory_clear(llama_get_memory(h->ctx), /*data=*/true);
    return dim;
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
    // data=true: selain mereset metadata sel, isi buffer KV di-zero-kan.
    // Dipanggil setelah tiap generasi selesai (lihat worker Dart) supaya
    // idle tidak menahan sisa cache antar turn — setiap prompt ulang dari
    // nol, sehingga KV yang lama memang sudah tidak terpakai.
    llama_memory_clear(llama_get_memory(model->ctx), /*data=*/true);
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

// Evaluates a prompt into the model context (KV cache) without generating
// new tokens. The callback fires once per prompt token with its text piece
// and may return non-zero to abort early. Returns 0 on success, -1 on error.
int tacit_eval_prompt(tacit_model * model,
                      const char * prompt,
                      TokenCallback callback,
                      void * user_data) {
    if (model == nullptr || prompt == nullptr || callback == nullptr) {
        set_error("null model, prompt or callback");
        return -1;
    }

    std::lock_guard<std::mutex> lock(model->mtx);

    std::vector<llama_token> prompt_tokens;
    if (!tokenize(model->vocab, prompt, prompt_tokens)) {
        set_error("failed to tokenize the prompt");
        return -1;
    }

    // Process the whole prompt in one batch -> fills the KV cache.
    llama_batch batch = llama_batch_get_one(prompt_tokens.data(), static_cast<int32_t>(prompt_tokens.size()));
    const int32_t rc = llama_decode(model->ctx, batch);
    if (rc != 0) {
        set_error(rc == 1
                      ? "llama_decode: KV cache full (increase context size)"
                      : "llama_decode(prompt) failed");
        return -1;
    }

    for (llama_token id : prompt_tokens) {
        const std::string piece = token_to_piece(model->vocab, id);
        if (!piece.empty() && callback(piece.c_str(), user_data) != 0) {
            break; // caller asked to abort early
        }
    }
    return 0;
}

int tacit_embedding_dim(tacit_model * model) {
    if (model == nullptr || model->model == nullptr) {
        set_error("model handle is null");
        return -1;
    }
    return static_cast<int>(llama_model_n_embd_out(model->model));
}

int tacit_get_embedding(tacit_model * model,
                        const char * text,
                        float * out,
                        int out_cap) {
    if (model == nullptr) {
        set_error("model handle is null");
        return -1;
    }
    if (text == nullptr) {
        set_error("text is null");
        return -1;
    }

    const int dim = tacit_embedding_dim(model);
    if (dim < 0) {
        return -1; // set_error sudah dipanggil tacit_embedding_dim
    }
    if (out == nullptr || out_cap <= 0) {
        return dim; // size query: tidak ada yang ditulis
    }
    if (out_cap < dim) {
        set_error("embedding output buffer too small");
        return -1;
    }

    std::vector<float> buffer;
    std::string error;
    {
        std::lock_guard<std::mutex> lock(model->mtx);
        const int got = embed_int(model, text, buffer, error);
        if (got < 0) {
            set_error(error.c_str());
            return -1;
        }
    }
    memcpy(out, buffer.data(), sizeof(float) * static_cast<size_t>(dim));
    return dim;
}

const char * tacit_last_error(void) {
    return g_last_error[0] == '\0' ? nullptr : g_last_error;
}

} // extern "C"
