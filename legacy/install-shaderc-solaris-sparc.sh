#!/usr/bin/env bash
# Build Google Shaderc for Oracle Solaris 11.4 / SPARCv9 (GCC 15).
# Uses version-pinned upstream dependencies and installs only under /opt.
# This is a porting/build attempt, not a guaranteed Solaris-supported build.
set -Eeuo pipefail

VERSION="2025.4"
PREFIX="/opt/shaderc-${VERSION}"
WORK="/var/tmp/shaderc-solaris-${VERSION}"
SRC="$WORK/shaderc"
BUILD="$WORK/build"
JOBS="${JOBS:-8}"
MODE=full

for arg in "$@"; do
  case "$arg" in
    --configure-only) MODE=configure ;;
    --build-only) MODE=build ;;
    --help|-h)
      cat <<HELP
Usage: sudo bash $0 [--configure-only | --build-only]

  --configure-only  Fetch matching sources and configure without compiling.
  --build-only      Continue compilation/install from a configured build tree.
  (no option)       Fetch, configure, build and install Shaderc.

Installs glslc, libshaderc_shared.so and headers under ${PREFIX}.
Build logs: ${WORK}/configure.log, ${WORK}/build.log, ${WORK}/install.log
HELP
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ $(id -u) -eq 0 ]] || { echo 'Run with sudo bash ...' >&2; exit 1; }
export PATH="/usr/gcc/15/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:${PATH}"
export CC=/usr/gcc/15/bin/gcc
export CXX=/usr/gcc/15/bin/g++
export PYTHON=/usr/bin/python3
export CMAKE_PREFIX_PATH="/opt/vulkan-1.3.250${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

for cmd in git cmake ninja python3; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
[[ -x "$CC" && -x "$CXX" ]] || { echo 'Missing GCC 15 compiler' >&2; exit 1; }
mkdir -p "$WORK"
trap 'rc=$?; echo "FAILED at line $LINENO (exit $rc); logs in $WORK" >&2' ERR

echo "== Shaderc v${VERSION} on Solaris SPARC =="
echo "  prefix: $PREFIX"
echo "  source: $SRC"
echo "  build: $BUILD"
echo "  jobs: $JOBS"
echo '  NOTE: does not alter existing Mesa, Vulkan, SSH or login defaults.'

if [[ "$MODE" != build ]]; then
  if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
    echo '== Cloning Shaderc =='
    git clone --branch "v$VERSION" --depth 1 \
      https://github.com/google/shaderc.git "$SRC" \
      2>&1 | tee "$WORK/source.log"
  else
    echo '== Reusing existing Shaderc source =='
  fi

  # The official sync tool checks out matching glslang, SPIRV-Tools and
  # SPIRV-Headers revisions. Do not substitute arbitrary dependency versions.
  if [[ ! -f "$SRC/third_party/spirv-tools/CMakeLists.txt" || \
        ! -f "$SRC/third_party/glslang/CMakeLists.txt" || \
        ! -f "$SRC/third_party/spirv-headers/CMakeLists.txt" ]]; then
    echo '== Fetching version-matched Shaderc dependencies =='
    (cd "$SRC" && python3 utils/git-sync-deps) \
      2>&1 | tee "$WORK/dependencies.log"
  fi

  echo '== Configuring Shaderc =='
  cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib/sparcv9 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS='-m64 -D__EXTENSIONS__' \
    -DCMAKE_CXX_FLAGS='-m64 -D__EXTENSIONS__' \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_RPATH="$PREFIX/lib/sparcv9" \
    -DCMAKE_EXE_LINKER_FLAGS='-m64 -Wl,-zgnu-version-script-compat -Wl,-z,rescan-now' \
    -DCMAKE_SHARED_LINKER_FLAGS='-m64 -Wl,-zgnu-version-script-compat -Wl,-z,rescan-now' \
    -DPython_EXECUTABLE=/usr/bin/python3 \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
    -DSPIRV_WERROR=OFF \
    -DSPIRV_SKIP_TESTS=ON \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DSHADERC_ENABLE_WGSL_OUTPUT=OFF \
    2>&1 | tee "$WORK/configure.log"
  if [[ "$MODE" == configure ]]; then
    echo "Configured successfully. Next: sudo bash $0 --build-only"
    exit 0
  fi
fi

[[ -f "$BUILD/build.ninja" ]] || { echo 'No configured Ninja build tree. Run --configure-only first.' >&2; exit 1; }
echo '== Building Shaderc shared library and glslc =='
cmake --build "$BUILD" --parallel "$JOBS" \
  2>&1 | tee "$WORK/build.log"
echo '== Installing Shaderc =='
cmake --install "$BUILD" 2>&1 | tee "$WORK/install.log"

# Smoke-test the GLSL->SPIR-V compiler independently of a Vulkan ICD.
echo '== Testing glslc =='
if [[ -x "$PREFIX/bin/glslc" ]]; then
  cat > "$WORK/triangle.vert" <<'GLSL'
#version 450
vec2 positions[3] = vec2[](vec2(0.0, -0.5), vec2(0.5, 0.5), vec2(-0.5, 0.5));
void main() { gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0); }
GLSL
  "$PREFIX/bin/glslc" --target-env=vulkan1.2 -fshader-stage=vert \
    "$WORK/triangle.vert" -o "$WORK/triangle.vert.spv"
  test -s "$WORK/triangle.vert.spv"
  echo "SPIR-V shader generated: $WORK/triangle.vert.spv"
else
  echo 'WARNING: glslc was not installed at the expected path'
fi

echo '== Installed library files =='
find "$PREFIX/lib/sparcv9" -maxdepth 1 \( -name '*shaderc*' -o -name '*SPIRV*' \) -print
cat <<FINISHED

SUCCESS: Shaderc build and install completed.
For LWJGL Shaderc native binding, try:
  -Dorg.lwjgl.shaderc.libname=$PREFIX/lib/sparcv9/libshaderc_shared.so

Keep in mind: Minecraft Vulkan mods may also need native LWJGL,
GLFW, VMA, and SPIRV-Cross ports for Solaris/SPARC.
FINISHED
