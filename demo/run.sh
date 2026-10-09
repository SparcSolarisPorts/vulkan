#!/usr/bin/env bash
# Launch installed Lavapipe Vulkan demo on Solaris/SPARC, without modifying shell startup files.
set -euo pipefail
VK_PREFIX=${VK_PREFIX:-/opt/vulkan-1.3.250}
MESA_PREFIX=${MESA_PREFIX:-/opt/mesa-lavapipe-21.3.8-wsi}
APP_PREFIX=${APP_PREFIX:-/opt/vk-rotating-block}

# Preserve explicit driver selection before sourcing env scripts (which may reset it).
CALLER_VK_DRIVER_FILES=${VK_DRIVER_FILES:-}
CALLER_VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-}
case "$(uname -p)" in
  sparc*) LIBDIR_NAME=sparcv9 ;;
  i386|i86pc|amd64|x86_64) LIBDIR_NAME=amd64 ;;
  *) echo "Unsupported CPU $(uname -p)" >&2; exit 2 ;;
esac
if [[ -f "$VK_PREFIX/bin/vulkan-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$VK_PREFIX/bin/vulkan-env.sh"
fi
if [[ -f "$MESA_PREFIX/bin/lavapipe-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$MESA_PREFIX/bin/lavapipe-env.sh"
fi

[[ -z "$CALLER_VK_DRIVER_FILES" ]] || export VK_DRIVER_FILES="$CALLER_VK_DRIVER_FILES"
[[ -z "$CALLER_VK_ICD_FILENAMES" ]] || export VK_ICD_FILENAMES="$CALLER_VK_ICD_FILENAMES"
# Explicitly choose the /opt Vulkan loader on Solaris. Never change system libraries.
export LD_LIBRARY_PATH_64="$VK_PREFIX/lib/$LIBDIR_NAME:$MESA_PREFIX/lib/$LIBDIR_NAME:/usr/llvm/13/lib/$LIBDIR_NAME:/usr/lib/xorg/sparcv9${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"

# Use the ICD from the Lavapipe installation; never default to an unrelated GPU ICD.
if [[ -z "${VK_DRIVER_FILES:-}" && ( -z "${VK_ICD_FILENAMES:-}" || ! -f "$VK_ICD_FILENAMES" ) ]]; then
  ICD=$(find "$MESA_PREFIX" -type f \( -name '*lvp*icd*.json' -o -name '*lvp*.json' \) -print -quit 2>/dev/null || true)
  if [[ -z "$ICD" ]]; then
    echo "ERROR: No Lavapipe ICD JSON under $MESA_PREFIX" >&2
    echo "Did the Mesa + Lavapipe v6 installer successfully finish?" >&2
    exit 2
  fi
  export VK_ICD_FILENAMES="$ICD"
fi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -x "$DIR/vk-rotating-block" ]]; then
  EXE="$DIR/vk-rotating-block"
elif [[ -x "$APP_PREFIX/bin/vk-rotating-block" ]]; then
  EXE="$APP_PREFIX/bin/vk-rotating-block"
else
  echo "ERROR: Demo binary is missing. First run: sudo bash build.sh" >&2
  exit 2
fi

echo "Vulkan loader: $VK_PREFIX/lib/$LIBDIR_NAME/libvulkan.so.1"
echo "Lavapipe ICD:  ${VK_DRIVER_FILES:-${VK_ICD_FILENAMES:-system}}"
if [[ " ${*:-} " != *" --probe "* ]] || [[ " ${*:-} " == *" --wsi-probe "* ]] || [[ " ${*:-} " == *" --dri3-probe "* ]]; then
  export DISPLAY=${DISPLAY:-:0}
  echo "X11 display:   $DISPLAY"
fi
exec "$EXE" "$@"
