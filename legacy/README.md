# Historical installer and diagnostic scripts

This folder preserves the exact scripts used during the SPARC porting sequence:
loader 1.3.250, Mesa 21.3.8 build iterations v4/v5/v6, Shaderc attempt,
working no-FD WSI patch and MSBFirst pixel-color experiment.

**Do not run all these in sequence.** Versions v4/v5/v6 predate the successful
WSI fixes and may build a Vulkan ICD that fails `vkCreateSwapchainKHR`.
The top-level `scripts/install-all.sh` and `scripts/install-mesa-lavapipe.sh`
apply both proven WSI patches during initial compilation. The legacy scripts
are reference material and regression/debugging tools only. They hardcode
SPARC paths and must not be treated as universal x86 installers.

The two `test-mesa...` scripts depend on a previously configured Mesa tree at
`/var/tmp/mesa-solaris-21.3.8-work/build-mesa-lavapipe-x11-v4`; they will
not bootstrap a fresh source checkout. The standalone patches under
`patches/` work with the new installer instead.
