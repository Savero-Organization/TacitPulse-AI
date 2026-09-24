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

# Include header llama.cpp & ggml versi terbaru
include_directories(
    ${LLAMA_DIR}/include
    ${LLAMA_DIR}/ggml/include
    ${LLAMA_DIR}/src
)

# Masukkan llama.cpp ke dalam build tree
add_subdirectory(${LLAMA_DIR} llama_build)

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