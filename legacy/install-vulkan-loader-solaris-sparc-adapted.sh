#!/usr/bin/env bash
# Vulkan Loader 1.3.250 for Oracle Solaris 11.4 / SPARC64.
# Adapted from the user's previously working SunOS port changes.
# Installs only under /opt/vulkan-1.3.250. NO system library replacement,
# NO changes to Mesa, login profiles, display services, or SSH.
# Upstream Solaris/SPARC build/runtime remain experimental.
set -Eeuo pipefail

VERSION=1.3.250
PREFIX="${PREFIX:-/opt/vulkan-$VERSION}"
WORK="${WORK:-/var/tmp/vulkan-loader-sparc-$VERSION}"
JOBS="${JOBS:-8}"
WITH_X11=1

usage() {
    echo "Usage: sudo bash $0 [--headless|--with-x11]"
    echo "  --with-x11  Enable XCB + Xlib WSI (default; useful for Lavapipe X11)"
    echo "  --headless  Disable XCB + Xlib WSI to minimize dependencies"
}
for arg in "$@"; do
    case "$arg" in
        --headless) WITH_X11=0 ;;
        --with-x11) WITH_X11=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ $(uname -s) != SunOS ]] || [[ $(uname -p) != sparc ]]; then
    echo "ERROR: run this on Solaris/SPARC, not $(uname -s)/$(uname -p)" >&2
    exit 2
fi
if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: please run with sudo bash $0" >&2
    exit 2
fi

export PATH="/usr/gcc/15/bin:/usr/gnu/bin:/usr/local/bin:/usr/bin:/usr/sbin:${PATH:-}"
export CC=/usr/gcc/15/bin/gcc
export CXX=/usr/gcc/15/bin/g++
# Prefer 64-bit SPARC pkg-config metadata for X11 dependencies.
export PKG_CONFIG_PATH="/usr/lib/sparcv9/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
for tool in git cmake python3 gmake pkg-config "$CC" "$CXX"; do
    command -v "$tool" >/dev/null || {
        echo "ERROR: missing build tool: $tool" >&2
        exit 3
    }
done

# Only optional WSI requires X11/XCB pkg-config dependencies.
if (( WITH_X11 )); then
    if ! pkg-config --exists x11 xcb; then
        echo 'ERROR: x11 and/or xcb pkg-config files are missing.' >&2
        echo 'Install X11 development libraries, or run again with --headless.' >&2
        exit 3
    fi
    XCB=ON; XLIB=ON
else
    XCB=OFF; XLIB=OFF
fi

HEADERS="$WORK/Vulkan-Headers"
LOADER="$WORK/Vulkan-Loader"
HEADER_BUILD="$WORK/headers-build"
LOADER_BUILD="$WORK/loader-build"
mkdir -p "$WORK"
LOG="$WORK/install.log"
exec > >(tee -a "$LOG") 2>&1
trap 'r=$?; echo "FAILED (exit $r, script line $LINENO). Read $LOG" >&2' ERR

echo "== Vulkan Loader $VERSION, Solaris/SPARC, GCC 15 =="
echo "Install prefix: $PREFIX"
echo "Work directory: $WORK"
echo "X11 support: $WITH_X11 (XCB=$XCB, XLIB=$XLIB)"
"$CC" --version | head -1
cmake --version | head -1

clone_tag() {
    local name="$1" dest="$2" want have
    if [[ -d "$dest/.git" ]]; then
        want=$(git -C "$dest" rev-parse "refs/tags/v$VERSION^{commit}") || {
            echo "ERROR: $dest lacks tag v$VERSION" >&2; exit 4;
        }
        have=$(git -C "$dest" rev-parse HEAD)
        [[ "$have" == "$want" ]] || {
            echo "ERROR: $dest not checked out at v$VERSION. Leave it untouched and inspect." >&2
            exit 4
        }
        echo "Reusing $dest at v$VERSION"
    else
        [[ ! -e "$dest" ]] || { echo "ERROR: $dest exists and is not a Git checkout" >&2; exit 4; }
        git clone --depth=1 --branch "v$VERSION" \
            "https://github.com/KhronosGroup/$name.git" "$dest"
    fi
}
clone_tag Vulkan-Headers "$HEADERS"
clone_tag Vulkan-Loader "$LOADER"

