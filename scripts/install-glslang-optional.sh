#!/usr/bin/env bash
# OPTIONAL/UNTESTED independent glslang CLI install; Shaderc bundles its own glslang.
set -Eeuo pipefail
[[ $(uname -s) == SunOS && $(id -u) == 0 ]] || { echo 'Requires sudo on Solaris.' >&2; exit 2; }
case "$(uname -p)" in sparc*) libdir=sparcv9;; i386|i86pc|amd64|x86_64) libdir=amd64;; *) exit 2;; esac
VERSION=13.1.1
PREFIX=${GLSLANG_PREFIX:-/opt/glslang-$VERSION}
WORK=${GLSLANG_WORK:-/var/tmp/glslang-solaris-$VERSION}
JOBS=${JOBS:-8}
mkdir -p "$WORK"
if [[ ! -d "$WORK/glslang/.git" ]]; then
 git clone --depth 1 --branch "$VERSION" https://github.com/KhronosGroup/glslang.git "$WORK/glslang"
fi
cmake -S "$WORK/glslang" -B "$WORK/build" -G Ninja \
 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
 -DCMAKE_INSTALL_LIBDIR="lib/$libdir" \
 -DCMAKE_C_COMPILER=/usr/gcc/15/bin/gcc -DCMAKE_CXX_COMPILER=/usr/gcc/15/bin/g++ \
 -DCMAKE_C_FLAGS='-m64 -D__EXTENSIONS__' -DCMAKE_CXX_FLAGS='-m64 -D__EXTENSIONS__' \
 -DBUILD_TESTING=OFF -DENABLE_OPT=OFF -DENABLE_PCH=OFF
cmake --build "$WORK/build" --parallel "$JOBS"
cmake --install "$WORK/build"
echo "glslang installed to $PREFIX (unverified Solaris build path)"
