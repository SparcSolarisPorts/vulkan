#!/usr/bin/env bash
# Experimental Mesa 21.3.8 build for Oracle Solaris 11.4 / SPARC.
# Run as: sudo bash install-mesa-solaris-sparc.sh
# Tries Gallium nouveau + swrast and Vulkan lavapipe first; falls back to swrast.
# Overrides Oracle Userland's GCC/Perl/Python defaults for this host.
# Keeps mixed-width Userland bootstrap separate from the 64-bit Mesa build.
# Installing Mesa user-space drivers DOES NOT install Nouveau kernel DRM,
# guarantee Vulkan support, or guarantee OpenGL 4.6 on SPARC.
set -Eeuo pipefail
umask 022

PREFIX=/opt/mesa-21.3.8-solaris
WORK=/var/tmp/mesa-solaris-21.3.8-work
REPO="$WORK/solaris-userland"
COMPONENT="$REPO/components/x11/lib/mesa"
# Use the available Mesa 21.3.8 archive mirror, retaining Oracle Userland's SHA256 validation.
MESA_ARCHIVE_URL="${MESA_ARCHIVE_URL:-https://ww.artfiles.org/x.org/pub/mesa/older-versions/21.x/mesa-21.3.8.tar.xz}"
LOG="$WORK/install.log"
JOBS="${JOBS:-8}"
MODE=experimental
ALLOW_FALLBACK=1
SET_USER_DEFAULT=1

usage() {
  cat <<'HELP'
Usage: sudo bash install-mesa-solaris-sparc.sh [OPTIONS]
  --software-only    Build Oracle-style swrast without Nouveau/Lavapipe
  --no-fallback      Stop if the experimental build fails
  --no-default       Do not add Mesa environment to invoking user's profile
  --jobs N           Ninja parallel jobs (default: 8)
  --help             Show this help

This script installs to /opt/mesa-21.3.8-solaris and, if available,
creates /opt/mesa -> /opt/mesa-21.3.8-solaris.
It never replaces the IPS-managed /usr/lib OpenGL libraries.
HELP
}

while (( $# )); do
  case "$1" in
    --software-only) MODE=software ;;
    --no-fallback) ALLOW_FALLBACK=0 ;;
    --no-default) SET_USER_DEFAULT=0 ;;
    --jobs)
      shift
      if (( $# == 0 )) || [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then
        echo 'ERROR: --jobs requires a positive integer' >&2
        exit 2
      fi
      JOBS="$1" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(id -u)" != 0 ]]; then
  echo 'ERROR: Please run with sudo: sudo bash install-mesa-solaris-sparc.sh' >&2
  exit 1
fi
if [[ "$(uname -s)" != SunOS || "$(uname -p)" != sparc* ]]; then
  echo 'ERROR: This build script is intended for Solaris on SPARC.' >&2
  exit 1
fi
if [[ -e "$PREFIX" || -L "$PREFIX" ]]; then
  echo "ERROR: $PREFIX already exists; refusing to overwrite an installation." >&2
  exit 1
fi

mkdir -p "$WORK"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; echo "ERROR: install stopped (exit $rc) at line $LINENO. Log: $LOG" >&2' ERR
info() { printf '\n>>> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }

# Capture the real login account before sudo changes HOME.
TARGET_USER="${SUDO_USER:-}"
TARGET_HOME=""
if [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]]; then
  TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
fi

export PATH="/usr/llvm/13/bin:/usr/gcc/15/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH"
export PKG_CONFIG_PATH="/usr/llvm/13/lib/sparcv9/pkgconfig:/usr/lib/xorg/sparcv9/pkgconfig:/usr/lib/sparcv9/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# CRITICAL: Do not export -m64 (or custom CC/CXX/CFLAGS/LDFLAGS) here.
# Oracle Userland's `gmake setup` builds both time-sparcv7.o (-m32)
# and time-sparcv9.o (-m64). Global -m64 makes the 32-bit helper fail.
# Also don't let inherited settings from an interactive shell leak into gmake.
unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LD_OPTIONS || :

# These flags are passed ONLY to the standalone 64-bit Mesa Meson setup.
# Meson persists them in its build configuration, so Ninja uses them.
MESA_CFLAGS="-m64 -D__EXTENSIONS__ -Wno-incompatible-pointer-types -I/usr/llvm-13/include"
MESA_CXXFLAGS="-m64 -D__EXTENSIONS__ -I/usr/llvm-13/include"
MESA_CPPFLAGS="-D__EXTENSIONS__ -D__STDC_CONSTANT_MACROS -D__STDC_LIMIT_MACROS -I/usr/llvm-13/include"
MESA_LDFLAGS="-m64 -Wl,-zgnu-version-script-compat -Wl,-znolazyload -Wl,-z,rescan-now -L/usr/llvm/13/lib/sparcv9 -L/usr/lib/xorg/sparcv9"

# Oracle Solaris pkg(1) returns 4 when no changes are necessary.
# Do not confuse the "already installed" case with an installation failure.
pkg_install() {
  local rc=0
  pkg install --accept "$@" || rc=$?
  case "$rc" in
    0) return 0 ;;
    4) info 'IPS packages already installed (exit 4, nothing to do).'; return 0 ;;
    *) echo "ERROR: pkg install exited $rc" >&2; return "$rc" ;;
  esac
}