# The Khronos loader specifically uses matching installed Vulkan-Headers.
# No need for Vulkan-ValidationLayers, Vulkan-Tools or an ICD at this stage.
echo '== Install Vulkan-Headers =='
cmake -S "$HEADERS" -B "$HEADER_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib/sparcv9 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_C_FLAGS='-m64 -D__EXTENSIONS__' \
    -DBUILD_TESTS=OFF
cmake --build "$HEADER_BUILD" --parallel "$JOBS"
cmake --install "$HEADER_BUILD"

# User-supplied port, adapted for the v1.3.250 source structure.
# In this tag, elseif(UNIX AND NOT APPLE) already selects X11 WSI and
# loader_linux.c for SunOS. The older patch's Linux|BSD|... replacements
# are therefore unnecessary; retain the more general upstream conditions.
echo '== Apply idempotent Solaris compatibility changes =='
python3 - "$LOADER" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])

def replace_once(path, old, new, description):
    p = root / path
    s = p.read_text()
    if new in s:
        print('Already patched:', description)
        return
    if s.count(old) != 1:
        raise SystemExit(f'ERROR: expected one anchor for {description} in {p}; found {s.count(old)}')
    p.write_text(s.replace(old, new, 1))
    print('Applied:', description)

replace_once(
    'CMakeLists.txt',
    'add_library(loader_common_options INTERFACE)\n',
    'add_library(loader_common_options INTERFACE)\n'
    'if(CMAKE_SYSTEM_NAME STREQUAL "SunOS")\n'
    '    target_compile_definitions(loader_common_options INTERFACE _POSIX_C_SOURCE=200809L __EXTENSIONS__)\n'
    'endif()\n',
    'SunOS POSIX/extension macros (user patch)'
)
replace_once(
    'loader/vk_loader_platform.h',
    'defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)',
    'defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__) || defined(__sun)',
    'include SunOS in COMMON_UNIX_PLATFORMS (user patch)'
)
replace_once(
    'loader/vk_loader_platform.h',
    '#elif defined(__APPLE__)\n#include <libproc.h>\n',
    '#elif defined(__sun)\n'
    'static inline char *loader_platform_executable_path(char *buffer, size_t size) {\n'
    '    if (buffer == NULL || size < 2) return NULL;\n'
    '    ssize_t count = readlink("/proc/self/path/a.out", buffer, size - 1);\n'
    '    if (count <= 0 || (size_t)count >= size) return NULL;\n'
    "    buffer[count] = '\\0';\n"
    '    return buffer;\n'
    '}\n'
    '#elif defined(__APPLE__)\n#include <libproc.h>\n',
    'Solaris /proc/self/path/a.out executable path (user patch, bounds-safe)'
)
replace_once(
    'loader/loader_environment.c',
    '#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)',
    '#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__sun)',
    'disable environment-driven ICD injection in privileged processes'
)
# Assert the tag already has UNIX/SunOS code paths for WSI and loader_linux.c.
cm = (root / 'CMakeLists.txt').read_text()
ld = (root / 'loader/CMakeLists.txt').read_text()
if 'elseif(UNIX AND NOT APPLE)' not in cm or 'elseif(UNIX AND NOT APPLE)' not in ld:
    raise SystemExit('ERROR: upstream UNIX CMake conditions changed; check SunOS source selection')
print('Upstream UNIX CMake branches already cover SunOS, no other edits required.')
PY

