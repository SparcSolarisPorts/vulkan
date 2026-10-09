#!/usr/bin/env bash
# Experimental Mesa 21.3.8 OpenGL + Lavapipe + X11/DRI3 v6 for Solaris/SPARC.
# Automatically restores the previously prepared, Oracle-patched Mesa source tree,
# and the separately installed /opt/vulkan-1.3.250 Vulkan loader+headers.
# Installs ONLY to /opt/mesa-lavapipe-21.3.8; never replaces system OpenGL,
# Oracle IPS packages, user login profiles, SSH, or the existing /opt/mesa.
# This is a PORTING BUILD, not a guarantee of Solaris/SPARC Lavapipe support.
set -Eeuo pipefail
umask 022

PREFIX=/opt/mesa-lavapipe-21.3.8
VK_PREFIX=/opt/vulkan-1.3.250
WORK=/var/tmp/mesa-solaris-21.3.8-work
COMPONENT="$WORK/solaris-userland/components/x11/lib/mesa"
BUILD="$WORK/build-mesa-lavapipe-x11-v4"
STAGE=""
LOG="$WORK/lavapipe-install.log"
CONFIG_LOG="$WORK/lavapipe-configure.log"
BUILD_LOG="$WORK/lavapipe-build.log"
STAGE_LOG="$WORK/lavapipe-stage-install.log"
JOBS="${JOBS:-8}"
CONFIGURE_ONLY=0
VULKAN_ONLY=0
SOURCE_OVERRIDE=''
MESA_ARCHIVE_URL="${MESA_ARCHIVE_URL:-https://ww.artfiles.org/x.org/pub/mesa/older-versions/21.x/mesa-21.3.8.tar.xz}"