info 'Installing Solaris build dependencies (IPS)'
# Mesa, X11, and libdrm are usually already present on Solaris 11.4.
# These are the documented component dependencies; IPS resolves versions.
pkg_install \
  developer/versioning/git \
  developer/build/meson \
  developer/build/pkg-config \
  developer/build/gnu-make \
  developer/llvm/llvm-13 \
  developer/llvm/llvm-build-13 \
  developer/lexer/flex \
  developer/parser/bison \
  x11/header/x11-protocols \
  x11/library/libdrm \
  x11/library/libx11 \
  x11/library/libxcb \
  x11/library/libxext \
  x11/library/libxfixes \
  x11/library/libxdamage \
  x11/library/libxshmfence \
  x11/library/libxxf86vm \
  library/expat library/zlib compress/zstd

# Meson generally pulls in Ninja, but check explicitly on the installed image.
if ! command -v ninja >/dev/null 2>&1; then
  pkg_install developer/build/ninja
fi
for tool in git gmake meson ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
for tool in /usr/gcc/15/bin/gcc /usr/gcc/15/bin/g++ /usr/llvm/13/bin/llvm-config; do
  [[ -x "$tool" ]] || { echo "Missing required compiler/LLVM tool: $tool" >&2; exit 1; }
done

# This host has GCC 15.2, Perl 5.38.4, Python 3.11.14.  The newest
# upstream Userland checkout uses GCC 16, Perl 5.42 and Python 3.13 by
# default. GNU make command-line variables override the upstream defaults
# and propagate to recursive make invocations; no system symlinks are changed.
USERLAND_MAKE_VARS=(
  GCC_ROOT=/usr/gcc/15
  PERL_VERSION=5.38
  PERL=/usr/bin/perl
  PYTHON_VERSION=3.11
)
for tool in /usr/bin/perl /usr/bin/python3.11; do
  [[ -x "$tool" ]] || { echo "Missing required tool: $tool" >&2; exit 1; }
done

info 'Retrieving Oracle Solaris Userland build rules and Mesa patches'
if [[ ! -d "$REPO/.git" ]]; then
  git clone --depth=1 https://github.com/oracle/solaris-userland.git "$REPO"
else
  info "Reusing already cloned repository: $REPO"
fi
# A few tools in Oracle's latest master branch hardcode Python 3.13 in
# their shebangs, irrespective of the PYTHON_VERSION make variable.
# Rewrite *only the disposable checkout*, and only when 3.13 is absent.
if [[ ! -x /usr/bin/python3.13 ]]; then
  info 'Adapting Oracle checkout tool shebangs from Python 3.13 to Python 3.11'
  while IFS= read -r pyfile; do
    /usr/gnu/bin/sed -i '1s@^#!/usr/bin/python3\.13$@#!/usr/bin/python3.11@' "$pyfile"
  done < <(grep -rIl '^#!/usr/bin/python3\.13' "$REPO/tools" || true)
fi
(cd "$REPO/components" && gmake "${USERLAND_MAKE_VARS[@]}" setup)
# Override the source archive URL for BOTH phases so recursive Userland
# download/prep uses the same mirror. COMPONENT_SIG_URL expands from this
# setting and the COMPONENT_ARCHIVE_HASH in Oracle's Makefile is preserved.
info "Downloading Mesa 21.3.8 from: $MESA_ARCHIVE_URL"
(cd "$COMPONENT" && \
  gmake "${USERLAND_MAKE_VARS[@]}" "COMPONENT_ARCHIVE_URL=$MESA_ARCHIVE_URL" download && \
  gmake "${USERLAND_MAKE_VARS[@]}" "COMPONENT_ARCHIVE_URL=$MESA_ARCHIVE_URL" prep)

