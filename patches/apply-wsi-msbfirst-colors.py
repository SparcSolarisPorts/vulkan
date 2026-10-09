#!/usr/bin/env python3
# Proven on Solaris 11.4 SPARC T8-1 with X11 32bpp MSBFirst.
# Usage: python3 apply-wsi-msbfirst-colors.py /path/to/wsi_common_x11.c
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