usage() {
  cat <<'HELP'
Usage: sudo bash install-mesa-lavapipe-solaris-sparc-v6.sh [--configure-only] [--vulkan-only] [--jobs N] [--source DIR]
  --configure-only  Run Meson configure only; do not compile/install
  --vulkan-only     Build Lavapipe + X11 without OpenGL/GLX/EGL (diagnostics)
  --no-default      Accepted for compatibility; profiles/defaults are never modified
  --jobs N          Ninja job count (default 8)
  --source DIR      Explicit Oracle-patched Mesa 21.3.8 source directory

Finds or restores Oracle-patched Mesa 21.3.8 source using gmake prep;
requires the existing Oracle Userland checkout and the tested Vulkan
loader in /opt/vulkan-1.3.250. Default: OpenGL + GLES + EGL + GLX and
Vulkan Lavapipe with X11/DRI3, NO Nouveau. GTK is not a Mesa build option.
Never changes existing /opt/mesa installs, system GL/Vulkan libraries,
shell defaults, X11 setup, or SSH.
HELP
}
while (( $# )); do
  case "$1" in
    --configure-only) CONFIGURE_ONLY=1 ;;
    --vulkan-only) VULKAN_ONLY=1 ;;
    --no-default) : ;;
    --source) shift; [[ $# -gt 0 ]] || { usage >&2; exit 2; }; SOURCE_OVERRIDE="$1" ;;
    --jobs) shift; [[ $# -gt 0 && "$1" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }; JOBS="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ $(id -u) -eq 0 ]] || { echo 'Use sudo to run this script.' >&2; exit 2; }
[[ $(uname -s) == SunOS && $(uname -p) == sparc* ]] || {
  echo 'This script is for Solaris/SPARC only.' >&2; exit 2;
}
[[ ! -e "$PREFIX" && ! -L "$PREFIX" ]] || {
  echo "Refusing to overwrite installed directory: $PREFIX" >&2; exit 2;
}
[[ -r "$VK_PREFIX/include/vulkan/vulkan.h" ]] || {
  echo "Missing Vulkan headers at $VK_PREFIX/include/vulkan/vulkan.h" >&2; exit 2;
}
[[ -f "$VK_PREFIX/lib/sparcv9/libvulkan.so.1" ]] || {
  echo "Missing Vulkan loader at $VK_PREFIX/lib/sparcv9/libvulkan.so.1" >&2; exit 2;
}
# Search before touching the source checkout. The earlier OpenGL installer produced
# this tree, but it may have been cleaned since the original build completed.
export PATH="/usr/gcc/15/bin:/usr/llvm/13/bin:/usr/gnu/bin:/usr/local/bin:/usr/bin:/usr/sbin:${PATH:-}"
if [[ -n "$SOURCE_OVERRIDE" ]]; then
  [[ -f "$SOURCE_OVERRIDE/meson.build" ]] || {
    echo "--source directory lacks meson.build: $SOURCE_OVERRIDE" >&2; exit 2;
  }
  SRC=$(cd "$SOURCE_OVERRIDE" && pwd)
else
  [[ -f "$COMPONENT/Makefile" ]] || {
    echo "Oracle Userland Mesa component missing: $COMPONENT" >&2; exit 2;
  }
  find_prepared() {
    find "$COMPONENT" -type f -path '*/mesa-21.3.8/meson.build' -print -quit 2>/dev/null || :
  }
  SRC_MESON=$(find_prepared)
  if [[ -z "$SRC_MESON" ]]; then
    echo "Prepared Mesa source missing; restoring from Oracle Userland."
    echo "Source mirror: $MESA_ARCHIVE_URL"
    # IMPORTANT: Userland builds a 32-bit sparcv7 host helper; never pass
    # Mesa's -m64 flags to gmake prep/setup.
    unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LD_OPTIONS || :
    ulvars=(
      GCC_ROOT=/usr/gcc/15
      PERL_VERSION=5.38
      PERL=/usr/bin/perl
      PYTHON_VERSION=3.11
      "COMPONENT_ARCHIVE_URL=$MESA_ARCHIVE_URL"
    )
    for tool in gmake /usr/bin/perl /usr/gcc/15/bin/gcc /usr/bin/python3.11; do
      [[ -x "$tool" ]] || command -v "$tool" >/dev/null 2>&1 || {
        echo "Required Oracle Userland tool is missing: $tool" >&2; exit 2;
      }
    done
    mkdir -p "$WORK"
    PREP_LOG="$WORK/lavapipe-source-repair.log"
    if ! ( cd "$COMPONENT" && gmake "${ulvars[@]}" download && gmake "${ulvars[@]}" prep ) >"$PREP_LOG" 2>&1; then
      echo "Oracle Userland preparation failed. Last log lines:" >&2
      /usr/gnu/bin/tail -n 80 "$PREP_LOG" >&2
      exit 2
    fi
    SRC_MESON=$(find_prepared)
    if [[ -z "$SRC_MESON" ]]; then
      echo "No source after prep; cleaning ONLY this Mesa component and re-preparing."
      if ! ( cd "$COMPONENT" && gmake "${ulvars[@]}" clean && gmake "${ulvars[@]}" download && gmake "${ulvars[@]}" prep ) >>"$PREP_LOG" 2>&1; then
        echo "Component clean/re-prep failed. Last log lines:" >&2
        /usr/gnu/bin/tail -n 80 "$PREP_LOG" >&2
        exit 2
      fi
      SRC_MESON=$(find_prepared)
    fi
    if [[ -z "$SRC_MESON" ]]; then
      echo "Prepared source still missing. Run: find '$COMPONENT' -name meson.build -print" >&2
      echo "Preparation log: $PREP_LOG" >&2
      exit 2
    fi
  fi
  SRC=$(dirname "$SRC_MESON")
fi
if (( VULKAN_ONLY )); then
  BUILD="$WORK/build-lavapipe-vulkan-only-v4"
fi
export CC=/usr/gcc/15/bin/gcc CXX=/usr/gcc/15/bin/g++
export PKG_CONFIG_PATH="$VK_PREFIX/lib/sparcv9/pkgconfig:/usr/llvm/13/lib/sparcv9/pkgconfig:/usr/lib/sparcv9/pkgconfig:/usr/lib/xorg/sparcv9/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# These flags apply only to standalone 64-bit Meson/Ninja, NOT Oracle Userland's
# earlier mixed 32/64-bit 'gmake setup' helper build.
export CFLAGS="-m64 -D__EXTENSIONS__ -I$VK_PREFIX/include -I/usr/llvm-13/include"
export CXXFLAGS="-m64 -D__EXTENSIONS__ -I$VK_PREFIX/include -I/usr/llvm-13/include"
export CPPFLAGS="-D__EXTENSIONS__ -D__STDC_CONSTANT_MACROS -D__STDC_LIMIT_MACROS -I$VK_PREFIX/include -I/usr/llvm-13/include"
export LDFLAGS="-m64 -Wl,-zgnu-version-script-compat -Wl,-znolazyload -Wl,-z,rescan-now -L/usr/llvm/13/lib/sparcv9 -L/usr/lib/xorg/sparcv9 -L$VK_PREFIX/lib/sparcv9"

for tool in meson ninja python3 "$CC" "$CXX" pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done
mkdir -p "$WORK"
exec > >(tee -a "$LOG") 2>&1
trap 'r=$?; echo "FAILED: exit=$r line=$LINENO. See $LOG and $WORK/lavapipe-*.log" >&2' ERR

echo "== Lavapipe on Solaris SPARC =="
echo "Mesa source: $SRC"
echo "Vulkan loader: $VK_PREFIX"
echo "Install destination: $PREFIX"
echo "Jobs: $JOBS"
echo "This build does not request Nouveau/libdrm_nouveau."

# Vulkan X11 WSI needs DRI3, plus the XCB DRI3/Present development libraries.
# No kernel /dev/dri is required for basic CPU Vulkan device enumeration,
# but X11 presentation may still need working DRI3 support in the X server.
echo "Build mode: $([[ $VULKAN_ONLY -eq 1 ]] && echo 'Vulkan-only' || echo 'OpenGL + Vulkan')"
for dep in xcb-dri3 xcb-present xcb x11; do
  if pkg-config --exists "$dep"; then
    echo "X11 dependency found: $dep ($(pkg-config --modversion "$dep"))"
  else
    echo "WARNING: missing pkg-config module $dep; Meson may reject X11/DRI3" >&2
  fi
done
opts=(
  --prefix="$PREFIX"
  --libdir=lib/sparcv9
  --buildtype=release
  -Dplatforms=x11
  -Ddri3=enabled
  -Dgallium-drivers=swrast
  -Dvulkan-drivers=swrast
  '-Ddri-drivers=[]'
  "-Ddri-drivers-path=$PREFIX/lib/sparcv9/dri"
  -Dglvnd=false
  -Delf-tls=false
  -Dllvm=true
)
if (( VULKAN_ONLY )); then
  opts+=(
    -Dglx=disabled
    -Degl=disabled
    -Dgbm=disabled
    -Dopengl=false
    -Dgles1=disabled
    -Dgles2=disabled
    -Dshared-glapi=disabled
  )
else
  # Similar to the existing working Oracle-patched OpenGL build, with Vulkan
  # swrast and DRI3 added. Keep the user-tested glx=auto selection.
  opts+=(
    -Dglx=auto
    -Degl=enabled
    -Dgbm=enabled
    -Dopengl=true
    -Dgles1=enabled
    -Dgles2=enabled
    -Dshared-glapi=enabled
  )
fi


# Solaris GCC 15 source compatibility: Solaris may typedef int8_t as plain
# signed 'char', which is not type-compatible with 'signed char *' in C.
# In Mesa 21.3.8, the RGTC functions take signed char pointers, but two
# callers pass int8_t pointers/arrays. Correct the caller-local declarations
# instead of altering public RGTC helper APIs or suppressing diagnostics.
# Keep both source backups and the existing Ninja build tree.
echo "== Applying idempotent Solaris RGTC signed-char compatibility patch =="
python3 - "$SRC" <<'PY_RGTC_FIX'
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
PY_RGTC_FIX

# Solaris ld resolves undefined symbols only from explicitly linked DSOs.
# Mesa's Lavapipe target currently links -lxcb-dri3 but omits the other X11
# WSI libraries referenced by the statically linked wsi_common_x11 objects.
# Link them on this target only, leaving GL/EGL and user/system defaults alone.
echo "== Patching Lavapipe Solaris X11 WSI link dependencies =="
python3 - "$SRC" <<'PY_LVP_WSI'
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
PY_LVP_WSI

for module in xcb xcb-dri3 xcb-present xcb-randr xcb-shm xcb-sync xcb-xfixes xshmfence x11-xcb x11; do
  if ! pkg-config --exists "$module"; then
    echo "ERROR: missing X11 WSI pkg-config module: $module" >&2
    exit 2
  fi
done

printf '\n== Configuring Mesa (OpenGL + Lavapipe / X11 DRI3) ==\n'
# A failed Meson configure can leave a partial directory without build.ninja.
# Preserve it for inspection, but retry cleanly using this build directory.
if [[ -d "$BUILD" && ! -f "$BUILD/build.ninja" ]]; then
  OLD_BUILD="${BUILD}.failed-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$BUILD" "$OLD_BUILD"
  echo "Preserved incomplete Meson configuration: $OLD_BUILD"
fi
if [[ -f "$BUILD/build.ninja" ]]; then
  if ! meson setup --reconfigure "$BUILD" "$SRC" "${opts[@]}" >"$CONFIG_LOG" 2>&1; then
    /usr/gnu/bin/tail -n 100 "$CONFIG_LOG"; exit 1
  fi
else
  if ! meson setup "$BUILD" "$SRC" "${opts[@]}" >"$CONFIG_LOG" 2>&1; then
    /usr/gnu/bin/tail -n 100 "$CONFIG_LOG"; exit 1
  fi
fi
/usr/gnu/bin/tail -n 35 "$CONFIG_LOG"
if (( CONFIGURE_ONLY )); then
  echo "Configuration succeeded. Run without --configure-only to compile."
  exit 0
fi

printf '\n== Compiling Mesa + Lavapipe ==\n'
if ! ninja -C "$BUILD" -j "$JOBS" >"$BUILD_LOG" 2>&1; then
  echo "Compile failed. Last 120 lines of $BUILD_LOG:" >&2
  /usr/gnu/bin/tail -n 120 "$BUILD_LOG" >&2
  exit 1
fi
/usr/gnu/bin/tail -n 20 "$BUILD_LOG"

printf '\n== Staged install, existing Mesa preserved ==\n'
STAGE=$(mktemp -d "$WORK/mesa-lavapipe-v6-stage.XXXXXX")
echo "Stage directory: $STAGE"
if ! env DESTDIR="$STAGE" ninja -C "$BUILD" install >"$STAGE_LOG" 2>&1; then
  /usr/gnu/bin/tail -n 100 "$STAGE_LOG"; exit 1
fi
/usr/gnu/bin/tail -n 30 "$STAGE_LOG"

[[ -d "$STAGE$PREFIX" ]] || { echo 'Staged prefix missing' >&2; exit 1; }
if (( ! VULKAN_ONLY )); then
  GL_LIBRARY=$(find "$STAGE$PREFIX/lib/sparcv9" -name 'libGL.so*' -print -quit)
  [[ -n "$GL_LIBRARY" ]] || {
    echo 'Expected OpenGL libGL.so not present in staged combined installation.' >&2
    exit 1
  }
fi
ICD=$(find "$STAGE$PREFIX" -type f -name '*lvp*icd*.json' -print -quit)
if [[ -z "$ICD" ]]; then
  ICD=$(find "$STAGE$PREFIX" -type f -name '*lvp*.json' -print -quit)
fi
DRIVER=$(find "$STAGE$PREFIX" \( -type f -o -type l \) -name 'libvulkan_lvp.so*' -print -quit)
if [[ -z "$ICD" || -z "$DRIVER" ]]; then
  echo 'Build compiled, but staged Vulkan ICD/driver was not found; refusing to activate.' >&2
  echo "ICD=$ICD DRIVER=$DRIVER" >&2
  find "$STAGE$PREFIX" \( -name '*lvp*' -o -name '*vulkan*' \) -print >&2
  exit 1
fi

# Make the manifest independent of system DSO lookup. Driver resides under
# the final /opt prefix, not the temporary DESTDIR staging prefix.
FINAL_DRIVER=${DRIVER#"$STAGE"}
python3 - "$ICD" "$FINAL_DRIVER" <<'PY'
import json, sys
path, library = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
assert 'ICD' in data and 'library_path' in data['ICD'], 'Unsupported ICD manifest schema'
data['ICD']['library_path'] = library
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print('ICD library path set to:', library)
PY
FINAL_ICD=${ICD#"$STAGE"}

# Atomic activation only after successful build and staged manifest checks.
mv "$STAGE$PREFIX" "$PREFIX"
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/lavapipe-env.sh" <<EOF_ENV
# Source this file in bash/ksh to use opt-only Vulkan+Lavapipe.
export LD_LIBRARY_PATH_64="$VK_PREFIX/lib/sparcv9:$PREFIX/lib/sparcv9:/usr/llvm/13/lib/sparcv9:/usr/lib/xorg/sparcv9\${LD_LIBRARY_PATH_64:+:\$LD_LIBRARY_PATH_64}"
export VK_ICD_FILENAMES="$FINAL_ICD"
export LIBGL_DRIVERS_PATH="$PREFIX/lib/sparcv9/dri"
export VK_LOADER_DEBUG="\${VK_LOADER_DEBUG:-error,warn}"
EOF_ENV
cat > "$PREFIX/bin/lavapipe-run" <<EOF_RUN
#!/usr/bin/env bash
set -e
. "$PREFIX/bin/lavapipe-env.sh"
exec "\$@"
EOF_RUN
chmod 0755 "$PREFIX/bin/lavapipe-run"
cat > "$PREFIX/bin/mesa-run" <<EOF_RUN_GL
#!/usr/bin/env bash
set -e
. "$PREFIX/bin/lavapipe-env.sh"
exec "\$@"
EOF_RUN_GL
chmod 0755 "$PREFIX/bin/mesa-run"

# A complete ICD test, unlike vkEnumerateInstanceVersion in loader-only smoke.
cat > "$WORK/lavapipe-device-check.c" <<'C'
#include <stdio.h>
#include <vulkan/vulkan.h>
int main(void) {
    VkApplicationInfo app = {0};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "Solaris Lavapipe ICD test";
    app.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    info.pApplicationInfo = &app;
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&info, NULL, &instance);
    printf("vkCreateInstance = %d\n", result);
    if (result != VK_SUCCESS) return 2;
    uint32_t count = 0;
    result = vkEnumeratePhysicalDevices(instance, &count, NULL);
    printf("vkEnumeratePhysicalDevices = %d; devices = %u\n", result, count);
    if (result == VK_SUCCESS && count > 0) {
        VkPhysicalDevice dev;
        uint32_t one = 1;
        result = vkEnumeratePhysicalDevices(instance, &one, &dev);
        if (result == VK_SUCCESS && one > 0) {
            VkPhysicalDeviceProperties p;
            vkGetPhysicalDeviceProperties(dev, &p);
            printf("Vulkan device: %s\n", p.deviceName);
            printf("Device API version: %u.%u.%u\n",
                   VK_API_VERSION_MAJOR(p.apiVersion),
                   VK_API_VERSION_MINOR(p.apiVersion),
                   VK_API_VERSION_PATCH(p.apiVersion));
        }
    }
    vkDestroyInstance(instance, NULL);
    return (result == VK_SUCCESS && count > 0) ? 0 : 3;
}
C
"$CC" -m64 -D__EXTENSIONS__ -I"$VK_PREFIX/include" \
  "$WORK/lavapipe-device-check.c" -L"$VK_PREFIX/lib/sparcv9" \
  -Wl,-R,"$VK_PREFIX/lib/sparcv9" -lvulkan \
  -o "$WORK/lavapipe-device-check"

echo "Installed Lavapipe ICD: $FINAL_ICD"
echo "Installed Lavapipe DSO: $FINAL_DRIVER"
echo '== Runtime ICD smoke test =='
if "$PREFIX/bin/lavapipe-run" "$WORK/lavapipe-device-check"; then
  echo 'PASS: Lavapipe enumerates a Vulkan physical device.'
else
  echo 'WARNING: Lavapipe built but failed runtime initialization. Inspect loader diagnostics.' >&2
  echo "Run: VK_LOADER_DEBUG=all $PREFIX/bin/lavapipe-run $WORK/lavapipe-device-check" >&2
  exit 1
fi
printf '\nSUCCESS: Mesa/Lavapipe installed separately in %s\n' "$PREFIX"
if (( ! VULKAN_ONLY )); then
  echo "OpenGL test (from graphical user session): $PREFIX/bin/mesa-run glxinfo -B"
fi
echo "Recheck: $PREFIX/bin/lavapipe-run $WORK/lavapipe-device-check"
echo "Log directory: $WORK"
echo 'System Mesa, shell profiles, X11 settings and SSH configuration remain unchanged.'
echo 'NOTE: An enumerated Vulkan device does not prove X11 swapchain/presentation works.'
