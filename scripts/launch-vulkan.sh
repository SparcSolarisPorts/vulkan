#!/usr/bin/env bash
# Run arbitrary Vulkan programs against isolated /opt Lavapipe installation.
set -Eeuo pipefail
(( $# > 0 )) || { echo "Usage: $0 command [args...]" >&2; exit 2; }
VK_PREFIX=${VK_PREFIX:-/opt/vulkan-1.3.250}
MESA_PREFIX=${MESA_PREFIX:-/opt/mesa-lavapipe-21.3.8-wsi}
case "$(uname -p)" in
 sparc*) libdir=sparcv9;;
 i386|i86pc|amd64|x86_64) libdir=amd64;;
 *) echo 'Unsupported CPU'; exit 2;;
esac
if [[ -z ${VK_DRIVER_FILES:-} && -z ${VK_ICD_FILENAMES:-} ]]; then
  icd=$(find "$MESA_PREFIX/share/vulkan/icd.d" -name '*lvp*.json' -type f -print -quit 2>/dev/null || :)
  [[ -n "$icd" ]] || { echo "No Lavapipe ICD in $MESA_PREFIX" >&2; exit 2; }
  export VK_DRIVER_FILES="$icd"
fi
export LD_LIBRARY_PATH_64="$VK_PREFIX/lib/$libdir:$MESA_PREFIX/lib/$libdir:/usr/llvm/13/lib/$libdir:/usr/lib/xorg/$libdir${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
exec "$@"
