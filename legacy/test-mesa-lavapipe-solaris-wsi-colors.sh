#!/usr/bin/env bash
# Mesa 21.3.8 Solaris/SPARC experimental software Vulkan X11 WSI color fix.
# Converts BGRA8 memory to X11 MSBFirst XRGB byte order for 32-bpp XPutImage.
# Requires the successful no-FD-export WSI source patch already in the tree.
# Rebuilds a TEST ICD in the existing Mesa build tree. Never changes /opt Mesa.
#
#   sudo bash test-mesa-lavapipe-solaris-wsi-colors.sh --build [JOBS]
#   bash test-mesa-lavapipe-solaris-wsi-colors.sh --probe
#   bash test-mesa-lavapipe-solaris-wsi-colors.sh --run
#   MESA_SOLARIS_LVP_WSI_BYTESWAP=0 bash ... --run   # compare old behavior
set -Eeuo pipefail

WORK=${WORK:-/var/tmp/mesa-solaris-21.3.8-work}
SRC=${SRC:-$WORK/solaris-userland/components/x11/lib/mesa/mesa-21.3.8}
BUILD=${BUILD:-$WORK/build-mesa-lavapipe-x11-v4}
PREFIX=${PREFIX:-/opt/mesa-lavapipe-21.3.8}
VK_PREFIX=${VK_PREFIX:-/opt/vulkan-1.3.250}
TARGET=src/gallium/targets/lavapipe/libvulkan_lvp.so
LIB="$BUILD/$TARGET"
MANIFEST="$WORK/lvp-wsi-bgra-msb-test.json"
LOG="$WORK/lvp-wsi-bgra-msb-build.log"
FILE="$SRC/src/vulkan/wsi/wsi_common_x11.c"
MODE=${1:---help}

usage() {
cat <<'HELP'
Usage:
  sudo bash test-mesa-lavapipe-solaris-wsi-colors.sh --build [JOBS]
  bash test-mesa-lavapipe-solaris-wsi-colors.sh --probe
  bash test-mesa-lavapipe-solaris-wsi-colors.sh --run [demo arguments]

Requires the earlier successful wsi_common_drm.c no-FD-export source patch.
--build: Adds byte-order conversion only in Mesa's software X11 XPutImage
         path. Makes a backup, incrementally relinks Lavapipe, creates a
         separate ICD JSON. Does not change installed files under /opt.
--probe: Test swapchain creation with the newly built test ICD.
--run:   Open the rotating block in Vulkan WSI mode with that ICD.
         Demo arguments can follow (e.g. --api 1.1 --width 400).

On X11 MSBFirst with 32-bpp BGRA swapchain images, converts each pixel:
       [B,G,R,A] -> [A,R,G,B] before xcb_put_image.
Set MESA_SOLARIS_LVP_WSI_BYTESWAP=0 to disable this test conversion.
This is a targeted experimental workaround, not an upstream Mesa fix.
HELP
}

