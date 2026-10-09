#!/usr/bin/env python3
# Idempotent SunOS compatibility patch for Khronos Vulkan-Loader v1.3.250
# Usage: python3 apply-vulkan-loader-solaris.py /path/to/Vulkan-Loader
from pathlib import Path
import sys
root = Path(sys.argv[1])

def replace_once(path, old, new, description):
    p = root / path
    s = p.read_text()
    if new in s:
        print('Already patched:', description)
        return
    if s.count(old) != 1:
        raise SystemExit(f'ERROR: expected one anchor for {description} in {p}; found {s.count(old)}')
    p.write_text(s.replace(old, new, 1))
    print('Applied:', description)

replace_once(
    'CMakeLists.txt',
    'add_library(loader_common_options INTERFACE)\n',
    'add_library(loader_common_options INTERFACE)\n'
    'if(CMAKE_SYSTEM_NAME STREQUAL "SunOS")\n'
    '    target_compile_definitions(loader_common_options INTERFACE _POSIX_C_SOURCE=200809L __EXTENSIONS__)\n'
    'endif()\n',
    'SunOS POSIX/extension macros (user patch)'
)
replace_once(
    'loader/vk_loader_platform.h',
    'defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)',
    'defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__) || defined(__sun)',
    'include SunOS in COMMON_UNIX_PLATFORMS (user patch)'
)
replace_once(
    'loader/vk_loader_platform.h',
    '#elif defined(__APPLE__)\n#include <libproc.h>\n',
    '#elif defined(__sun)\n'
    'static inline char *loader_platform_executable_path(char *buffer, size_t size) {\n'
    '    if (buffer == NULL || size < 2) return NULL;\n'
    '    ssize_t count = readlink("/proc/self/path/a.out", buffer, size - 1);\n'
    '    if (count <= 0 || (size_t)count >= size) return NULL;\n'
    "    buffer[count] = '\\0';\n"
    '    return buffer;\n'
    '}\n'
    '#elif defined(__APPLE__)\n#include <libproc.h>\n',
    'Solaris /proc/self/path/a.out executable path (user patch, bounds-safe)'
)
replace_once(
    'loader/loader_environment.c',
    '#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)',
    '#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__sun)',
    'disable environment-driven ICD injection in privileged processes'
)
# Assert the tag already has UNIX/SunOS code paths for WSI and loader_linux.c.
cm = (root / 'CMakeLists.txt').read_text()
ld = (root / 'loader/CMakeLists.txt').read_text()
if 'elseif(UNIX AND NOT APPLE)' not in cm or 'elseif(UNIX AND NOT APPLE)' not in ld:
    raise SystemExit('ERROR: upstream UNIX CMake conditions changed; check SunOS source selection')
print('Upstream UNIX CMake branches already cover SunOS, no other edits required.')
