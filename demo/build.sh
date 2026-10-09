#!/usr/bin/env bash
# Compile and install the SPARC Vulkan demo under /opt. No changes to /usr.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VK_PREFIX=${VK_PREFIX:-/opt/vulkan-1.3.250}
APP_PREFIX=${APP_PREFIX:-/opt/vk-rotating-block}
CC=${CC:-/usr/gcc/15/bin/gcc}

if [[ ! -f "$VK_PREFIX/include/vulkan/vulkan.h" ]]; then
  echo "ERROR: Vulkan headers missing from $VK_PREFIX/include/vulkan/vulkan.h" >&2
  echo "Check where the Vulkan header installer placed the header." >&2
  exit 2
fi
case "$(uname -p)" in
  sparc*) LIBDIR_NAME=sparcv9 ;;
  i386|i86pc|amd64|x86_64) LIBDIR_NAME=amd64 ;;
  *) echo "Unsupported CPU $(uname -p)" >&2; exit 2 ;;
esac
if [[ ! -f "$VK_PREFIX/lib/$LIBDIR_NAME/libvulkan.so" ]]; then
  echo "ERROR: Vulkan loader missing at $VK_PREFIX/lib/$LIBDIR_NAME/libvulkan.so" >&2
  exit 2
fi
if [[ ! -x "$CC" ]]; then
  echo "ERROR: GCC 15 compiler not found at $CC" >&2
  exit 2
fi
mkdir -p "$HERE/build"
echo "== Building Vulkan/X11 rotating cube on Solaris (SPARC/x86) =="
"$CC" -m64 -std=c11 -O2 -D__EXTENSIONS__ -Wall -Wextra \
  -I"$VK_PREFIX/include" \
  "$HERE/src/vk_rotating_block.c" -o "$HERE/build/vk-rotating-block" \
  -L"$VK_PREFIX/lib/$LIBDIR_NAME" -Wl,-R"$VK_PREFIX/lib/$LIBDIR_NAME" \
  -lvulkan -lX11 -lm

echo "== Installing to $APP_PREFIX =="
mkdir -p "$APP_PREFIX/bin" "$APP_PREFIX/share/doc/vk-rotating-block"
cp "$HERE/build/vk-rotating-block" "$APP_PREFIX/bin/vk-rotating-block"
cp "$HERE/run.sh" "$APP_PREFIX/bin/run.sh"
cp "$HERE/test-modes.sh" "$APP_PREFIX/bin/test-modes.sh"
cp "$HERE/README.md" "$APP_PREFIX/share/doc/vk-rotating-block/README.md"
chmod 755 "$APP_PREFIX/bin/vk-rotating-block" "$APP_PREFIX/bin/run.sh" "$APP_PREFIX/bin/test-modes.sh"
echo "Installed: $APP_PREFIX/bin/vk-rotating-block"
echo "Run: $APP_PREFIX/bin/run.sh"
echo "Probe without X11: $APP_PREFIX/bin/run.sh --probe"
