#!/usr/bin/env bash
# Cross-compile native Android libraries for Breath of Fire IV:
#   1. Stages a patched copy of ps-recomp in android/build/ps-recomp (leaving
#      the git submodule untouched).
#   2. Builds libSDL2.so for each target ABI via CMake + Android NDK and copies
#      SDL2's Java Activity classes into android/app/src/main/java/org/libsdl/app/.
#   3. Cross-compiles port/src into libbof4.so using Odin (-subtarget:android).
#
# Requirements:
#   - Odin dev-2026-11+ on PATH (with -subtarget:android support)
#   - Android NDK r26+ (ANDROID_NDK_HOME or ANDROID_NDK_ROOT or ODIN_ANDROID_NDK)
#   - CMake 3.22+ and Ninja (or Make)
#   - SDL2 2.30+ source tree in android/sdl2 (or SDL2_DIR=/path/to/SDL2)
#   - Recompiled game sources in port/src/rec/ (run ./setup.sh once with your disc)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT_DIR="$ROOT_DIR/port"
PATCH_FILE="$ROOT_DIR/patches/ps-recomp-android.patch"
STAGE_PS="$SCRIPT_DIR/build/ps-recomp"
JNI_LIBS="$SCRIPT_DIR/app/src/main/jniLibs"
SDL2_DIR="${SDL2_DIR:-$SCRIPT_DIR/sdl2}"
SDL2_JAVA_DST="$SCRIPT_DIR/app/src/main/java/org/libsdl/app"

