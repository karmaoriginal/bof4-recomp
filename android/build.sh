#!/usr/bin/env bash
# End-to-end Android APK builder for Breath of Fire IV (bof4-recomp).
#
# Usage:
#   ./android/build.sh                     # Debug APK for arm64-v8a
#   ./android/build.sh --release           # Release APK (-o:speed)
#   ./android/build.sh --fast-release      # Release APK (-o:speed -no-bounds-check)
#   ./android/build.sh --abi arm64-v8a,x86_64
#   ./android/build.sh --install           # Also install via adb after building
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDL2_VERSION="${SDL2_VERSION:-2.30.11}"
SDL2_DIR="${SDL2_DIR:-$SCRIPT_DIR/sdl2}"

ABIS="arm64-v8a"
BUILD_TYPE="Debug"
NATIVE_ARGS=()
DO_INSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)          ABIS="$2"; shift 2 ;;
        --debug)        BUILD_TYPE="Debug"; NATIVE_ARGS+=(--debug); shift ;;
        --release)      BUILD_TYPE="Release"; shift ;;
        --fast-release) BUILD_TYPE="Release"; NATIVE_ARGS+=(--fast-release); shift ;;
        --standalone)   NATIVE_ARGS+=(--standalone); shift ;;
        --install)      DO_INSTALL=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--abi arm64-v8a[,x86_64]] [--debug|--release|--fast-release] [--standalone] [--install]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# 1. Fetch SDL2 source tarball if android/sdl2 is missing
if [[ ! -f "$SDL2_DIR/CMakeLists.txt" ]]; then
    echo "==> Downloading SDL2 ${SDL2_VERSION} source into $SDL2_DIR"
    mkdir -p "$SCRIPT_DIR/build"
    TARBALL="$SCRIPT_DIR/build/SDL2-${SDL2_VERSION}.tar.gz"
    URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz"
    if command -v curl >/dev/null 2>&1; then
        curl -fL "$URL" -o "$TARBALL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$TARBALL" "$URL"
    else
        echo "error: curl or wget required to download SDL2 (or place SDL2 source at $SDL2_DIR)." >&2
        exit 1
    fi
    rm -rf "$SDL2_DIR"
    mkdir -p "$SDL2_DIR"
    tar -xzf "$TARBALL" --strip-components=1 -C "$SDL2_DIR"
fi

# 2. Build native libraries (libSDL2.so + libbof4.so)
SDL2_DIR="$SDL2_DIR" bash "$SCRIPT_DIR/build-native.sh" --abi "$ABIS" "${NATIVE_ARGS[@]}"

# 3. Build Android APK with Gradle
if [[ -x "$SCRIPT_DIR/gradlew" ]]; then
    GRADLE="$SCRIPT_DIR/gradlew"
elif command -v gradle >/dev/null 2>&1; then
    GRADLE="gradle"
else
    echo "error: neither android/gradlew nor system 'gradle' found." >&2
    echo "Install Gradle 8.x (or open android/ in Android Studio) to package the APK." >&2
    exit 1
fi

echo "==> Packaging Android APK (assemble${BUILD_TYPE}, ABIs: $ABIS)"
(
    cd "$SCRIPT_DIR"
    "$GRADLE" "assemble${BUILD_TYPE}" -Pbof4.abis="$ABIS"
)

LOWER_TYPE="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
APK_SRC="$SCRIPT_DIR/app/build/outputs/apk/$LOWER_TYPE/app-$LOWER_TYPE.apk"
if [[ ! -f "$APK_SRC" ]]; then
    APK_SRC="$SCRIPT_DIR/app/build/outputs/apk/$LOWER_TYPE/app-$LOWER_TYPE-unsigned.apk"
fi
APK_OUT="$SCRIPT_DIR/bof4-android-$LOWER_TYPE.apk"
if [[ -f "$APK_SRC" ]]; then
    cp -f "$APK_SRC" "$APK_OUT"
    echo "==> APK ready: $APK_OUT"
fi

if [[ "$DO_INSTALL" == "1" ]]; then
    command -v adb >/dev/null 2>&1 || { echo "error: adb not found on PATH" >&2; exit 1; }
    echo "==> Installing APK via adb"
    adb install -r "$APK_OUT"
fi
