cmake_minimum_required(VERSION 3.18.1)
project(tacit_llama_bridge C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Matikan komponen opsional bawaan llama.cpp
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)

set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp)

# Enable Vulkan backend for llama.cpp / ggml
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(SPIRV-Headers_DIR /usr/share/cmake/SPIRV-Headers CACHE PATH "" FORCE)
set(SPIRV-Tools_DIR /usr/lib64/cmake/SPIRV-Tools CACHE PATH "" FORCE)
set(Vulkan_INCLUDE_DIR /usr/include CACHE PATH "" FORCE)
set(Vulkan_GLSLC_EXECUTABLE /home/savero/Android/Sdk/ndk/28.2.13676358/shader-tools/linux-x86_64/glslc CACHE FILEPATH "" FORCE)

# Include header llama.cpp & ggml versi terbaru
include_directories(
    ${LLAMA_DIR}/include
    ${LLAMA_DIR}/ggml/include
    ${LLAMA_DIR}/src
)

# Masukkan llama.cpp ke dalam build tree
add_subdirectory(${LLAMA_DIR} llama_build)

# whisper.cpp: dibangun sebagai sub-proyek CMake TERPISAH (ExternalProject)
# karena whisper.cpp mem-vendor ggml 0.25.1 sedangkan llama.cpp mem-vendor
# ggml 0.23.0. Keduanya sama-sama mendefinisikan target bernama `ggml`, jadi
# `add_subdirectory` berdua akan bertabrakan — whisper harus dikompilasi
# melawan header & sumber ggml 0.25.1 miliknya sendiri, bukan ggml llama.
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)

set(WHISPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp)
set(WHISPER_EP_BINARY_DIR ${CMAKE_BINARY_DIR}/whisper_ep)

include(ExternalProject)
ExternalProject_Add(whisper_ep
    SOURCE_DIR ${WHISPER_DIR}
    BINARY_DIR ${WHISPER_EP_BINARY_DIR}
    CMAKE_ARGS
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DCMAKE_ANDROID_NDK=${CMAKE_ANDROID_NDK}
        -DCMAKE_ANDROID_ARCH_ABI=${CMAKE_ANDROID_ARCH_ABI}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_PLATFORM=${ANDROID_PLATFORM}
        -DANDROID_STL=${ANDROID_STL}
        -DBUILD_SHARED_LIBS=OFF
        -DGGML_OPENMP=OFF
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DWHISPER_BUILD_TESTS=OFF
        -DWHISPER_BUILD_EXAMPLES=OFF
        -DWHISPER_BUILD_SERVER=OFF
        -DCMAKE_INSTALL_PREFIX=${WHISPER_EP_BINARY_DIR}/install
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS
        ${WHISPER_EP_BINARY_DIR}/src/libwhisper.a
        ${WHISPER_EP_BINARY_DIR}/ggml/src/libggml.a
        ${WHISPER_EP_BINARY_DIR}/ggml/src/libggml-base.a
        ${WHISPER_EP_BINARY_DIR}/ggml/src/libggml-cpu.a
)

add_library(tacit_whisper SHARED
    tacit_whisper.cpp
)
add_dependencies(tacit_whisper whisper_ep)
target_include_directories(tacit_whisper PRIVATE
    ${WHISPER_DIR}/include
    ${WHISPER_DIR}/ggml/include
)

# Target impor menunjuk artefak statis yang dihasilkan ExternalProject
# (verifikasi jalur: <ep>/src/libwhisper.a, <ep>/ggml/src/libggml*.a).
add_library(whisper_ep_whisper STATIC IMPORTED)
set_target_properties(whisper_ep_whisper PROPERTIES
    IMPORTED_LOCATION ${WHISPER_EP_BINARY_DIR}/src/libwhisper.a
    INTERFACE_INCLUDE_DIRECTORIES "${WHISPER_DIR}/include;${WHISPER_DIR}/ggml/include"
)
add_library(whisper_ep_ggml STATIC IMPORTED)
set_target_properties(whisper_ep_ggml PROPERTIES
    IMPORTED_LOCATION ${WHISPER_EP_BINARY_DIR}/ggml/src/libggml.a
)
add_library(whisper_ep_ggml_base STATIC IMPORTED)
set_target_properties(whisper_ep_ggml_base PROPERTIES
    IMPORTED_LOCATION ${WHISPER_EP_BINARY_DIR}/ggml/src/libggml-base.a
)
add_library(whisper_ep_ggml_cpu STATIC IMPORTED)
set_target_properties(whisper_ep_ggml_cpu PROPERTIES
    IMPORTED_LOCATION ${WHISPER_EP_BINARY_DIR}/ggml/src/libggml-cpu.a
)

target_link_libraries(tacit_whisper
    PRIVATE
    whisper_ep_whisper
    whisper_ep_ggml
    whisper_ep_ggml_base
    whisper_ep_ggml_cpu
    log
)

# Buat DLL / Shared Library bridge untuk Flutter FFI
add_library(tacit_llama SHARED
    tacit_llama.cpp
)

# Link library bridge dengan llama, ggml, dan Android logging
target_link_libraries(tacit_llama
    PRIVATE
    llama
    ggml
    log
)

# sqlite-vec: ekstensi SQLite untuk vector similarity search (vec0).
# Sumber amalgamasi di-vendor di vec0/ (sqlite-vec v0.1.10-alpha.4,
# commit 04d28bd, plus sqlite3ext.h dari SQLite 3.52.0). Dibuild sebagai
# shared library loadable extension; di-daftarkan dari Dart lewat
# sqlite3.ensureExtensionLoaded(SqliteExtension.inLibrary(libvec0.so, ...)).
add_library(vec0 SHARED
    vec0/sqlite-vec.c
)
set_target_properties(vec0 PROPERTIES
    OUTPUT_NAME "vec0"
)
target_compile_definitions(vec0 PRIVATE DART_SHARED_LIB)