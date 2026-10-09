#!/usr/bin/env bash
# Mesa 21.3.8 / Solaris SPARC: experiment with no-FD software X11 swapchain images.
# Safe: patches an Oracle-prepared source checkout and builds a candidate ICD only.
# Does NOT install or overwrite the working /opt Mesa/Lavapipe ICD or system libraries.
#
#   sudo bash test-mesa-lavapipe-solaris-wsi-no-fd.sh --build
#   bash      test-mesa-lavapipe-solaris-wsi-no-fd.sh --test
set -Eeuo pipefail

WORK=${WORK:-/var/tmp/mesa-solaris-21.3.8-work}
SRC=${SRC:-$WORK/solaris-userland/components/x11/lib/mesa/mesa-21.3.8}
BUILD=${BUILD:-$WORK/build-mesa-lavapipe-x11-v4}
PREFIX=${PREFIX:-/opt/mesa-lavapipe-21.3.8}
VK_PREFIX=${VK_PREFIX:-/opt/vulkan-1.3.250}
TARGET=src/gallium/targets/lavapipe/libvulkan_lvp.so
LIB="$BUILD/$TARGET"
MANIFEST="$WORK/lvp-wsi-no-fd-test.json"
LOG="$WORK/lvp-wsi-no-fd-build.log"
MODE=${1:---help}

usage() {
  cat <<'HELP'
Usage:
  sudo bash test-mesa-lavapipe-solaris-wsi-no-fd.sh --build [N_JOBS]
  bash test-mesa-lavapipe-solaris-wsi-no-fd.sh --test

--build: Patch ONLY the prepared Mesa 21.3.8 wsi_common_drm.c software WSI
         memory export chain. Rebuild only the Lavapipe ICD with Ninja. Create
         a separate manifest that loads the rebuilt ICD from the build tree.
         Never modifies the installed /opt prefix, system Mesa, or X11.
--test:  Run the rotating-block Xlib swapchain probe against the candidate ICD
         as the ordinary graphical desktop user (without sudo).

Hypothesis: without DRI3, Mesa 21.3.8 disables MIT-SHM presentation, but its
software X11 image allocator still asks for an exportable OPAQUE_FD allocation.
On Solaris this may fail and produce VK_ERROR_OUT_OF_DEVICE_MEMORY (-2).
This patch skips FD export ONLY when software WSI is used without alloc_shm.
This is an EXPERIMENT; a successful vkCreateSwapchainKHR must be verified.
HELP
}

case "$MODE" in
  --build)
    [[ $(id -u) -eq 0 ]] || { echo 'Use sudo for --build (Mesa tree may be root-owned).' >&2; exit 2; }
    [[ $(uname -s) == SunOS ]] || { echo 'Build mode is for Solaris.' >&2; exit 2; }
    [[ -f "$SRC/src/vulkan/wsi/wsi_common_drm.c" ]] || { echo "Source missing: $SRC" >&2; exit 2; }
    [[ -f "$BUILD/build.ninja" ]] || { echo "Existing Ninja build missing: $BUILD" >&2; exit 2; }
    [[ -f "$PREFIX/share/vulkan/icd.d/lvp_icd.sun4v.json" ]] || { echo 'Original installed ICD manifest not found.' >&2; exit 2; }

    export PATH="/usr/gcc/15/bin:/usr/llvm/13/bin:/usr/gnu/bin:/usr/local/bin:/usr/bin:/usr/sbin:${PATH:-}"
    export PKG_CONFIG_PATH="$VK_PREFIX/lib/sparcv9/pkgconfig:/usr/llvm/13/lib/sparcv9/pkgconfig:/usr/lib/sparcv9/pkgconfig:/usr/lib/xorg/sparcv9/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH_64="/usr/llvm/13/lib/sparcv9:/usr/lib/xorg/sparcv9:${LD_LIBRARY_PATH_64:-}"
    JOBS=${2:-8}
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'Jobs must be a positive integer.' >&2; exit 2; }

    python3 - "$SRC/src/vulkan/wsi/wsi_common_drm.c" <<'PY'
from pathlib import Path
import re, shutil, sys
path = Path(sys.argv[1])
s = path.read_text(encoding='utf-8')
marker = '/* SOLARIS_LVP_SW_NO_FD_EXPORT_TEST */'
if marker in s:
    print('WSI no-FD patch already present; leaving source unchanged.')
    raise SystemExit(0)
