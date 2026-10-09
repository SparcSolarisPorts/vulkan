#!/usr/bin/env python3
# Proven on Solaris 11.4 SPARC T8-1 against Oracle-patched Mesa 21.3.8.
# Usage: python3 apply-wsi-no-fd.py /path/to/wsi_common_drm.c
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
