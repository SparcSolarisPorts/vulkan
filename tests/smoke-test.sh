#!/usr/bin/env bash
# Read-only functional probes: run as graphical user, never sudo.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_PREFIX=${APP_PREFIX:-/opt/vk-rotating-block}
MESA_PREFIX=${MESA_PREFIX:-/opt/mesa-lavapipe-21.3.8-wsi}
SHADERC_PREFIX=${SHADERC_PREFIX:-/opt/shaderc-2025.4}
if [[ $(id -u) == 0 ]]; then echo 'Run tests as your graphical user (no sudo).' >&2; exit 2; fi
RUN="$APP_PREFIX/bin/run.sh"
[[ -x "$RUN" ]] || RUN="$HERE/demo/run.sh"
status=0
for version in 1.0 1.1 1.2; do
 printf '\n== Vulkan API %s offscreen probe ==\n' "$version"
 "$RUN" --api "$version" --probe || status=1
done
printf '\n== X11 extensions (DRI3 can be absent) ==\n'
"$RUN" --dri3-probe || :
printf '\n== Vulkan Xlib WSI surface/swapchain creation ==\n'
"$RUN" --api 1.2 --wsi-probe || status=1
printf '\n== Shaderc GLSL -> SPIR-V (if installed) ==\n'
if [[ -x "$SHADERC_PREFIX/bin/glslc" ]]; then
  f=$(mktemp -d "${TMPDIR:-/var/tmp}/shaderc-probe.XXXXXXXX") || exit 2
  trap 'rm -rf "$f"' EXIT
  cat > "$f/test.vert" <<'GLSL'
#version 450
void main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); }
GLSL
  "$SHADERC_PREFIX/bin/glslc" -fshader-stage=vert "$f/test.vert" -o "$f/test.spv" && test -s "$f/test.spv" || status=1
else
  echo "Shaderc not installed under $SHADERC_PREFIX: skipping compiler test"
fi
printf '\n== OpenGL software renderer (optional) ==\n'
if command -v glxinfo >/dev/null 2>&1 && [[ -x "$MESA_PREFIX/bin/mesa-run" ]]; then
  "$MESA_PREFIX/bin/mesa-run" glxinfo -B || :
fi
if [[ $status == 0 ]]; then
 echo 'Core Vulkan tests passed. Run GUI presentation separately.'
else
 echo 'One or more core probes failed. Check exact Vulkan error above.' >&2
fi
exit "$status"