# Reconfiguring after another run is safe: the patcher is idempotent.
# Use the C fallback rather than unsupported SPARC assembly. In this
# upstream version the C fallback uses tail-call optimizations: test it.
echo '== Configure Vulkan Loader =='
cmake -S "$LOADER" -B "$LOADER_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib/sparcv9 \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DVulkanHeaders_DIR="$PREFIX/share/cmake/VulkanHeaders" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS='-m64 -D_POSIX_C_SOURCE=200809L -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS' \
    -DCMAKE_CXX_FLAGS='-m64 -D_POSIX_C_SOURCE=200809L -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS' \
    -DBUILD_TESTS=OFF \
    -DBUILD_WSI_XCB_SUPPORT="$XCB" \
    -DBUILD_WSI_XLIB_SUPPORT="$XLIB" \
    -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
    -DBUILD_WSI_DIRECTFB_SUPPORT=OFF \
    -DUSE_GAS=OFF \
    -DENABLE_WERROR=OFF \
    -DFALLBACK_DATA_DIRS="$PREFIX/share:/usr/local/share:/usr/share" \
    -DSYSCONFDIR="$PREFIX/etc"

echo '== Build Vulkan Loader =='
cmake --build "$LOADER_BUILD" --parallel "$JOBS"
echo '== Install Vulkan Loader =='
cmake --install "$LOADER_BUILD"

LIBDIR="$PREFIX/lib/sparcv9"
[[ -f "$LIBDIR/libvulkan.so.1" ]] || {
    echo "ERROR: expected $LIBDIR/libvulkan.so.1 after installation" >&2
    exit 5
}

# A smoke test that does not need a Vulkan ICD: the loader should be able
# to return its Vulkan instance API version and enumerate global extensions.
cat > "$WORK/vulkan-smoke.c" <<'C'
#include <stdio.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
int main(void) {
    uint32_t version = 0;
    VkResult r = vkEnumerateInstanceVersion(&version);
    printf("vkEnumerateInstanceVersion: %d; Vulkan %u.%u.%u\n",
           r, VK_API_VERSION_MAJOR(version), VK_API_VERSION_MINOR(version),
           VK_API_VERSION_PATCH(version));
    if (r != VK_SUCCESS) return 1;
    uint32_t count = 0;
    r = vkEnumerateInstanceExtensionProperties(NULL, &count, NULL);
    printf("vkEnumerateInstanceExtensionProperties: %d; count=%u\n", r, count);
    return (r == VK_SUCCESS) ? 0 : 2;
}
C
"$CC" -m64 -D__EXTENSIONS__ -I"$PREFIX/include" \
    "$WORK/vulkan-smoke.c" -L"$LIBDIR" \
    -Wl,-R,"$LIBDIR" -lvulkan -o "$WORK/vulkan-smoke"

mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/vulkan-env.sh" <<EOF
# Source this file (do not execute) for an opt-only Vulkan environment.
VK_PREFIX="$PREFIX"
export VK_PREFIX
export LD_LIBRARY_PATH_64="\$VK_PREFIX/lib/sparcv9\${LD_LIBRARY_PATH_64:+:\$LD_LIBRARY_PATH_64}"
export PKG_CONFIG_PATH="\$VK_PREFIX/lib/sparcv9/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="\$VK_PREFIX\${CMAKE_PREFIX_PATH:+:\$CMAKE_PREFIX_PATH}"
# When Lavapipe has been built, set VK_DRIVER_FILES to its actual ICD JSON.
EOF

printf '\n== Installed Vulkan libraries ==\n'
ls -l "$LIBDIR"/libvulkan.so*
echo '== Smoke test (no Lavapipe driver yet) =='
"$WORK/vulkan-smoke"
printf '\nSUCCESS: Vulkan loader in %s\n' "$PREFIX"
echo "To use from your shell: . $PREFIX/bin/vulkan-env.sh"
echo "Smoke test: $WORK/vulkan-smoke"
echo "Log: $LOG"
echo 'System Mesa, system Vulkan and SSH configuration were not modified.'
echo 'NEXT: build Mesa Vulkan swrast (Lavapipe), without Nouveau.'
