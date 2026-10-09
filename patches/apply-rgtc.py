#!/usr/bin/env python3
# Idempotent Mesa 21.3.8 Solaris source portability patch.
# Usage: python3 apply-rgtc.py /path/to/mesa-21.3.8
import re
import shutil
import sys
from pathlib import Path

src = Path(sys.argv[1])
for rel in (
    'src/util/format/u_format_rgtc.c',
    'src/util/format/u_format_latc.c',
):
    path = src / rel
    if not path.is_file():
        raise SystemExit(f"Missing RGTC source: {path}")
    old = path.read_text(encoding='utf-8')
    if 'util_format_signed_fetch_texel_rgtc' not in old:
        raise SystemExit(f"Unexpected RGTC source contents: {path}")
    new, count = re.subn(r'\bint8_t\b', 'signed char', old)
    if count:
        backup = path.with_name(path.name + '.pre-solaris-rgtc-v5.bak')
        if not backup.exists():
            shutil.copy2(path, backup)
        path.write_text(new, encoding='utf-8')
        print(f"Patched: {rel}: {count} signed 8-bit declarations/casts (backup: {backup.name})")
    else:
        print(f"Already patched: {rel}")
