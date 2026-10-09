# Solaris build and WSI source patches

All patches are **targeted, idempotent Python source transformations**, not
binary replacements. They check specific source anchors, preserve first-run
backups, and refuse unexpected source layouts. They are intended for the tested
Oracle Solaris Userland **Mesa 21.3.8** sources and Khronos Loader **1.3.250**.

The default [`../scripts/install-mesa-lavapipe.sh`](../scripts/install-mesa-lavapipe.sh)
invokes, before configuration/compilation:

1. `apply-rgtc.py` — fix Solaris `char` versus `signed char` mismatches.
2. `apply-lavapipe-x11-link.py` — link required XCB libraries explicitly.
3. `apply-wsi-no-fd.py` — allow software no-SHM WSI allocations without an
   unnecessary exportable file descriptor. **Validated on SPARC**: fixed
   `vkCreateSwapchainKHR` returning -2.
4. `apply-wsi-msbfirst-colors.py` — conditional byte-order correction for
   software WSI on X11 `MSBFirst`, 32-bit images. **Validated on SPARC**:
   removed bright-blue background and distorted faces.

`apply-vulkan-loader-solaris.py` is run by the Vulkan loader installer and
adapts platform detection/macros and the Solaris `/proc` executable path.

The MSBFirst patch can be disabled at runtime with:

```bash
MESA_SOLARIS_LVP_WSI_BYTESWAP=0 /opt/vk-rotating-block/bin/run.sh \
  --api 1.2 --present wsi
```

If running the original unpatched Lavapipe driver, this may fail at swapchain
creation instead of exhibiting a color difference. The old `legacy/` scripts
create separate *test* ICD manifests and require a pre-existing configured
Mesa build tree; they are preserved for debugging and review.

These are **experimental downstream patches**. In particular, the color
conversion is correct for the observed 32bpp MSBFirst BGRA/XRGB combination,
not a universal pixel-conversion implementation for all visuals/OSes.
