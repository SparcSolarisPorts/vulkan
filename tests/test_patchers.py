#!/usr/bin/env python3
"""Offline smoke tests of source-rewrite targeting and idempotence (not Solaris runtime tests)."""
from pathlib import Path
import subprocess
import tempfile
import sys

BASE=Path(__file__).resolve().parents[1]
PATCH=BASE/'patches'
def run(script,src):
    p=subprocess.run([sys.executable,str(PATCH/script),str(src)],text=True,capture_output=True)
    if p.returncode != 0:
        raise AssertionError(f'{script} returned {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout

with tempfile.TemporaryDirectory() as tmp:
  root=Path(tmp)
  path=root/'wsi_common_drm.c'
  path.write_text('''static void wsi_create_native_image(void) {
 const VkMemoryDedicatedAllocateInfo memory_dedicated_info = {
   .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
   .pNext = &memory_export_info,
 };
}
''')
  run('apply-wsi-no-fd.py',path)
  assert 'SOLARIS_LVP_SW_NO_FD_EXPORT_TEST' in path.read_text()
  once=path.read_text()
  run('apply-wsi-no-fd.py',path)
  assert path.read_text()==once

  path=root/'wsi_common_x11.c'
  path.write_text('''static VkResult x11_present_to_x11_sw(xcb_connection_t *c) {
  xcb_put_image(c, 0, 0, 0, 8, 8, 0, 0, 0, 24, 256, data);
  return VK_SUCCESS;
}
''')
  run('apply-wsi-msbfirst-colors.py',path)
  once=path.read_text()
  assert 'solaris_lvp_put_image_msb(c' in once and 'SOLARIS_LVP_BGRA_MSB_FIRST_TEST' in once
  run('apply-wsi-msbfirst-colors.py',path)
  assert path.read_text()==once

  util=root/'src/util/format'
  util.mkdir(parents=True)
  for n in ['u_format_rgtc.c','u_format_latc.c']:
      (util/n).write_text('int8_t tmp_r[4][4]; /* util_format_signed_fetch_texel_rgtc */\n')
  run('apply-rgtc.py',root)
  assert 'signed char tmp_r[4][4]' in (util/'u_format_rgtc.c').read_text()
  run('apply-rgtc.py',root)

  meson=root/'src/gallium/targets/lavapipe/meson.build'
  meson.parent.mkdir(parents=True)
  meson.write_text('''shared_library('vulkan_lvp', target_sources,
  dependencies : [ dep_vulkan, dep_xcb ],
)
''')
  run('apply-lavapipe-x11-link.py',root)
  once=meson.read_text()
  assert 'solaris_lvp_wsi_deps' in once
  run('apply-lavapipe-x11-link.py',root)
  assert meson.read_text()==once
print('PASS: Mesa source patch targeting and idempotence')
