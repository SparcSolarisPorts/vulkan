# Solaris/SPARC rotating Vulkan block — Vulkan API 1.0, 1.1, 1.2 + optional WSI

Standalone C source for Oracle Solaris 11.4/SPARC T8-1, GCC 15, Vulkan Loader
1.3.250 in `/opt/vulkan-1.3.250`, and Lavapipe in
`/opt/mesa-lavapipe-21.3.8`.

**The default remains the known-working path:** Vulkan creates a CPU-backed
RGBA8 image, renders the rotating block with Vulkan `vkCmdClearAttachments`,
transfers pixels with `vkCmdCopyImageToBuffer`, then displays them through
Xlib `XPutImage`. It does not need the DRI3 extension or a Vulkan swapchain.
This is not a triangle/shader Vulkan rendering benchmark.

The optional WSI mode creates a genuine `VK_KHR_xlib_surface` and
`VK_KHR_swapchain` and attempts to render the same rotating block directly
into swapchain images, using Vulkan's FIFO presentation mode. The WSI mode
is **experimental** and may fail on your Solaris X server because the
server does not currently advertise DRI3. Failure is reported with the
specific Vulkan call and return code; the default working mode remains intact.

## Install

Unzip, then:

```sh
cd vk-rotating-block-solaris
sudo bash build.sh
```

This overwrites **only the demo** under `/opt/vk-rotating-block`.
It does not replace Mesa, the Vulkan loader, Xorg or your SSH settings.

## Run version-specific tests

From your graphical login, as your regular user (not sudo):

```sh
# Vulkan instance API 1.1, offscreen allocation check (no X11)
/opt/vk-rotating-block/bin/run.sh --probe --api 1.1

# Vulkan instance API 1.2, offscreen allocation check
/opt/vk-rotating-block/bin/run.sh --probe --api 1.2

# Vulkan 1.1 and 1.2 rotating cube, using working Vulkan->XPutImage path
/opt/vk-rotating-block/bin/run.sh --api 1.1 --present readback
/opt/vk-rotating-block/bin/run.sh --api 1.2 --present readback

# See whether X server exposes DRI3 (returns 3 when absent)
/opt/vk-rotating-block/bin/run.sh --dri3-probe

# Attempt real Vulkan Xlib surface and swapchain, without rendering
/opt/vk-rotating-block/bin/run.sh --api 1.2 --wsi-probe

# Require Vulkan Xlib swapchain to render, fail if unavailable
/opt/vk-rotating-block/bin/run.sh --api 1.2 --present wsi

# Try swapchain, fall back to offscreen readback if setup fails
/opt/vk-rotating-block/bin/run.sh --api 1.2 --present auto

# Run all short non-graphical / WSI setup tests at once
/opt/vk-rotating-block/bin/test-modes.sh
```

If the display is not automatically set, `run.sh` sets `DISPLAY=:0` for
GUI/WSI tests. You must have X11 authorization (same graphical user).
`--probe` does not need an X server.

Close graphical demos with **Q** or **Escape**. Use `--fps 8 --width 400
--height 300` for slower machines.

## Important version distinction

`--api 1.1` and `--api 1.2` change only the application's
`VkApplicationInfo.apiVersion` during `vkCreateInstance`. They do **not**
upgrade the loader or the Lavapipe ICD. The application prints the device's
actual Vulkan API version independently. The actual drawing operations here
are Vulkan 1.0 commands valid in these versions.

Your Lavapipe ICD negotiates loader/driver interface version 4 and has
previously emitted a Vulkan 1.1+ interface warning even while reporting device
API 1.2.195. Trying `--api 1.1` / `--api 1.2` can expose genuine API version
compatibility failures. Do not suppress the warning or assume that a successful
1.0 probe establishes full 1.2 conformance.

An X11 server advertising Present/MIT-SHM but no DRI3 cannot be forced to
support DRI3 by a Vulkan application's arguments. Vulkan Xlib WSI may work
without DRI3 in a software-specific path; only the surface/swapchain test can
establish whether your installed implementation supports it.

## Troubleshooting

If you encounter `VK_ERROR_OUT_OF_DEVICE_MEMORY (-2)`, check **which call**
reported it (`vkCreateImage`, `vkAllocateMemory`, `vkCreateSwapchainKHR` etc.).
The Vulkan result by itself does not prove physical RAM exhaustion.

Capture diagnostics:

```sh
VK_LOADER_DEBUG=all /opt/vk-rotating-block/bin/run.sh --api 1.2 --wsi-probe \
  > "$HOME/vulkan-wsi-probe.log" 2>&1
```

If `--present wsi` fails, `--present readback` remains the safe working mode.
WSI support is not required for running the offscreen renderer.

This project is for functionality testing; it does not claim Vulkan 1.2
conformance, does not require Shaderc, and is not a 3D shader pipeline benchmark.