# Userland's prep target normally creates build/.../mesa-21.3.8.
SRC_MESON="$(find "$COMPONENT" -type f -path '*/mesa-21.3.8/meson.build' -print -quit)"
if [[ -z "$SRC_MESON" ]]; then
  echo "ERROR: gmake prep did not expose a Mesa 21.3.8 source tree in $COMPONENT" >&2
  exit 1
fi
SRC="$(dirname "$SRC_MESON")"
info "Prepared source: $SRC"

run_logged() {
  local logfile="$1"
  shift
  "$@" 2>&1 | tee -a "$logfile"
  return "${PIPESTATUS[0]}"
}

try_build() {
  local name="$1" build="$WORK/build-$1" stage="$WORK/stage-$1"
  local config_log="$WORK/$name-configure.log"
  local build_log="$WORK/$name-build.log"
  local install_log="$WORK/$name-stage-install.log"
  local gallium='swrast' vulkan=''
  if [[ "$name" == experimental ]]; then
    gallium='swrast,nouveau'
    vulkan='swrast'  # Lavapipe ICD
  fi
  info "Configuring $name (Gallium=$gallium, Vulkan=${vulkan:-disabled})"
  # Removing only this script's fixed staging/build directories.
  rm -rf -- "$build" "$stage"
  mkdir -p "$build" "$stage"
  local opts=(
    --prefix="$PREFIX"
    --libdir=lib/sparcv9
    --buildtype=release
    -Dplatforms=x11
    "-Dgallium-drivers=$gallium"
    "-Dvulkan-drivers=$vulkan"
    -Ddri-drivers=
    "-Ddri-drivers-path=$PREFIX/lib/sparcv9/dri"
    -Delf-tls=false
    -Dgbm=true
    -Dglvnd=false
    -Dllvm=true
    -Dglx=auto
    -Degl=true
  )
  # Use a Mesa-only toolchain. Do not expose these flags to Userland's
  # earlier 32-bit host-tool compilation.
  if ! run_logged "$config_log" env \
      CC=/usr/gcc/15/bin/gcc \
      CXX=/usr/gcc/15/bin/g++ \
      CFLAGS="$MESA_CFLAGS" \
      CXXFLAGS="$MESA_CXXFLAGS" \
      CPPFLAGS="$MESA_CPPFLAGS" \
      LDFLAGS="$MESA_LDFLAGS" \
      meson setup "$build" "$SRC" "${opts[@]}"; then
    warn "$name: Meson configure failed; see $config_log"
    return 1
  fi
  if ! run_logged "$build_log" ninja -C "$build" -j "$JOBS"; then
    warn "$name: compile/link failed; see $build_log"
    return 1
  fi
  if ! run_logged "$install_log" env DESTDIR="$stage" ninja -C "$build" install; then
    warn "$name: staged install failed; see $install_log"
    return 1
  fi
  if [[ ! -d "$stage$PREFIX/lib/sparcv9" ]] ||
     [[ -z "$(find "$stage$PREFIX/lib/sparcv9" -name 'libGL.so*' -print -quit)" ]]; then
    warn "$name: staged install contains no 64-bit Mesa libGL; refusing to activate."
    return 1
  fi
  # Never activate a partially built or installed tree.
  mv "$stage$PREFIX" "$PREFIX"
  printf '%s\n' "$name" > "$PREFIX/BUILD-MODE.txt"
  info "$name: successful staged build and install: $PREFIX"
  return 0
}

BUILT=0
if [[ "$MODE" == experimental ]]; then
  if try_build experimental; then
    BUILT=1
  elif (( ALLOW_FALLBACK )); then
    warn 'Full Nouveau/Lavapipe build unavailable. Falling back to swrast only.'
  else
    echo 'ERROR: Experimental build failed; fallback disabled.' >&2
    exit 1
  fi
fi
if (( ! BUILT )); then
  if ! try_build software; then
    echo 'ERROR: Neither experimental nor software-only Mesa could be built.' >&2
    echo "Examine $WORK/*-configure.log and $WORK/*-build.log" >&2
    exit 1
  fi
fi

info 'Configuring opt-only environment and test tools'
# Install using a stable /opt/mesa alias if that pathname is not already used.
if [[ ! -e /opt/mesa && ! -L /opt/mesa ]]; then
  ln -s "$PREFIX" /opt/mesa
elif [[ -L /opt/mesa && "$(readlink /opt/mesa)" == "$PREFIX" ]]; then
  :
else
  warn '/opt/mesa already exists and is not changed; use the versioned prefix.'
fi