# Narrowly scope the replacement to the specific dedicated-memory initializer
# in wsi_create_native_image, not to any other exported-memory allocation.
pattern = (r'(const\s+VkMemoryDedicatedAllocateInfo\s+memory_dedicated_info\s*=\s*\{)'
           r'(?P<body>.*?)'
           r'(\n\s*\};)')
match = re.search(pattern, s, flags=re.S)
if match is None:
    raise SystemExit('Unsupported WSI source: memory_dedicated_info initializer not found; unchanged.')
body = match.group('body')
needle = '.pNext = &memory_export_info,'
if body.count(needle) != 1:
    raise SystemExit('Unexpected memory_export_info initializer; unchanged.')
replacement = (marker + '\n      .pNext = '
               '(wsi->sw && alloc_shm == NULL) ? NULL : &memory_export_info,')
newbody = body.replace(needle, replacement)
result = s[:match.start('body')] + newbody + s[match.end('body'):]
backup = path.with_name(path.name + '.pre-solaris-no-fd-test.bak')
if not backup.exists():
    shutil.copy2(path, backup)
path.write_text(result, encoding='utf-8')
print('Patched:', path)
print('Backup: ', backup)
print('Software non-SHM images will now allocate regular host memory.')
PY

    echo "== Incremental Lavapipe rebuild: $TARGET =="
    echo "Build log: $LOG"
    if ! ninja -C "$BUILD" -j "$JOBS" "$TARGET" >"$LOG" 2>&1; then
      tail -n 100 "$LOG" >&2
      exit 1
    fi
    tail -n 20 "$LOG"
    [[ -f "$LIB" ]] || { echo "Candidate driver not generated: $LIB" >&2; exit 1; }

    python3 - "$PREFIX/share/vulkan/icd.d/lvp_icd.sun4v.json" "$LIB" "$MANIFEST" <<'PY'
import json, sys
orig, library, output = sys.argv[1:]
with open(orig, encoding='utf-8') as f:
    data = json.load(f)
if 'ICD' not in data or 'library_path' not in data['ICD']:
    raise SystemExit('Unexpected Vulkan ICD JSON schema')
data['ICD']['library_path'] = library
with open(output, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print('Test-only ICD manifest:', output)
print('Test-only Lavapipe DSO:', library)
PY
    chmod 644 "$MANIFEST"
    echo 'Installed /opt Mesa and Vulkan libraries were NOT modified.'
    echo 'Now run WITHOUT sudo:'
    echo "  bash $(basename "$0") --test"
    ;;
  --test)
    [[ $(id -u) -ne 0 ]] || { echo 'Run --test as your graphical desktop user, not root.' >&2; exit 2; }
    [[ -r "$MANIFEST" ]] || { echo "Run --build first: no $MANIFEST" >&2; exit 2; }
    [[ -f "$LIB" ]] || { echo "Candidate ICD library missing: $LIB" >&2; exit 2; }
    [[ -x /opt/vk-rotating-block/bin/vk-rotating-block ]] || { echo 'The demo binary is missing.' >&2; exit 2; }
    # Don't call demo's run.sh here; it sources lavapipe-env.sh which overwrites
    # VK_ICD_FILENAMES. Launch the binary directly with an isolated manifest.
    if [[ -f "$PREFIX/bin/lavapipe-env.sh" ]]; then
      source "$PREFIX/bin/lavapipe-env.sh"
    fi
    export LD_LIBRARY_PATH_64="$VK_PREFIX/lib/sparcv9:$PREFIX/lib/sparcv9:/usr/llvm/13/lib/sparcv9:/usr/lib/xorg/sparcv9${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
    export VK_ICD_FILENAMES="$MANIFEST"
    export DISPLAY="${DISPLAY:-:0}"
    echo "Testing driver: $LIB"
    echo "Using manifest: $VK_ICD_FILENAMES"
    exec /opt/vk-rotating-block/bin/vk-rotating-block --api 1.2 --wsi-probe
    ;;
  -h|--help) usage ;;
  *) echo "Unknown mode: $MODE" >&2; usage >&2; exit 2 ;;
esac
