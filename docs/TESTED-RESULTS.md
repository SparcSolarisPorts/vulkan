# Observed test results (Solaris 11.4, SPARC T8-1)

This is a record of the **user-reported terminal output**, not a conformance certificate.

- CPU: SPARC T8-1; Solaris 11.4.90.212.0 (from test environment notes).
- GCC 15.2; LLVM 13.0.1.
- Vulkan Loader: 1.3.250 under `/opt/vulkan-1.3.250`.
- Mesa: Oracle-patched 21.3.8 with Lavapipe; the ICD reports `llvmpipe (LLVM 13.0.1, 128 bits)` and Vulkan device API 1.2.195.
- The original offscreen demo successfully created device, image, and readback buffer, and drew the cube into an X11 window through `XPutImage`.
- Requested Vulkan instance API 1.0, 1.1, 1.2: basic initialization tests all passed. This does **not** establish Vulkan conformance at these levels.
- `xdpyinfo`: `DRI3=NO`, `Present=yes`, `MIT-SHM=yes`, `image byte order=MSBFirst`.
- `vkCreateXlibSurfaceKHR`, `vkGetPhysicalDeviceSurfaceSupportKHR` (present=yes), and `vkGetPhysicalDeviceSurfaceCapabilitiesKHR` returned `VK_SUCCESS`.
- Unpatched Mesa: `vkCreateSwapchainKHR = -2` (`VK_ERROR_OUT_OF_DEVICE_MEMORY`).
- Patched `wsi_common_drm.c`: `vkCreateSwapchainKHR = 0`, three images, format 44 or 50.
- Patched `wsi_common_x11.c` to reorder bytes in the software 32-bpp XPutImage path on MSBFirst X11: visible pixel colors improved; the screenshot confirmed expected sRGB gamma behavior.
- Direct WSI demo: 12.2 FPS at a target of ~12 FPS; `vkQueuePresentKHR` ran during continuous animation, even though DRI3 was absent.
- Loader warning: ICD advertises API 1.1+ but implements loader/driver interface version 4; interface >=5 expected. Successful demos do not resolve that warning.
- The demo sometimes printed `X connection to :0 broken (explicit kill or server shutdown)` on exit; cause not established.

**x86-64:** scripts include a Solaris x86-64 build path but no successful x86 run is established by the SPARC evidence above. No official proprietary NVIDIA x86 driver testing is claimed.

**ARM:** untested, not an advertised working target.

**Mesa 24:** reported separately by the project author as functional from a Python-driven experiment. This repository does not include those Python sources or reproduce that result. The installed Solaris libdrm version is a practical barrier to enabling certain newer Mesa DRM-backed drivers; it does not imply Mesa 24 cannot execute any software driver. See the compatibility section in the root README.
