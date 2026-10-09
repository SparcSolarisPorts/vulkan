#!/usr/bin/env bash
# Test the Vulkan instance API request modes and X11 DRI3 / WSI capabilities.
# No sudo required; WSI tests need access to your X11 desktop session.
set -uo pipefail
PREFIX=${APP_PREFIX:-/opt/vk-rotating-block}
RUN="$PREFIX/bin/run.sh"
if [[ ! -x "$RUN" ]]; then
  HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  RUN="$HERE/run.sh"
fi
status=0
for api in 1.0 1.1 1.2; do
  echo
  echo "===== Vulkan API $api: offscreen allocation probe ====="
  "$RUN" --probe --api "$api"
  rc=$?
  echo "API $api returned exit status $rc"
  if [[ $rc -ne 0 ]]; then status=1; fi
done
printf '\n===== X11 DRI3 extension probe =====\n'
"$RUN" --dri3-probe
rc=$?
echo "DRI3 check returned exit status $rc (3 means DRI3 absent)"
printf '\n===== Vulkan 1.2 Xlib WSI/swapchain probe =====\n'
"$RUN" --api 1.2 --wsi-probe
rc=$?
echo "WSI probe returned exit status $rc (4 means setup failed)"
printf '\n===== Summary =====\n'
echo 'API mode failures indicate an instance/device compatibility or allocation issue.'
echo 'Missing DRI3 is an X-server limitation, not something --api enables.'
echo 'WSI failure does not invalidate the original XPutImage offscreen demo.'
exit "$status"