ABIS="arm64-v8a"
OPT="${BOF4_OPT:-speed}"
DEBUG_FLAGS=""
FAST_RELEASE=0
STANDALONE=0
API_LEVEL="${BOF4_ANDROID_API:-29}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)          ABIS="$2"; shift 2 ;;
        --debug)        DEBUG_FLAGS="-debug"; OPT="minimal"; shift ;;
        --fast-release) FAST_RELEASE=1; shift ;;
        --standalone)   STANDALONE=1; shift ;;
        --api)          API_LEVEL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--abi arm64-v8a[,x86_64]] [--debug] [--fast-release] [--standalone] [--api 29]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Locate Android NDK
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ODIN_ANDROID_NDK:-}}}"
if [[ -z "$NDK" && -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/ndk" ]]; then
    NDK="$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -n 1 || true)"
fi
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
    echo "error: Android NDK not found. Set ANDROID_NDK_HOME (or ODIN_ANDROID_NDK)." >&2
    exit 1
fi
export ODIN_ANDROID_NDK="$NDK"

if ! command -v odin >/dev/null 2>&1; then
    echo "error: 'odin' compiler not found on PATH (requires Odin dev-2026-11+)." >&2
    exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "error: 'cmake' not found on PATH." >&2
    exit 1
fi
if [[ ! -d "$PORT_DIR/src/rec" ]]; then
    if [[ "$STANDALONE" == "1" ]]; then
        echo "==> Building standalone APK (no port/src/rec; uses built-in R3000A interpreter or user-provided bof4.native)"
    else
        echo "==> port/src/rec not found; enabling standalone APK mode (pass your disc to ./setup.sh to embed statically recompiled code)"
        STANDALONE=1
    fi
fi
if [[ ! -f "$SDL2_DIR/CMakeLists.txt" ]]; then
    echo "error: SDL2 source not found at $SDL2_DIR. Run ./android/build.sh (which downloads SDL2) or set SDL2_DIR." >&2
    exit 1
fi

# 0. Prepare Odin source dir (use staged copy with stub rec package in standalone mode)
BUILD_SRC="$PORT_DIR/src"
if [[ "$STANDALONE" == "1" && ! -d "$PORT_DIR/src/rec" ]]; then
    STAGE_SRC="$SCRIPT_DIR/build/src-standalone"
    rm -rf "$STAGE_SRC"
    mkdir -p "$STAGE_SRC/rec"
    cp -a "$PORT_DIR/src/." "$STAGE_SRC/"
    cat > "$STAGE_SRC/rec/rec.odin" <<'EOF'
// Standalone stub: no copyrighted game code is compiled into this binary.
// ps-recomp runs the user's disc image via its built-in R3000A interpreter,
// or loads a user-generated bof4_arm64.native / bof4.native blob if present.
package rec

import cpu "ps:psx/cpu"

EXE_FUNCS: [0]cpu.Func_Entry
register_overlays :: proc() {}
EOF
    BUILD_SRC="$STAGE_SRC"
fi

# 1. Stage patched ps-recomp cleanly without touching the submodule
echo "==> Staging patched ps-recomp into $STAGE_PS"
rm -rf "$STAGE_PS"
mkdir -p "$(dirname "$STAGE_PS")"
cp -a "$ROOT_DIR/ps-recomp" "$STAGE_PS"
rm -rf "$STAGE_PS/.git"
if [[ -f "$PATCH_FILE" ]]; then
    patch -d "$STAGE_PS" -p1 -s < "$PATCH_FILE"
fi

# 2. Copy SDL2 Android Java sources so Bof4Activity extends org.libsdl.app.SDLActivity
SDL2_JAVA_SRC="$SDL2_DIR/android-project/app/src/main/java/org/libsdl/app"
if [[ -d "$SDL2_JAVA_SRC" ]]; then
    mkdir -p "$SDL2_JAVA_DST"
    cp -f "$SDL2_JAVA_SRC/"*.java "$SDL2_JAVA_DST/"
else
    echo "warning: SDL2 Java sources not found at $SDL2_JAVA_SRC" >&2
fi

GEN_ARGS=()
if command -v ninja >/dev/null 2>&1; then
    GEN_ARGS=(-G Ninja)
fi

EXTRA_ODIN_FLAGS=()
if [[ "$FAST_RELEASE" == "1" ]]; then
    EXTRA_ODIN_FLAGS+=(-no-bounds-check)
fi

IFS=',' read -ra ABI_LIST <<< "$ABIS"
for ABI in "${ABI_LIST[@]}"; do
    ABI="$(echo "$ABI" | xargs)"
    case "$ABI" in
        arm64-v8a)
            ODIN_TARGET="linux_arm64"
            ODIN_ARCH_FLAGS=(-microarch:armv8-a)
            ;;
        x86_64)
            ODIN_TARGET="linux_amd64"
            ODIN_ARCH_FLAGS=()
            ;;
        *)
            echo "error: unsupported Android ABI '$ABI' (supported: arm64-v8a, x86_64)" >&2
            exit 1
            ;;
    esac

    # 3. Build libSDL2.so via CMake + NDK toolchain
    SDL_BUILD="$SCRIPT_DIR/build/sdl2-$ABI"
    ABI_OUT="$JNI_LIBS/$ABI"
    mkdir -p "$ABI_OUT"

    if [[ ! -f "$ABI_OUT/libSDL2.so" ]]; then
        echo "==> Building libSDL2.so for $ABI (API $API_LEVEL)"
        cmake -S "$SCRIPT_DIR/app/jni" -B "$SDL_BUILD" "${GEN_ARGS[@]}" \
            -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI="$ABI" \
            -DANDROID_PLATFORM="android-$API_LEVEL" \
            -DCMAKE_BUILD_TYPE=Release \
            -DSDL2_DIR="$SDL2_DIR"
        cmake --build "$SDL_BUILD" --target SDL2 --parallel
        cp -f "$SDL_BUILD/sdl2-build/libSDL2.so" "$ABI_OUT/libSDL2.so"
    else
        echo "==> Using cached $ABI_OUT/libSDL2.so"
    fi

    # 4. Cross-compile libbof4.so with Odin (-subtarget:android -build-mode:shared)
    echo "==> Compiling libbof4.so for $ABI ($ODIN_TARGET, -o:$OPT)"
    (
        cd "$PORT_DIR"
        odin build "$BUILD_SRC" \
            -out:"$ABI_OUT/libbof4.so" \
            -target:"$ODIN_TARGET" \
            -subtarget:android \
            -minimum-os-version:"$API_LEVEL" \
            -build-mode:shared \
            -use-separate-modules \
            $DEBUG_FLAGS \
            -o:"$OPT" \
            "${ODIN_ARCH_FLAGS[@]}" \
            "${EXTRA_ODIN_FLAGS[@]}" \
            -collection:ps="$STAGE_PS" \
            -define:ENV_PREFIX=BOF4_ \
            -define:PS_ANDROID_PATCH=true \
            -extra-linker-flags:"-L$ABI_OUT -lSDL2 -landroid -llog -Wl,-rpath,\$ORIGIN -Wl,-z,max-page-size=16384"
    )
    echo "==> Built $ABI_OUT/libbof4.so"
done
