#!/usr/bin/env python3
# Idempotent Mesa 21.3.8 Solaris source portability patch.
# Usage: python3 apply-lavapipe-x11-link.py /path/to/mesa-21.3.8
import re
import shutil
import sys
from pathlib import Path

p = Path(sys.argv[1]) / 'src/gallium/targets/lavapipe/meson.build'
if not p.is_file():
    raise SystemExit(f'Missing Lavapipe target Meson file: {p}')
s = p.read_text(encoding='utf-8')
marker = '# solaris-lavapipe-x11-wsi-link-v6'
if marker in s:
    print('Lavapipe X11 linker patch already present')
    raise SystemExit(0)

preamble = """# solaris-lavapipe-x11-wsi-link-v6
solaris_lvp_wsi_deps = []
if host_machine.system() == 'sunos'
  foreach module : [
    'xcb-dri3', 'xcb-present', 'xcb-randr', 'xcb-shm',
    'xcb-sync', 'xcb-xfixes', 'xshmfence', 'x11-xcb',
    'xcb', 'x11',
  ]
    solaris_lvp_wsi_deps += dependency(module)
  endforeach
endif

"""

m = re.search(r"shared_library\s*\(\s*['\"]vulkan_lvp['\"]", s)
if not m:
    raise SystemExit('Could not find shared_library(vulkan_lvp); source unchanged')
opening = s.find('(', m.start())
i, level, quote, comment = opening, 0, None, False
while i < len(s):
    c = s[i]
    if comment:
        if c == '\n':
            comment = False
    elif quote:
        if c == '\\':
            i += 1
        elif c == quote:
            quote = None
    elif c == '#':
        comment = True
    elif c in "'\"":
        quote = c
    elif c == '(':
        level += 1
    elif c == ')':
        level -= 1
        if level == 0:
            break
    i += 1
if i >= len(s):
    raise SystemExit('Could not find Lavapipe library end; source unchanged')
block = s[opening + 1:i]
md = re.search(r'\bdependencies\s*:\s*', block)
if not md:
    raise SystemExit('No dependencies property in Lavapipe target; source unchanged')
val = md.end()
if block[val:val+1] == '[':
    newblock = block[:val+1] + '\n    solaris_lvp_wsi_deps, ' + block[val+1:]
else:
    var = re.match(r'([A-Za-z_][A-Za-z0-9_]*)\s*(?=,|\n)', block[val:])
    if not var:
        raise SystemExit('Unrecognized dependency expression; source unchanged')
    newblock = block[:val] + '[' + var.group(1) + ', solaris_lvp_wsi_deps]' + block[val + var.end(1):]

backup = p.with_name(p.name + '.pre-solaris-lvp-wsi-v6.bak')
if not backup.exists():
    shutil.copy2(p, backup)
p.write_text(preamble + s[:opening+1] + newblock + s[i:], encoding='utf-8')
print('Patched only the Lavapipe ICD direct X11 dependencies.')
print('Original backed up to:', backup)
