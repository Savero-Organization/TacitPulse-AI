#include "llama.h"
#include <android/log.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "TacitPulse_Native", __VA_ARGS__)

extern "C" {
    bool tacit_init_backend() {
        llama_backend_init();
        LOGI("llama.cpp backend for TacitPulse AI initialized successfully!");
        return true;
    }

    void tacit_free_backend() {
        llama_backend_free();
        LOGI("llama.cpp backend freed.");
    }
}