case "$MODE" in
  --build)
    [[ $(id -u) -eq 0 ]] || { echo 'Use sudo to build; source tree may be root-owned.' >&2; exit 2; }
    [[ $(uname -s) == SunOS ]] || { echo 'Only build on Solaris.' >&2; exit 2; }
    [[ -f "$FILE" && -f "$BUILD/build.ninja" ]] || { echo 'Mesa source or existing Ninja build directory missing.' >&2; exit 2; }
    if ! /usr/gnu/bin/grep -q 'SOLARIS_LVP_SW_NO_FD_EXPORT_TEST' "$SRC/src/vulkan/wsi/wsi_common_drm.c"; then
        echo 'STOP: previously successful no-FD-export WSI source patch is missing.' >&2
        echo 'Run the earlier test-mesa-lavapipe-solaris-wsi-no-fd.sh --build first.' >&2
        exit 2
    fi
    [[ -r "$PREFIX/share/vulkan/icd.d/lvp_icd.sun4v.json" ]] || { echo 'Installed ICD JSON not found.' >&2; exit 2; }
    export PATH="/usr/gcc/15/bin:/usr/llvm/13/bin:/usr/gnu/bin:/usr/local/bin:/usr/bin:/usr/sbin:${PATH:-}"
    export PKG_CONFIG_PATH="$VK_PREFIX/lib/sparcv9/pkgconfig:/usr/llvm/13/lib/sparcv9/pkgconfig:/usr/lib/sparcv9/pkgconfig:/usr/lib/sparcv9/pkgconfig:/usr/lib/xorg/sparcv9/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH_64="/usr/llvm/13/lib/sparcv9:/usr/lib/xorg/sparcv9${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
    JOBS=${2:-8}
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer.' >&2; exit 2; }

    python3 - "$FILE" <<'PY'
from pathlib import Path
import re
import shutil
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
marker = 'SOLARIS_LVP_BGRA_MSB_FIRST_TEST'
if marker in s:
    print('Color patch already present; skipping source modifications.')
    sys.exit(0)

pat = re.compile(r'\bstatic\s+VkResult\s+x11_present_to_x11_sw\s*\(')
matches = list(pat.finditer(s))
if len(matches) != 1:
    raise SystemExit('Could not uniquely locate x11_present_to_x11_sw; source left unchanged.')
start = matches[0].start()
brace = s.find('{', matches[0].end())
if brace < 0:
    raise SystemExit('Cannot identify WSI function body; source left unchanged.')
level = 0
end = -1
for i in range(brace, len(s)):
    if s[i] == '{':
        level += 1
    elif s[i] == '}':
        level -= 1
        if level == 0:
            end = i + 1
            break
if end < 0:
    raise SystemExit('Cannot identify end of WSI function; source left unchanged.')
func = s[start:end]
count = len(re.findall(r'\bxcb_put_image\s*\(', func))
if not 1 <= count <= 8:
    raise SystemExit(f'Unexpected xcb_put_image call count={count}; source left unchanged.')
# Only replace in software x11 presentation function. Other Mesa X11 paths untouched.
func = re.sub(r'\bxcb_put_image\s*\(', 'solaris_lvp_put_image_msb(', func)

helper = '''/* SOLARIS_LVP_BGRA_MSB_FIRST_TEST
 * On big-endian Solaris X11, the CPU software WSI sends BGRA bytes
 * directly to XCB Z_PIXMAP. With MSBFirst / 32-bpp XRGB that makes
 * alpha appear as blue. Convert a private copy before xcb_put_image.
 * The Vulkan-owned image memory is never modified.
 * Only software X11 presentations call this function.
 * This is an experimental Solaris workaround.
 */
#include <stdlib.h>
#include <stdio.h>

static xcb_void_cookie_t
solaris_lvp_put_image_msb(xcb_connection_t *c, uint8_t format,
                         xcb_drawable_t drawable, xcb_gcontext_t gc,
                         uint16_t width, uint16_t height,
                         int16_t dst_x, int16_t dst_y,
                         uint8_t left_pad, uint8_t depth,
                         uint32_t data_len, const uint8_t *data)
{
   const xcb_setup_t *setup = xcb_get_setup(c);
   const char *opt = getenv("MESA_SOLARIS_LVP_WSI_BYTESWAP");
   bool enabled = setup != NULL &&
                  setup->image_byte_order == XCB_IMAGE_ORDER_MSB_FIRST &&
                  format == XCB_IMAGE_FORMAT_Z_PIXMAP &&
                  data != NULL && data_len != 0 && (data_len % 4) == 0;
   if (opt && opt[0] == '0' && opt[1] == 0)
      enabled = false;

   if (enabled) {
      bool bpp32 = false;
      xcb_format_iterator_t fi = xcb_setup_pixmap_formats_iterator(setup);
      for (; fi.rem; xcb_format_next(&fi)) {
         if (fi.data->depth == depth && fi.data->bits_per_pixel == 32) {
            bpp32 = true;
            break;
         }
      }
      enabled = bpp32;
   }

   if (!enabled)
      return xcb_put_image(c, format, drawable, gc, width, height,
                           dst_x, dst_y, left_pad, depth, data_len, data);

   uint8_t *converted = malloc(data_len);
   if (converted == NULL) {
      fprintf(stderr, "Solaris Lavapipe WSI: no scratch memory for pixel conversion\\n");
      return xcb_put_image(c, format, drawable, gc, width, height,
                           dst_x, dst_y, left_pad, depth, data_len, data);
   }
   for (size_t i = 0; i < data_len; i += 4) {
      converted[i + 0] = data[i + 3]; /* ignored X byte <- alpha */
      converted[i + 1] = data[i + 2]; /* X11 red <- Vulkan red */
      converted[i + 2] = data[i + 1]; /* X11 green <- Vulkan green */
      converted[i + 3] = data[i + 0]; /* X11 blue <- Vulkan blue */
   }
   static bool announced = false;
   if (!announced) {
      fprintf(stderr, "Solaris Lavapipe WSI: BGRA to MSBFirst XRGB correction active\\n");
      announced = true;
   }
   xcb_void_cookie_t cookie = xcb_put_image(c, format, drawable, gc,
                                           width, height, dst_x, dst_y,
                                           left_pad, depth, data_len, converted);
   free(converted);
   return cookie;
}

'''
backup = p.with_name(p.name + '.pre-solaris-bgra-msb-test.bak')
if not backup.exists():
    shutil.copy2(p, backup)
p.write_text(s[:start] + helper + func + s[end:], encoding='utf-8')
print('Patched:', p)
print('Backup: ', backup)
print('Replaced', count, 'XCB PutImage calls in software WSI function.')
PY

    echo "== Incrementally rebuilding Lavapipe only =="
    echo "Build log: $LOG"
    if ! ninja -C "$BUILD" -j "$JOBS" "$TARGET" >"$LOG" 2>&1; then
        tail -n 100 "$LOG" >&2
        exit 1
    fi
    tail -n 16 "$LOG"
    [[ -f "$LIB" ]] || { echo "Candidate ICD not found: $LIB" >&2; exit 1; }
    python3 - "$PREFIX/share/vulkan/icd.d/lvp_icd.sun4v.json" "$LIB" "$MANIFEST" <<'PY'
from pathlib import Path
import json, sys
src, library, dest = sys.argv[1:]
data = json.loads(Path(src).read_text(encoding='utf-8'))
if 'ICD' not in data or 'library_path' not in data['ICD']:
    raise SystemExit('Original ICD JSON has an unexpected structure')
data['ICD']['library_path'] = library
Path(dest).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
print('Test manifest:', dest)
print('Test driver:  ', library)
PY
    chmod 644 "$MANIFEST"
    echo 'Installed /opt Mesa, Vulkan loader, and system graphics were NOT changed.'
    echo 'Next, run WITHOUT sudo:'
    echo "  bash $(basename "$0") --run"
    ;;

  --probe|--run)
    [[ $(id -u) -ne 0 ]] || { echo 'Run graphics tests as your desktop user, not root.' >&2; exit 2; }
    [[ -r "$MANIFEST" && -f "$LIB" ]] || { echo 'Test ICD missing. Run --build first.' >&2; exit 2; }
    [[ -x /opt/vk-rotating-block/bin/vk-rotating-block ]] || { echo 'Rotating block binary not found.' >&2; exit 2; }
    # Never source lavapipe-env.sh after setting the test ICD: it overwrites VK_ICD_FILENAMES.
    export LD_LIBRARY_PATH_64="$VK_PREFIX/lib/sparcv9:$PREFIX/lib/sparcv9:/usr/llvm/13/lib/sparcv9:/usr/lib/xorg/sparcv9${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
    export VK_ICD_FILENAMES="$MANIFEST"
    export DISPLAY="${DISPLAY:-:0}"
    echo "Using test ICD: $VK_ICD_FILENAMES"
    echo "Pixel conversion: ${MESA_SOLARIS_LVP_WSI_BYTESWAP:-auto (enabled on MSBFirst 32-bpp)}"
    if [[ "$MODE" == --probe ]]; then
        exec /opt/vk-rotating-block/bin/vk-rotating-block --api 1.2 --wsi-probe
    else
        shift
        if (( $# > 0 )); then
            exec /opt/vk-rotating-block/bin/vk-rotating-block "$@"
        fi
        exec /opt/vk-rotating-block/bin/vk-rotating-block --api 1.2 --present wsi
    fi
    ;;
  --help|-h) usage ;;
  *) echo "Unknown mode: $MODE" >&2; usage >&2; exit 2 ;;
esac
