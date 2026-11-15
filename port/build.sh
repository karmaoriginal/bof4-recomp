#!/bin/sh
# Build the port, optimized. A first argument `debug` adds debug info
# (-debug). Set BOF4_OPT=none for an unoptimized build; other flags pass
# through, e.g. ./build.sh -sanitize:address
# BOF4_ARCH picks the CPU target. The default, native, uses everything the
# build machine's CPU has (AVX2, AVX-512 where present), so the binary may
# not start on another machine. For a build to hand to others use
# BOF4_ARCH=x86-64-v3 (AVX2: Intel from 2013, AMD from 2015) or
# BOF4_ARCH=x86-64 (any 64-bit x86).
# PS_RECOMP names the ps-recomp checkout (the emulated PS1 in psx, and the
# shared core: trace, capture, PNG, environment); the default is the
# repository root's ps-recomp/.
# BOF4_PATCH_PS (default 1 when patches/ps-recomp-android.patch is present and
# PS_RECOMP is unset) stages a patched copy in port/.ps-recomp/ for low-latency
# post-sleep input polling, repeat-frame upload skipping, SIMD conversion, and
# full-screen touch controls without touching the ps-recomp submodule.
set -e
cd "$(dirname "$0")"
debug=
if [ "${1:-}" = debug ]; then
	debug=-debug
	shift
fi
ps_dir="${PS_RECOMP:-../ps-recomp}"
patch_define=
if [ -z "${PS_RECOMP:-}" ] && [ "${BOF4_PATCH_PS:-1}" = "1" ] && [ -f ../patches/ps-recomp-android.patch ] && command -v patch >/dev/null 2>&1; then
	stage=".ps-recomp"
	rm -rf "$stage"
	cp -a ../ps-recomp "$stage"
	rm -rf "$stage/.git"
	patch -d "$stage" -p1 -s < ../patches/ps-recomp-android.patch
	ps_dir="$stage"
	patch_define="-define:PS_ANDROID_PATCH=true"
fi
odin build src -out:bof4 -use-separate-modules $debug -o:"${BOF4_OPT:-speed}" -microarch:"${BOF4_ARCH:-native}" -collection:ps="$ps_dir" -define:ENV_PREFIX=BOF4_ $patch_define "$@"
