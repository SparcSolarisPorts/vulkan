#!/usr/bin/env bash
# Optional Vulkan-Tools build (vkcube / vulkaninfo) for Solaris 11.4.
# Experimental: not part of the tested /opt stack, may require portability fixes.
set -Eeuo pipefail
[[ $(uname -s) == SunOS && $(id -u) == 0 ]] || { echo 'Solaris and sudo/root required' >&2; exit 2; }
case "$(uname -p)" in sparc*) libdir=sparcv9;; i386|i86pc|amd64|x86_64) libdir=amd64;; *) exit 2;; esac
VERSION=1.3.250
PREFIX=${TOOLS_PREFIX:-/opt/vulkan-tools-$VERSION}
VK_PREFIX=${VK_PREFIX:-/opt/vulkan-$VERSION}
GLSLANG_PREFIX=${GLSLANG_PREFIX:-/opt/glslang-13.1.1}
WORK=${TOOLS_WORK:-/var/tmp/vulkan-tools-solaris-$VERSION}
JOBS=${JOBS:-8}
[[ -f "$VK_PREFIX/include/vulkan/vulkan.h" ]] || { echo 'Install Vulkan-Headers/Loader first' >&2; exit 2; }
mkdir -p "$WORK"
if [[ ! -d "$WORK/Vulkan-Tools/.git" ]]; then
  git clone --depth 1 --branch "v$VERSION" https://github.com/KhronosGroup/Vulkan-Tools.git "$WORK/Vulkan-Tools"
fi
export PKG_CONFIG_PATH="$VK_PREFIX/lib/$libdir/pkgconfig:/usr/lib/$libdir/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
cmake -S "$WORK/Vulkan-Tools" -B "$WORK/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR="lib/$libdir" \
  -DCMAKE_INSTALL_RPATH="$VK_PREFIX/lib/$libdir" \
  -DCMAKE_C_COMPILER=/usr/gcc/15/bin/gcc \
  -DCMAKE_CXX_COMPILER=/usr/gcc/15/bin/g++ \
  -DCMAKE_C_FLAGS='-m64 -D__EXTENSIONS__' \
  -DCMAKE_CXX_FLAGS='-m64 -D__EXTENSIONS__' \
  -DCMAKE_PREFIX_PATH="$VK_PREFIX;$GLSLANG_PREFIX" \
  -DVULKAN_HEADERS_INSTALL_DIR="$VK_PREFIX" \
  -DVULKAN_LOADER_INSTALL_DIR="$VK_PREFIX" \
  -DGLSLANG_INSTALL_DIR="$GLSLANG_PREFIX" \
  -DBUILD_CUBE=ON -DBUILD_VULKANINFO=ON -DBUILD_ICD=OFF \
  -DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=ON \
  -DBUILD_WSI_WAYLAND_SUPPORT=OFF -DCUBE_WSI_SELECTION=XLIB
cmake --build "$WORK/build" --parallel "$JOBS"
cmake --install "$WORK/build"
echo "Experimental Vulkan-Tools installation completed under $PREFIX"
echo "Run via: bash scripts/launch-vulkan.sh $PREFIX/bin/vkcube"