cat > "$PREFIX/mesa-env.sh" <<'ENV'
# Source this file in sh/bash/ksh: . /opt/mesa-21.3.8-solaris/mesa-env.sh
MESA_ROOT=/opt/mesa-21.3.8-solaris
case ":${LD_LIBRARY_PATH_64:-}:" in
  *":$MESA_ROOT/lib/sparcv9:"*) ;;
  *) LD_LIBRARY_PATH_64="$MESA_ROOT/lib/sparcv9:/usr/llvm/13/lib/sparcv9:/usr/lib/xorg/sparcv9${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}" ;;
esac
LIBGL_DRIVERS_PATH="$MESA_ROOT/lib/sparcv9/dri"
export MESA_ROOT LD_LIBRARY_PATH_64 LIBGL_DRIVERS_PATH
# Only advertise a Lavapipe ICD if this build actually installed one.
for _mesa_icd in "$MESA_ROOT"/share/vulkan/icd.d/*lvp*.json; do
  if [ -f "$_mesa_icd" ]; then
    VK_ICD_FILENAMES="$_mesa_icd"
    export VK_ICD_FILENAMES
    break
  fi
done
unset _mesa_icd
ENV

mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/mesa-run" <<'RUN'
#!/usr/bin/env bash
set -e
. /opt/mesa-21.3.8-solaris/mesa-env.sh
exec "$@"
RUN
cat > "$PREFIX/bin/mesa-check" <<'CHECK'
#!/usr/bin/env bash
set -u
. /opt/mesa-21.3.8-solaris/mesa-env.sh
printf 'Build mode: '
cat "$MESA_ROOT/BUILD-MODE.txt"
printf '\nGallium driver modules:\n'
find "$MESA_ROOT/lib/sparcv9" \( -name '*_dri.so' -o -name '*nouveau*.so' \) -print
printf '\nVulkan ICDs:\n'
find "$MESA_ROOT" -name '*lvp*.json' -print
printf '\nKernel DRM devices:\n'
ls -l /dev/dri 2>/dev/null || echo 'No /dev/dri available'
printf '\nOpenGL renderer (requires X11 DISPLAY and glxinfo):\n'
if command -v glxinfo >/dev/null 2>&1; then glxinfo -B || :; else echo 'glxinfo not installed'; fi
printf '\nVulkan driver (requires loader and vulkaninfo):\n'
if command -v vulkaninfo >/dev/null 2>&1; then vulkaninfo --summary || :; else echo 'vulkaninfo not installed'; fi
CHECK
chmod 0755 "$PREFIX/bin/mesa-run" "$PREFIX/bin/mesa-check"

if (( SET_USER_DEFAULT )) && [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]]; then
  info "Selecting $PREFIX for new shell sessions of $TARGET_USER"
  # Existing dotfiles only; .profile is created when none exists.
  profiles=("$TARGET_HOME/.profile")
  for file in "$TARGET_HOME/.bash_profile" "$TARGET_HOME/.bashrc" "$TARGET_HOME/.zshrc"; do
    [[ -f "$file" ]] && profiles+=("$file")
  done
  for file in "${profiles[@]}"; do
    if [[ ! -e "$file" ]]; then
      : > "$file"
      chown "$TARGET_USER" "$file"
    fi
    if ! grep -Fq '# >>> mesa-21.3.8-solaris >>>' "$file"; then
      cat >> "$file" <<'PROFILE'

# >>> mesa-21.3.8-solaris >>>
if [ -r /opt/mesa-21.3.8-solaris/mesa-env.sh ]; then
  . /opt/mesa-21.3.8-solaris/mesa-env.sh
fi
# <<< mesa-21.3.8-solaris <<<
PROFILE
    fi
  done
else
  warn 'No login profile changed; manually source the installed mesa-env.sh.'
fi

info 'Final installation inventory'
find "$PREFIX/lib/sparcv9" \( -name 'libGL.so*' -o -name '*_dri.so' -o -name '*nouveau*.so' \) -print
find "$PREFIX" -name '*lvp*.json' -print
printf '\nINSTALL COMPLETE: %s\n' "$PREFIX"
printf 'Build mode: %s\n' "$(cat "$PREFIX/BUILD-MODE.txt")"
printf 'Logs: %s\n' "$WORK"
printf 'Test in your X session: %s/bin/mesa-check\n' "$PREFIX"
printf 'Run individual GL programs: %s/bin/mesa-run glxinfo -B\n' "$PREFIX"
printf 'Revert shell defaults: remove the marked mesa-21.3.8-solaris block from ~/.profile (and any applicable ~/.bashrc / ~/.bash_profile / ~/.zshrc).\n'
warn 'Nouveau needs a separate working Solaris kernel DRM driver. Lavapipe needs a usable Vulkan loader. OpenGL 4.6 is not guaranteed on SPARC.'
