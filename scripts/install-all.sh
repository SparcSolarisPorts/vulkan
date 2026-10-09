#!/usr/bin/env bash
# Install a side-by-side Vulkan software stack under /opt, no system takeover.
# GCC 15/LLVM 13 Solaris 11.4 SPARC verified for loader/Mesa; x86 experimental.
set -Eeuo pipefail
umask 022
BASE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export VK_PREFIX=${VK_PREFIX:-/opt/vulkan-1.3.250}
export MESA_PREFIX=${MESA_PREFIX:-/opt/mesa-lavapipe-21.3.8-wsi}
export SHADERC_PREFIX=${SHADERC_PREFIX:-/opt/shaderc-2025.4}
export APP_PREFIX=${APP_PREFIX:-/opt/vk-rotating-block}
export JOBS=${JOBS:-8}
WANT_LOADER=1 WANT_MESA=1 WANT_DEMO=1 WANT_SHADERC=1
SOURCE=''
DRY_RUN=0
help() { cat <<'HELP'
Usage: sudo bash scripts/install-all.sh [options]
  --all                Loader + Mesa/Lavapipe + rotating cube + Shaderc (default)
  --core               Loader + Mesa/Lavapipe + cube, skip Shaderc
  --loader-only | --mesa-only | --shaderc-only | --demo-only
  --source DIR         Prepared Oracle-patched Mesa 21.3.8 source tree
  --jobs N             Number of Ninja build jobs (default 8)
  --dry-run            Print planned install commands; change nothing
  --help
Prefixes may be overridden with VK_PREFIX, MESA_PREFIX, SHADERC_PREFIX,
APP_PREFIX. An existing prefix is reused, not overwritten; inspect compatibility
before reusing. Mesa defaults to /opt/mesa-lavapipe-21.3.8-wsi to preserve the
older unpatched /opt/mesa-lavapipe-21.3.8 installation.

Requirements: Solaris 11.4 x86-64 or SPARCv9; GCC 15; LLVM 13; Meson/Ninja,
CMake, git, Python 3, pkg-config, Oracle Solaris Userland prepared Mesa source,
X11/XCB development modules. ARM has not been tested.
HELP
}
while (($#)); do
 case "$1" in
 --all) WANT_LOADER=1 WANT_MESA=1 WANT_DEMO=1 WANT_SHADERC=1;;
 --core) WANT_LOADER=1 WANT_MESA=1 WANT_DEMO=1 WANT_SHADERC=0;;
 --loader-only) WANT_LOADER=1 WANT_MESA=0 WANT_DEMO=0 WANT_SHADERC=0;;
 --mesa-only) WANT_LOADER=0 WANT_MESA=1 WANT_DEMO=0 WANT_SHADERC=0;;
 --shaderc-only) WANT_LOADER=0 WANT_MESA=0 WANT_DEMO=0 WANT_SHADERC=1;;
 --demo-only) WANT_LOADER=0 WANT_MESA=0 WANT_DEMO=1 WANT_SHADERC=0;;
 --source) shift; (($#)) || { help >&2; exit 2; }; SOURCE=$1;;
 --jobs) shift; (($#)) && [[ $1 =~ ^[1-9][0-9]*$ ]] || { help >&2; exit 2; }; JOBS=$1; export JOBS;;
 --dry-run) DRY_RUN=1;;
 --help|-h) help; exit 0;;
 *) echo "Invalid argument: $1" >&2; help >&2; exit 2;;
 esac; shift
done
[[ $(uname -s) == SunOS ]] || { echo 'This installer requires Solaris (SunOS).' >&2; exit 2; }
case "$(uname -p)" in
  sparc*) LIBDIR_NAME=sparcv9;;
  i386|i86pc|amd64|x86_64) LIBDIR_NAME=amd64; echo 'NOTE: Solaris x86 support is experimental, not validated by the SPARC screenshots.';;
  *) echo "Unsupported CPU $(uname -p); ARM is untested." >&2; exit 2;;
esac
if (( ! DRY_RUN )); then
 [[ $(id -u) == 0 ]] || { echo 'Installer requires sudo/root; demos should be run without sudo.' >&2; exit 2; }
fi
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; ((DRY_RUN)) || "$@"; }
if ((WANT_LOADER)); then
 if [[ -f "$VK_PREFIX/include/vulkan/vulkan.h" && -f "$VK_PREFIX/lib/$LIBDIR_NAME/libvulkan.so.1" ]]; then
    echo "REUSE existing Vulkan loader: $VK_PREFIX (not rebuilt)"
 else
    run bash "$BASE/scripts/install-vulkan-loader.sh"
 fi
fi
if ((WANT_MESA)); then
 if [[ -f "$MESA_PREFIX/lib/$LIBDIR_NAME/libvulkan_lvp.so" ]]; then
   echo "REUSE existing Mesa/Lavapipe: $MESA_PREFIX (not rebuilt)"
 else
   opts=(--jobs "$JOBS")
   [[ -z "$SOURCE" ]] || opts+=(--source "$SOURCE")
   run bash "$BASE/scripts/install-mesa-lavapipe.sh" "${opts[@]}"
 fi
fi
# Build demo before Shaderc: Shaderc is not required for Vulkan offscreen or WSI demo.
if ((WANT_DEMO)); then
 run bash "$BASE/demo/build.sh"
fi
if ((WANT_SHADERC)); then
 if [[ -x "$SHADERC_PREFIX/bin/glslc" ]]; then
   echo "REUSE existing Shaderc: $SHADERC_PREFIX (not rebuilt)"
 else
   run bash "$BASE/scripts/install-shaderc.sh"
 fi
fi
cat <<END
Installer stages complete (or dry-run).
Loader:  $VK_PREFIX
Mesa:    $MESA_PREFIX
Shaderc: $SHADERC_PREFIX
Demo:    $APP_PREFIX

As NORMAL graphical user (no sudo):
  MESA_PREFIX="$MESA_PREFIX" $BASE/demo/run.sh --api 1.2 --probe
  MESA_PREFIX="$MESA_PREFIX" $BASE/demo/run.sh --api 1.2 --wsi-probe
  MESA_PREFIX="$MESA_PREFIX" $BASE/demo/run.sh --api 1.2 --present wsi
  bash $BASE/tests/smoke-test.sh
END
