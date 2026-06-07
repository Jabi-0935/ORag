#!/usr/bin/env bash
# ============================================================================
# Build llama-server for Android ARM64 using the Android NDK.
#
# This produces a statically-linked PIE executable named 'libllama_server.so'
# that can be placed in jniLibs/arm64-v8a/ for inclusion in the APK.
#
# Prerequisites:
#   - Android NDK installed (set ANDROID_NDK environment variable)
#   - CMake 3.21+
#   - Ninja (recommended) or Make
#
# Usage:
#   export ANDROID_NDK=/path/to/ndk
#   bash scripts/build_llama_android.sh
# ============================================================================

set -euo pipefail

# ---- Configuration ----
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_CPP_TAG="${LLAMA_CPP_TAG:-master}"   # Pin to a release tag for reproducibility
ANDROID_ABI="arm64-v8a"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-28}"
OUTPUT_DIR="$(cd "$(dirname "$0")/../android/app/src/main/jniLibs/arm64-v8a" && pwd)"
BUILD_DIR="/tmp/llama-cpp-android-build"

# ---- Validate prerequisites ----
if [ -z "${ANDROID_NDK:-}" ]; then
    echo "ERROR: ANDROID_NDK is not set. Please set it to your NDK installation path."
    echo "  Example: export ANDROID_NDK=\$HOME/Android/Sdk/ndk/27.0.12077973"
    exit 1
fi

if ! command -v cmake &>/dev/null; then
    echo "ERROR: cmake not found in PATH"
    exit 1
fi

TOOLCHAIN_FILE="${ANDROID_NDK}/build/cmake/android.toolchain.cmake"
if [ ! -f "$TOOLCHAIN_FILE" ]; then
    echo "ERROR: Android NDK toolchain file not found at $TOOLCHAIN_FILE"
    exit 1
fi

echo "=== Building llama-server for Android ($ANDROID_ABI) ==="
echo "  NDK:       $ANDROID_NDK"
echo "  Platform:  $ANDROID_PLATFORM"
echo "  Output:    $OUTPUT_DIR"
echo ""

# ---- Clone / update llama.cpp ----
if [ -d "$BUILD_DIR/llama.cpp" ]; then
    echo "Updating existing llama.cpp checkout..."
    cd "$BUILD_DIR/llama.cpp"
    git fetch --all
    git checkout "$LLAMA_CPP_TAG"
else
    echo "Cloning llama.cpp (tag: $LLAMA_CPP_TAG)..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    git clone --depth 1 --branch "$LLAMA_CPP_TAG" "$LLAMA_CPP_REPO" llama.cpp || \
    git clone "$LLAMA_CPP_REPO" llama.cpp
    cd llama.cpp
    git checkout "$LLAMA_CPP_TAG" 2>/dev/null || true
fi

# ---- Configure ----
echo ""
echo "=== Configuring CMake ==="
rm -rf build-android
mkdir build-android
cd build-android

cmake .. \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DANDROID_ABI="$ANDROID_ABI" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DCMAKE_C_FLAGS="-march=armv8.2a+dotprod" \
    -DCMAKE_CXX_FLAGS="-march=armv8.2a+dotprod" \
    -DGGML_OPENMP=OFF \
    -DGGML_LLAMAFILE=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -G Ninja

# ---- Build ----
echo ""
echo "=== Building ==="
cmake --build . --config Release -j "$(nproc)"

# ---- Install ----
echo ""
echo "=== Installing to $OUTPUT_DIR ==="
mkdir -p "$OUTPUT_DIR"

# Find the llama-server binary (might be in bin/ or examples/server/)
SERVER_BIN=""
for candidate in bin/llama-server examples/server/llama-server llama-server; do
    if [ -f "$candidate" ]; then
        SERVER_BIN="$candidate"
        break
    fi
done

if [ -z "$SERVER_BIN" ]; then
    echo "ERROR: Could not find llama-server binary in build output"
    find . -name "llama-server" -o -name "llama_server" | head -5
    exit 1
fi

# Copy and rename to lib*.so pattern (required by Android packaging)
cp "$SERVER_BIN" "$OUTPUT_DIR/libllama_server.so"
echo ""
echo "=== Done ==="
echo "  Binary: $OUTPUT_DIR/libllama_server.so"
echo "  Size:   $(du -h "$OUTPUT_DIR/libllama_server.so" | cut -f1)"
echo ""
echo "Verify with: file $OUTPUT_DIR/libllama_server.so"
