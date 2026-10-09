/*
 * Solaris/SPARC Lavapipe Vulkan rotating cube, displayed with Xlib.
 *
 * Display mode: offscreen readback (default) or optional real Vulkan Xlib WSI/swapchain.
 * Actual colored cube faces are rasterized by Vulkan vkCmdClearAttachments
 * into a VK_FORMAT_R8G8B8A8_UNORM image; a Vulkan image->buffer transfer
 * provides RGBA pixels, and XPutImage displays them in an ordinary X11 window.
 *
 * A scanline clear rectangle is issued per polygon row. This is a Vulkan
 * graphics-command demonstration, not a shader/triangle-pipeline benchmark.
 * Vulkan core-1.0 commands, with selectable application API 1.0/1.1/1.2.
 *
 * Copyright (c) 2026. MIT-licensed; see LICENSE.
 */
#define _POSIX_C_SOURCE 200809L
#define __EXTENSIONS__ 1
#include <X11/Xlib.h>
#define VK_USE_PLATFORM_XLIB_KHR 1
#include <vulkan/vulkan.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MIN_(a,b) ((a) < (b) ? (a) : (b))
#define MAX_(a,b) ((a) > (b) ? (a) : (b))
#define CHECK_VK(expr) do { VkResult _r = (expr); if (_r != VK_SUCCESS) { \
    fprintf(stderr, "VULKAN ERROR at %s:%d: %s returned %d (%s)\n", \
        __FILE__, __LINE__, #expr, (int)_r, vk_error_name(_r)); exit(1); \
} } while (0)

typedef struct { float x, y, z; } Vec3;
typedef struct { float x, y; } Vec2;
typedef struct { int idx[4]; float depth; float rgb[3]; } Face;

typedef struct {
    int width, height, fps;
    uint32_t requested_api;
    int present; /* 0 = XPutImage readback, 1 = Vulkan Xlib WSI required, 2 = WSI auto/fallback */
    int wsi_active;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat swap_format;
    VkRenderPass wsi_render_pass;
    VkImage *wsi_images;
    VkImageView *wsi_views;
    VkFramebuffer *wsi_fbs;
    uint32_t wsi_count;
    VkSemaphore acquire_semaphore;
    VkSemaphore render_semaphore;
    VkInstance instance;
    VkPhysicalDevice physical;
    VkPhysicalDeviceMemoryProperties mem_props;
    VkDevice device;
    uint32_t queue_family;
    VkQueue queue;
    VkImage image;
    VkDeviceMemory image_mem;
    VkImageView image_view;
    VkRenderPass render_pass;
    VkFramebuffer framebuffer;
    VkBuffer readback;
    VkDeviceMemory readback_mem;
    void *readback_ptr;
    int readback_coherent;
    VkCommandPool command_pool;
    VkCommandBuffer command;
    VkFence fence;
    Display *display;
    Window window;
    GC gc;
    XImage *ximage;
    int xscreen;
    unsigned long red_mask, green_mask, blue_mask;
} App;

static const char *vk_error_name(VkResult r) {
    switch (r) {
    case VK_SUCCESS: return "VK_SUCCESS";
    case VK_ERROR_OUT_OF_HOST_MEMORY: return "VK_ERROR_OUT_OF_HOST_MEMORY";
    case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
    case VK_ERROR_INITIALIZATION_FAILED: return "VK_ERROR_INITIALIZATION_FAILED";
    case VK_ERROR_DEVICE_LOST: return "VK_ERROR_DEVICE_LOST";
    case VK_ERROR_INCOMPATIBLE_DRIVER: return "VK_ERROR_INCOMPATIBLE_DRIVER";
    case VK_ERROR_FEATURE_NOT_PRESENT: return "VK_ERROR_FEATURE_NOT_PRESENT";
    case VK_ERROR_FORMAT_NOT_SUPPORTED: return "VK_ERROR_FORMAT_NOT_SUPPORTED";
    default: return "unknown VkResult";
    }
}

static uint32_t find_mem_type(App *a, uint32_t bits, VkMemoryPropertyFlags flags) {
    for (uint32_t i = 0; i < a->mem_props.memoryTypeCount; ++i) {
        if ((bits & (1u << i)) &&
            (a->mem_props.memoryTypes[i].propertyFlags & flags) == flags)
            return i;
    }
    return UINT32_MAX;
}

static int has_instance_extension(const char *want) {
    uint32_t count = 0;
    if (vkEnumerateInstanceExtensionProperties(NULL, &count, NULL) != VK_SUCCESS) return 0;
    VkExtensionProperties *xs = calloc(count ? count : 1, sizeof(*xs));
    if (!xs) return 0;
    VkResult r = vkEnumerateInstanceExtensionProperties(NULL, &count, xs);
    int found = 0;
    if (r == VK_SUCCESS) for (uint32_t i = 0; i < count; ++i)
        if (strcmp(xs[i].extensionName, want) == 0) found = 1;
    free(xs);
    return found;
}
static int has_device_extension(VkPhysicalDevice phys, const char *want) {
    uint32_t count = 0;
    if (vkEnumerateDeviceExtensionProperties(phys, NULL, &count, NULL) != VK_SUCCESS) return 0;
    VkExtensionProperties *xs = calloc(count ? count : 1, sizeof(*xs));
    if (!xs) return 0;
    VkResult r = vkEnumerateDeviceExtensionProperties(phys, NULL, &count, xs);
    int found = 0;
    if (r == VK_SUCCESS) for (uint32_t i = 0; i < count; ++i)
        if (strcmp(xs[i].extensionName, want) == 0) found = 1;
    free(xs);
    return found;
}
static void disable_wsi_or_die(App *a, const char *why) {
    fprintf(stderr, "Vulkan X11 WSI unavailable: %s\n", why);
    if (a->present == 1) {
        fprintf(stderr, "--present wsi requires working Vulkan Xlib surface/swapchain.\n");
        exit(2);
    }
    fprintf(stderr, "Falling back to Vulkan offscreen rendering and XPutImage.\n");
    a->present = 0;
}
static void init_vulkan(App *a) {
    VkApplicationInfo ai = {0};
    ai.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    ai.pApplicationName = "SPARC Vulkan rotating block";
    ai.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    ai.pEngineName = "Vulkan clear rectangles / Xlib readback";
    ai.apiVersion = a->requested_api;
    fprintf(stderr, "Requesting Vulkan instance API %u.%u (not changing ICD/device capabilities).\n",
            VK_VERSION_MAJOR(ai.apiVersion), VK_VERSION_MINOR(ai.apiVersion));
    VkInstanceCreateInfo ici = {0};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &ai;
    const char *ix[2] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_XLIB_SURFACE_EXTENSION_NAME };
    if (a->present != 0) {
        if (!has_instance_extension(ix[0]) || !has_instance_extension(ix[1]))
            disable_wsi_or_die(a, "VK_KHR_surface or VK_KHR_xlib_surface instance extension missing");
        else { ici.enabledExtensionCount = 2; ici.ppEnabledExtensionNames = ix; }
    }
    CHECK_VK(vkCreateInstance(&ici, NULL, &a->instance));

    uint32_t count = 0;
    CHECK_VK(vkEnumeratePhysicalDevices(a->instance, &count, NULL));
    if (!count) {
        fprintf(stderr, "No Vulkan physical device. Check VK_ICD_FILENAMES and Lavapipe installation.\n");
        exit(2);
    }
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices) exit(3);
    CHECK_VK(vkEnumeratePhysicalDevices(a->instance, &count, devices));
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t families = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, NULL);
        VkQueueFamilyProperties *q = calloc(families ? families : 1, sizeof(*q));
        if (!q) exit(3);
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, q);
        for (uint32_t j = 0; j < families; ++j) {
            if (q[j].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                VkFormatProperties fp;
                vkGetPhysicalDeviceFormatProperties(devices[i], VK_FORMAT_R8G8B8A8_UNORM, &fp);
                if (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) {
                    a->physical = devices[i];
                    a->queue_family = j;
                    break;
                }
            }
        }
        free(q);
        if (a->physical) break;
    }
    free(devices);
    if (!a->physical) {
        fprintf(stderr, "No Vulkan graphics queue with RGBA8 color attachment support.\n");
        exit(2);
    }
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(a->physical, &props);
    fprintf(stderr, "Vulkan physical device: %s (API %u.%u.%u)\n",
        props.deviceName, VK_VERSION_MAJOR(props.apiVersion),
        VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion));
    fprintf(stderr, "Graphics queue family: %u\n", a->queue_family);
    if (VK_VERSION_MAJOR(props.apiVersion) < VK_VERSION_MAJOR(a->requested_api) ||
        (VK_VERSION_MAJOR(props.apiVersion) == VK_VERSION_MAJOR(a->requested_api) &&
         VK_VERSION_MINOR(props.apiVersion) < VK_VERSION_MINOR(a->requested_api))) {
        fprintf(stderr, "Device supports a lower Vulkan API version than requested; refusing.\n");
        exit(2);
    }
    if (a->present != 0 && !has_device_extension(a->physical, VK_KHR_SWAPCHAIN_EXTENSION_NAME))
        disable_wsi_or_die(a, "VK_KHR_swapchain device extension missing");
    vkGetPhysicalDeviceMemoryProperties(a->physical, &a->mem_props);

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = {0};
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = a->queue_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;
    VkDeviceCreateInfo dci = {0};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    const char *dx[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    if (a->present != 0) { dci.enabledExtensionCount = 1; dci.ppEnabledExtensionNames = dx; }
    CHECK_VK(vkCreateDevice(a->physical, &dci, NULL, &a->device));
    vkGetDeviceQueue(a->device, a->queue_family, 0, &a->queue);

    VkImageCreateInfo imci = {0};
    imci.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imci.imageType = VK_IMAGE_TYPE_2D;
    imci.format = VK_FORMAT_R8G8B8A8_UNORM;
    imci.extent.width = (uint32_t)a->width;
    imci.extent.height = (uint32_t)a->height;
    imci.extent.depth = 1;
    imci.mipLevels = 1;
    imci.arrayLayers = 1;
    imci.samples = VK_SAMPLE_COUNT_1_BIT;
    imci.tiling = VK_IMAGE_TILING_OPTIMAL;
    imci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    imci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    imci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    CHECK_VK(vkCreateImage(a->device, &imci, NULL, &a->image));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(a->device, a->image, &req);
    uint32_t mt = find_mem_type(a, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mt == UINT32_MAX) mt = find_mem_type(a, req.memoryTypeBits, 0);
    if (mt == UINT32_MAX) { fprintf(stderr, "No compatible image memory type.\n"); exit(2); }
    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = mt;
    CHECK_VK(vkAllocateMemory(a->device, &mai, NULL, &a->image_mem));
    CHECK_VK(vkBindImageMemory(a->device, a->image, a->image_mem, 0));

    VkImageViewCreateInfo ivci = {0};
    ivci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    ivci.image = a->image;
    ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    ivci.format = VK_FORMAT_R8G8B8A8_UNORM;
    ivci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    ivci.subresourceRange.levelCount = 1;
    ivci.subresourceRange.layerCount = 1;
    CHECK_VK(vkCreateImageView(a->device, &ivci, NULL, &a->image_view));

    VkAttachmentDescription att = {0};
    att.format = VK_FORMAT_R8G8B8A8_UNORM;
    att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    att.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference cref = {0};
    cref.attachment = 0;
    cref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    VkSubpassDescription sub = {0};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &cref;
    VkSubpassDependency dep[2] = {{0}};
    dep[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    dep[0].dstSubpass = 0;
    dep[0].srcStageMask = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    dep[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dep[1].srcSubpass = 0;
    dep[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    dep[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep[1].dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
    dep[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dep[1].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    VkRenderPassCreateInfo rpci = {0};
    rpci.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpci.attachmentCount = 1;
    rpci.pAttachments = &att;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &sub;
    rpci.dependencyCount = 2;
    rpci.pDependencies = dep;
    CHECK_VK(vkCreateRenderPass(a->device, &rpci, NULL, &a->render_pass));
    VkFramebufferCreateInfo fbci = {0};
    fbci.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fbci.renderPass = a->render_pass;
    fbci.attachmentCount = 1;
    fbci.pAttachments = &a->image_view;
    fbci.width = (uint32_t)a->width;
    fbci.height = (uint32_t)a->height;
    fbci.layers = 1;
    CHECK_VK(vkCreateFramebuffer(a->device, &fbci, NULL, &a->framebuffer));

    VkDeviceSize bytes = (VkDeviceSize)a->width * (VkDeviceSize)a->height * 4u;
    VkBufferCreateInfo bci = {0};
    bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = bytes;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    CHECK_VK(vkCreateBuffer(a->device, &bci, NULL, &a->readback));
    vkGetBufferMemoryRequirements(a->device, a->readback, &req);
    mt = find_mem_type(a, req.memoryTypeBits,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mt == UINT32_MAX)
        mt = find_mem_type(a, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    if (mt == UINT32_MAX) { fprintf(stderr, "No host-visible readback memory type.\n"); exit(2); }
    a->readback_coherent = !!(a->mem_props.memoryTypes[mt].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = mt;
    CHECK_VK(vkAllocateMemory(a->device, &mai, NULL, &a->readback_mem));
    CHECK_VK(vkBindBufferMemory(a->device, a->readback, a->readback_mem, 0));
    CHECK_VK(vkMapMemory(a->device, a->readback_mem, 0, VK_WHOLE_SIZE, 0, &a->readback_ptr));

    VkCommandPoolCreateInfo cpci = {0};
    cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = a->queue_family;
    CHECK_VK(vkCreateCommandPool(a->device, &cpci, NULL, &a->command_pool));
    VkCommandBufferAllocateInfo cbai = {0};
    cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool = a->command_pool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    CHECK_VK(vkAllocateCommandBuffers(a->device, &cbai, &a->command));
    VkFenceCreateInfo fci = {0};
    fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    CHECK_VK(vkCreateFence(a->device, &fci, NULL, &a->fence));
    fprintf(stderr, "Vulkan resources allocated: %dx%d RGBA8 offscreen, %.2f MiB readback.\n",
        a->width, a->height, (double)bytes / (1024.0 * 1024.0));
}

static void init_x11(App *a) {
    a->display = XOpenDisplay(NULL);
    if (!a->display) {
        fprintf(stderr, "XOpenDisplay failed. Set DISPLAY=:0 and run as the graphical desktop user.\n");
        exit(2);
    }
    a->xscreen = DefaultScreen(a->display);
    Visual *visual = DefaultVisual(a->display, a->xscreen);
    a->red_mask = visual->red_mask;
    a->green_mask = visual->green_mask;
    a->blue_mask = visual->blue_mask;
    a->window = XCreateSimpleWindow(a->display, RootWindow(a->display, a->xscreen),
        30, 30, (unsigned)a->width, (unsigned)a->height, 0,
        BlackPixel(a->display, a->xscreen), BlackPixel(a->display, a->xscreen));
    XSelectInput(a->display, a->window, ExposureMask | KeyPressMask | StructureNotifyMask);
    XStoreName(a->display, a->window, "Vulkan Lavapipe rotating block - Solaris SPARC");
    XSizeHints hint = {0};
    hint.flags = PMinSize | PMaxSize;
    hint.min_width = hint.max_width = a->width;
    hint.min_height = hint.max_height = a->height;
    XSetWMNormalHints(a->display, a->window, &hint);
    XMapWindow(a->display, a->window);
    a->gc = XCreateGC(a->display, a->window, 0, NULL);
    a->ximage = XCreateImage(a->display, visual,
        (unsigned)DefaultDepth(a->display, a->xscreen), ZPixmap, 0, NULL,
        (unsigned)a->width, (unsigned)a->height, 32, 0);
    if (!a->ximage) { fprintf(stderr, "XCreateImage failed.\n"); exit(2); }
    a->ximage->data = calloc((size_t)a->ximage->bytes_per_line, (size_t)a->height);
    if (!a->ximage->data) { fprintf(stderr, "Out of host memory for XImage.\n"); exit(2); }
    fprintf(stderr, "X11 display %s; %dbpp pixel format; DRI3 not required.\n",
        DisplayString(a->display), a->ximage->bits_per_pixel);
}

/* DRI3 is a server extension; Vulkan Xlib surface availability is a separate check. */
static int probe_dri3(Display *display) {
    int major = 0, first_event = 0, first_error = 0;
    int dri3 = XQueryExtension(display, "DRI3", &major, &first_event, &first_error);
    int present = XQueryExtension(display, "Present", &major, &first_event, &first_error);
    int shm = XQueryExtension(display, "MIT-SHM", &major, &first_event, &first_error);
    fprintf(stderr, "X11 extensions: DRI3=%s, Present=%s, MIT-SHM=%s\n",
        dri3 ? "yes" : "NO", present ? "yes" : "no", shm ? "yes" : "no");
    return dri3;
}

static int init_wsi(App *a) {
    if (!a->display || a->present == 0) return 0;
    int dri3 = probe_dri3(a->display);
    if (!dri3) fprintf(stderr, "NOTE: DRI3 absent. Software Lavapipe WSI may still work, but is not guaranteed.\n");
    VkXlibSurfaceCreateInfoKHR sci = {0};
    sci.sType = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
    sci.dpy = a->display;
    sci.window = a->window;
    VkResult r = vkCreateXlibSurfaceKHR(a->instance, &sci, NULL, &a->surface);
    fprintf(stderr, "vkCreateXlibSurfaceKHR: %d (%s)\n", (int)r, vk_error_name(r));
    if (r != VK_SUCCESS) return 0;
    VkBool32 supports = VK_FALSE;
    r = vkGetPhysicalDeviceSurfaceSupportKHR(a->physical, a->queue_family, a->surface, &supports);
    fprintf(stderr, "vkGetPhysicalDeviceSurfaceSupportKHR: %d, present support=%u\n", (int)r, supports);
    if (r != VK_SUCCESS || !supports) return 0;
    VkSurfaceCapabilitiesKHR cap;
    r = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(a->physical, a->surface, &cap);
    fprintf(stderr, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR: %d\n", (int)r);
    if (r != VK_SUCCESS) return 0;
    if (!(cap.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {
        fprintf(stderr, "Surface does not support color attachments.\n"); return 0;
    }
    uint32_t n = 0;
    r = vkGetPhysicalDeviceSurfaceFormatsKHR(a->physical, a->surface, &n, NULL);
    if (r != VK_SUCCESS || !n) { fprintf(stderr, "No surface formats: %d\n", (int)r); return 0; }
    VkSurfaceFormatKHR *formats = calloc(n, sizeof(*formats));
    if (!formats) return 0;
    r = vkGetPhysicalDeviceSurfaceFormatsKHR(a->physical, a->surface, &n, formats);
    if (r != VK_SUCCESS) { free(formats); return 0; }
    VkSurfaceFormatKHR chosen = formats[0];
    for (uint32_t i=0;i<n;i++) if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM &&
        formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) { chosen = formats[i]; break; }
    free(formats);
    if (chosen.format == VK_FORMAT_UNDEFINED) chosen.format = VK_FORMAT_B8G8R8A8_UNORM;
    VkFormatProperties fp;
    vkGetPhysicalDeviceFormatProperties(a->physical, chosen.format, &fp);
    if (!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)) {
        fprintf(stderr, "Chosen swapchain format lacks color attachment feature.\n"); return 0;
    }
    uint32_t w = (uint32_t)a->width, h = (uint32_t)a->height;
    if (cap.currentExtent.width != UINT32_MAX) {
        if (cap.currentExtent.width != w || cap.currentExtent.height != h) {
            fprintf(stderr, "Surface size mismatch: %ux%u versus %ux%u.\n",
                cap.currentExtent.width, cap.currentExtent.height, w, h); return 0;
        }
    } else if (w < cap.minImageExtent.width || h < cap.minImageExtent.height ||
        w > cap.maxImageExtent.width || h > cap.maxImageExtent.height) {
        fprintf(stderr, "Requested window size outside supported swapchain extents.\n"); return 0;
    }
    uint32_t image_count = cap.minImageCount < 2 ? 2 : cap.minImageCount;
    if (cap.maxImageCount > 0 && image_count > cap.maxImageCount) image_count = cap.maxImageCount;
    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (!(cap.supportedCompositeAlpha & alpha)) {
        for (unsigned b = 0; b < 32; ++b) if (cap.supportedCompositeAlpha & (1u << b)) {
            alpha = (VkCompositeAlphaFlagBitsKHR)(1u << b); break;
        }
    }
    VkSwapchainCreateInfoKHR ci = {0};
    ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    ci.surface = a->surface;
    ci.minImageCount = image_count;
    ci.imageFormat = chosen.format;
    ci.imageColorSpace = chosen.colorSpace;
    ci.imageExtent = (VkExtent2D){w,h};
    ci.imageArrayLayers = 1;
    ci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.preTransform = cap.currentTransform;
    ci.compositeAlpha = alpha;
    ci.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    ci.clipped = VK_TRUE;
    r = vkCreateSwapchainKHR(a->device, &ci, NULL, &a->swapchain);
    fprintf(stderr, "vkCreateSwapchainKHR: %d (%s)\n", (int)r, vk_error_name(r));
    if (r != VK_SUCCESS) return 0;
    a->swap_format = chosen.format;
    r = vkGetSwapchainImagesKHR(a->device, a->swapchain, &a->wsi_count, NULL);
    if (r != VK_SUCCESS || !a->wsi_count) return 0;
    a->wsi_images = calloc(a->wsi_count, sizeof(*a->wsi_images));
    a->wsi_views = calloc(a->wsi_count, sizeof(*a->wsi_views));
    a->wsi_fbs = calloc(a->wsi_count, sizeof(*a->wsi_fbs));
    if (!a->wsi_images || !a->wsi_views || !a->wsi_fbs) return 0;
    r = vkGetSwapchainImagesKHR(a->device, a->swapchain, &a->wsi_count, a->wsi_images);
    if (r != VK_SUCCESS) return 0;
    VkAttachmentDescription att = {0};
    att.format = chosen.format;
    att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    att.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference ref = {0};
    ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    VkSubpassDescription sub = {0};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &ref;
    VkSubpassDependency dep = {0};
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo rpc = {0};
    rpc.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpc.attachmentCount = 1; rpc.pAttachments = &att;
    rpc.subpassCount = 1; rpc.pSubpasses = &sub;
    rpc.dependencyCount = 1; rpc.pDependencies = &dep;
    r = vkCreateRenderPass(a->device, &rpc, NULL, &a->wsi_render_pass);
    if (r != VK_SUCCESS) { fprintf(stderr, "WSI renderpass failed: %d\n", (int)r); return 0; }
    for (uint32_t i = 0; i < a->wsi_count; ++i) {
        VkImageViewCreateInfo vi = {0};
        vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vi.image = a->wsi_images[i];
        vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
        vi.format = chosen.format;
        vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        vi.subresourceRange.levelCount = 1;
        vi.subresourceRange.layerCount = 1;
        r = vkCreateImageView(a->device, &vi, NULL, &a->wsi_views[i]);
        if (r != VK_SUCCESS) return 0;
        VkFramebufferCreateInfo fi = {0};
        fi.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fi.renderPass = a->wsi_render_pass;
        fi.attachmentCount = 1; fi.pAttachments = &a->wsi_views[i];
        fi.width = w; fi.height = h; fi.layers = 1;
        r = vkCreateFramebuffer(a->device, &fi, NULL, &a->wsi_fbs[i]);
        if (r != VK_SUCCESS) return 0;
    }
    VkSemaphoreCreateInfo si = {0}; si.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    if (vkCreateSemaphore(a->device, &si, NULL, &a->acquire_semaphore) != VK_SUCCESS) return 0;
    if (vkCreateSemaphore(a->device, &si, NULL, &a->render_semaphore) != VK_SUCCESS) return 0;
    a->wsi_active = 1;
    fprintf(stderr, "WSI SUCCESS: Vulkan Xlib swapchain has %u images, format %d.\n",
        a->wsi_count, (int)a->swap_format);
    return 1;
}

static Vec3 cube[8] = {
    {-1,-1,-1}, {1,-1,-1}, {1,1,-1}, {-1,1,-1},
    {-1,-1, 1}, {1,-1, 1}, {1,1, 1}, {-1,1, 1}
};
static const int face_indices[6][4] = {
    {4,5,6,7}, {1,0,3,2}, {0,4,7,3},
    {5,1,2,6}, {3,7,6,2}, {0,1,5,4}
};
static const float face_colors[6][3] = {
    {0.97f,0.35f,0.30f}, {0.63f,0.42f,0.95f},
    {0.32f,0.57f,0.99f}, {0.36f,0.86f,0.51f},
    {1.00f,0.80f,0.26f}, {0.26f,0.86f,0.84f}
};
static int face_compare(const void *a, const void *b) {
    float da = ((const Face*)a)->depth, db = ((const Face*)b)->depth;
    return (da > db) - (da < db);
}

static void clear_rect(VkCommandBuffer cmd, int x, int y, int w, int h, const float c[3]) {
    if (w <= 0 || h <= 0) return;
    VkClearAttachment att = {0};
    att.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    att.colorAttachment = 0;
    att.clearValue.color.float32[0] = c[0];
    att.clearValue.color.float32[1] = c[1];
    att.clearValue.color.float32[2] = c[2];
    att.clearValue.color.float32[3] = 1.0f;
    VkClearRect rect = {0};
    rect.rect.offset.x = x;
    rect.rect.offset.y = y;
    rect.rect.extent.width = (uint32_t)w;
    rect.rect.extent.height = (uint32_t)h;
    rect.layerCount = 1;
    vkCmdClearAttachments(cmd, 1, &att, 1, &rect);
}

/* Rasterize a convex polygon as horizontal Vulkan clear-rect commands. */
static void draw_face(App *a, const Vec2 quad[4], const float rgb[3]) {
    float miny = quad[0].y, maxy = quad[0].y;
    for (int i = 1; i < 4; ++i) {
        miny = fminf(miny, quad[i].y);
        maxy = fmaxf(maxy, quad[i].y);
    }
    int first = MAX_(0, (int)floorf(miny));
    int last = MIN_(a->height - 1, (int)ceilf(maxy));
    for (int y = first; y <= last; ++y) {
        float sx[4]; int n = 0; float scan_y = (float)y + 0.5f;
        for (int j = 0; j < 4; ++j) {
            Vec2 p = quad[j], q = quad[(j+1)%4];
            if ((p.y <= scan_y && q.y > scan_y) ||
                (q.y <= scan_y && p.y > scan_y)) {
                sx[n++] = p.x + (scan_y-p.y)*(q.x-p.x)/(q.y-p.y);
            }
        }
        if (n < 2) continue;
        float xlo = sx[0], xhi = sx[0];
        for (int j = 1; j < n; ++j) { xlo = fminf(xlo, sx[j]); xhi = fmaxf(xhi, sx[j]); }
        int x0 = MAX_(0, (int)ceilf(xlo - 0.5f));
        int x1 = MIN_(a->width - 1, (int)floorf(xhi - 0.5f));
        if (x0 <= x1) clear_rect(a->command, x0, y, x1-x0+1, 1, rgb);
    }
}

static void rotate_vertices(App *a, float angle, Vec2 points[8], Vec3 transformed[8]) {
    float cy = cosf(angle), sy = sinf(angle);
    float cx = cosf(angle*0.72f + 0.37f), sx = sinf(angle*0.72f + 0.37f);
    float cz = cosf(angle*0.23f), sz = sinf(angle*0.23f);
    float factor = 0.92f * (float)MIN_(a->width, a->height);
    for (int i = 0; i < 8; ++i) {
        Vec3 p = cube[i];
        float rx = p.x*cy + p.z*sy;
        float rz = -p.x*sy + p.z*cy;
        float ry = p.y*cx-rz*sx;
        float z = p.y*sx + rz*cx;
        float x = rx*cz-ry*sz;
        float y = rx*sz+ry*cz;
        transformed[i] = (Vec3){x,y,z};
        float invz = factor / (4.8f - z);
        points[i].x = 0.5f*(float)a->width + x*invz;
        points[i].y = 0.5f*(float)a->height - y*invz;
    }
}

static void render_frame(App *a, float angle, Vec2 projected[8]) {
    uint32_t wsi_index = 0;
    if (a->wsi_active) {
        VkResult acquire = vkAcquireNextImageKHR(a->device, a->swapchain, UINT64_MAX,
            a->acquire_semaphore, VK_NULL_HANDLE, &wsi_index);
        CHECK_VK(acquire);
    }
    Vec3 transformed[8];
    rotate_vertices(a, angle, projected, transformed);
    Face faces[6];
    for (int i = 0; i < 6; ++i) {
        faces[i].depth = 0.0f;
        for (int j = 0; j < 4; ++j) {
            faces[i].idx[j] = face_indices[i][j];
            faces[i].depth += transformed[faces[i].idx[j]].z * 0.25f;
        }
        float light = 0.66f + 0.15f * faces[i].depth;
        light = fmaxf(0.46f, fminf(0.95f, light));
        for (int k = 0; k < 3; ++k) faces[i].rgb[k] = face_colors[i][k] * light;
    }
    qsort(faces, 6, sizeof(Face), face_compare);
    CHECK_VK(vkResetCommandBuffer(a->command, 0));
    VkCommandBufferBeginInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CHECK_VK(vkBeginCommandBuffer(a->command, &bi));
    VkClearValue background = {0};
    background.color.float32[0] = 0.045f;
    background.color.float32[1] = 0.065f;
    background.color.float32[2] = 0.095f;
    background.color.float32[3] = 1.0f;
    VkRenderPassBeginInfo rpbi = {0};
    rpbi.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rpbi.renderPass = a->wsi_active ? a->wsi_render_pass : a->render_pass;
    rpbi.framebuffer = a->wsi_active ? a->wsi_fbs[wsi_index] : a->framebuffer;
    rpbi.renderArea.extent.width = (uint32_t)a->width;
    rpbi.renderArea.extent.height = (uint32_t)a->height;
    rpbi.clearValueCount = 1;
    rpbi.pClearValues = &background;
    vkCmdBeginRenderPass(a->command, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
    for (int i = 0; i < 6; ++i) {
        Vec2 quad[4];
        for (int j = 0; j < 4; ++j) quad[j] = projected[faces[i].idx[j]];
        draw_face(a, quad, faces[i].rgb);
    }
    vkCmdEndRenderPass(a->command);
    if (!a->wsi_active) {
    VkImageMemoryBarrier imgbar = {0};
    imgbar.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    imgbar.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    imgbar.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    imgbar.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    imgbar.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    imgbar.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    imgbar.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    imgbar.image = a->image;
    imgbar.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    imgbar.subresourceRange.levelCount = 1;
    imgbar.subresourceRange.layerCount = 1;
    vkCmdPipelineBarrier(a->command, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &imgbar);
    VkBufferImageCopy copy = {0};
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = (uint32_t)a->width;
    copy.imageExtent.height = (uint32_t)a->height;
    copy.imageExtent.depth = 1;
    vkCmdCopyImageToBuffer(a->command, a->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        a->readback, 1, &copy);
    VkBufferMemoryBarrier mem_bar = {0};
    mem_bar.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    mem_bar.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    mem_bar.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    mem_bar.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    mem_bar.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    mem_bar.buffer = a->readback;
    mem_bar.offset = 0;
    mem_bar.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(a->command, VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &mem_bar, 0, NULL);
    }
    CHECK_VK(vkEndCommandBuffer(a->command));
    CHECK_VK(vkResetFences(a->device, 1, &a->fence));
    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &a->command;
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    if (a->wsi_active) {
        si.waitSemaphoreCount = 1; si.pWaitSemaphores = &a->acquire_semaphore;
        si.pWaitDstStageMask = &wait_stage;
        si.signalSemaphoreCount = 1; si.pSignalSemaphores = &a->render_semaphore;
    }
    CHECK_VK(vkQueueSubmit(a->queue, 1, &si, a->fence));
    CHECK_VK(vkWaitForFences(a->device, 1, &a->fence, VK_TRUE, UINT64_MAX));
    if (a->wsi_active) {
        VkPresentInfoKHR pi = {0};
        pi.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        pi.waitSemaphoreCount = 1; pi.pWaitSemaphores = &a->render_semaphore;
        pi.swapchainCount = 1; pi.pSwapchains = &a->swapchain;
        pi.pImageIndices = &wsi_index;
        CHECK_VK(vkQueuePresentKHR(a->queue, &pi));
        /* Conservative synchronization for this simple one-frame-at-a-time demo. */
        CHECK_VK(vkDeviceWaitIdle(a->device));
        return;
    }
    if (!a->readback_coherent) {
        VkMappedMemoryRange r = {0};
        r.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        r.memory = a->readback_mem;
        r.offset = 0;
        r.size = VK_WHOLE_SIZE;
        CHECK_VK(vkInvalidateMappedMemoryRanges(a->device, 1, &r));
    }
}

static unsigned long scale_channel(uint8_t v, unsigned long mask) {
    if (!mask) return 0;
    unsigned shift = 0;
    while (((mask >> shift) & 1ul) == 0ul) ++shift;
    unsigned long vmax = mask >> shift;
    return ((((unsigned long)v * vmax + 127ul) / 255ul) << shift) & mask;
}
static void update_ximage(App *a) {
    const uint8_t *p = (const uint8_t*)a->readback_ptr;
    for (int y = 0; y < a->height; ++y) {
        for (int x = 0; x < a->width; ++x) {
            size_t src = ((size_t)y * (size_t)a->width + (size_t)x) * 4u;
            unsigned long pixel = scale_channel(p[src], a->red_mask) |
                scale_channel(p[src+1], a->green_mask) |
                scale_channel(p[src+2], a->blue_mask);
            if (a->ximage->bits_per_pixel == 32) {
                uint8_t *d = (uint8_t*)a->ximage->data +
                    (size_t)y * (size_t)a->ximage->bytes_per_line + (size_t)x*4u;
                if (a->ximage->byte_order == LSBFirst) {
                    for (int i = 0; i < 4; ++i) d[i] = (uint8_t)(pixel >> (8*i));
                } else {
                    for (int i = 0; i < 4; ++i) d[i] = (uint8_t)(pixel >> (8*(3-i)));
                }
            } else {
                XPutPixel(a->ximage, x, y, pixel);
            }
        }
    }
}
static double seconds_now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0.0;
    return (double)t.tv_sec + (double)t.tv_nsec*1.0e-9;
}
static void sleep_remaining(double seconds) {
    if (seconds <= 0) return;
    struct timespec t = {(time_t)seconds, (long)((seconds - floor(seconds))*1.0e9)};
    nanosleep(&t, NULL);
}
static void cleanup(App *a) {
    if (a->device) {
        vkDeviceWaitIdle(a->device);
        if (a->acquire_semaphore) vkDestroySemaphore(a->device, a->acquire_semaphore, NULL);
        if (a->render_semaphore) vkDestroySemaphore(a->device, a->render_semaphore, NULL);
        for (uint32_t i = 0; i < a->wsi_count; ++i) {
            if (a->wsi_fbs && a->wsi_fbs[i]) vkDestroyFramebuffer(a->device, a->wsi_fbs[i], NULL);
            if (a->wsi_views && a->wsi_views[i]) vkDestroyImageView(a->device, a->wsi_views[i], NULL);
        }
        free(a->wsi_fbs); free(a->wsi_views); free(a->wsi_images);
        if (a->wsi_render_pass) vkDestroyRenderPass(a->device, a->wsi_render_pass, NULL);
        if (a->swapchain) vkDestroySwapchainKHR(a->device, a->swapchain, NULL);
        if (a->fence) vkDestroyFence(a->device, a->fence, NULL);
        if (a->command_pool) vkDestroyCommandPool(a->device, a->command_pool, NULL);
        if (a->readback_ptr) vkUnmapMemory(a->device, a->readback_mem);
        if (a->readback) vkDestroyBuffer(a->device, a->readback, NULL);
        if (a->readback_mem) vkFreeMemory(a->device, a->readback_mem, NULL);
        if (a->framebuffer) vkDestroyFramebuffer(a->device, a->framebuffer, NULL);
        if (a->render_pass) vkDestroyRenderPass(a->device, a->render_pass, NULL);
        if (a->image_view) vkDestroyImageView(a->device, a->image_view, NULL);
        if (a->image) vkDestroyImage(a->device, a->image, NULL);
        if (a->image_mem) vkFreeMemory(a->device, a->image_mem, NULL);
        vkDestroyDevice(a->device, NULL);
    }
    if (a->surface) vkDestroySurfaceKHR(a->instance, a->surface, NULL);
    if (a->display) {
        if (a->ximage) XDestroyImage(a->ximage);
        if (a->gc) XFreeGC(a->display, a->gc);
        if (a->window) XDestroyWindow(a->display, a->window);
        XCloseDisplay(a->display);
    }
    if (a->instance) vkDestroyInstance(a->instance, NULL);
}
static void usage(const char *name) {
    fprintf(stderr,
        "Usage: %s [--api 1.0|1.1|1.2] [--present readback|wsi|auto] [--probe|--wsi-probe|--dri3-probe]\n"
        "  --api VERSION       Request Vulkan instance API; device maximum is reported separately\n"
        "  --present readback   Default: Vulkan offscreen render to XPutImage (no DRI3)\n"
        "  --present wsi        REQUIRE Vulkan Xlib surface and swapchain, no fallback\n"
        "  --present auto       Try real Xlib Vulkan swapchain; fall back on setup failure\n"
        "  --probe              Check Vulkan offscreen allocation; no X11 required\n"
        "  --wsi-probe          Try Xlib VkSurfaceKHR and VkSwapchainKHR setup (requires X11)\n"
        "  --dri3-probe         Query X11 DRI3 / Present / MIT-SHM extensions\n"
        "  --width/--height N   Image size; default 520x390\n"
        "  --fps N              Frame rate cap 1..60 (default 12)\n"
        "  q / Escape          Close window\n", name);
}
static int parse_int(const char *s, int min, int max, const char *opt) {
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || end == s || *end || v < min || v > max) {
        fprintf(stderr, "Invalid %s: %s; valid range %d..%d\n", opt, s, min, max);
        exit(2);
    }
    return (int)v;
}
int main(int argc, char **argv) {
    App a = {0};
    a.width = 520; a.height = 390; a.fps = 12;
    a.requested_api = VK_API_VERSION_1_0;
    int probe = 0, wsi_probe = 0, dri3_probe = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--probe")) { probe = 1; continue; }
        if (!strcmp(argv[i], "--wsi-probe")) { wsi_probe = 1; a.present = 1; continue; }
        if (!strcmp(argv[i], "--dri3-probe")) { dri3_probe = 1; continue; }
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { usage(argv[0]); return 0; }
        if (!strcmp(argv[i], "--api") && i+1 < argc) {
            const char *ver = argv[++i];
            if (!strcmp(ver,"1.0")) a.requested_api = VK_API_VERSION_1_0;
            else if (!strcmp(ver,"1.1")) a.requested_api = VK_API_VERSION_1_1;
            else if (!strcmp(ver,"1.2")) a.requested_api = VK_API_VERSION_1_2;
            else { fprintf(stderr,"Unsupported API version: %s\n",ver); return 2; }
            continue;
        }
        if (!strcmp(argv[i], "--present") && i+1 < argc) {
            const char *mode = argv[++i];
            if (!strcmp(mode,"readback")) a.present = 0;
            else if (!strcmp(mode,"wsi")) a.present = 1;
            else if (!strcmp(mode,"auto")) a.present = 2;
            else { fprintf(stderr,"Unsupported present mode: %s\n",mode); return 2; }
            continue;
        }
        if ((!strcmp(argv[i], "--width") || !strcmp(argv[i], "--height") ||
             !strcmp(argv[i], "--fps")) && i + 1 < argc) {
            if (!strcmp(argv[i], "--width")) a.width = parse_int(argv[++i],160,1280,"--width");
            else if (!strcmp(argv[i], "--height")) a.height = parse_int(argv[++i],120,960,"--height");
            else a.fps = parse_int(argv[++i],1,60,"--fps");
            continue;
        }
        usage(argv[0]); return 2;
    }
    if ((probe && wsi_probe) || (dri3_probe && (probe || wsi_probe))) {
        fprintf(stderr,"Select only one probe mode.\n"); return 2;
    }
    if (dri3_probe) {
        Display *dpy = XOpenDisplay(NULL);
        if (!dpy) { fprintf(stderr,"Cannot open X display for DRI3 check.\n"); return 2; }
        int dri3 = probe_dri3(dpy);
        XCloseDisplay(dpy);
        return dri3 ? 0 : 3;
    }
    if (probe) a.present = 0;
    init_vulkan(&a);
    if (probe) {
        fprintf(stderr,"PROBE SUCCESS: Vulkan API request, device and offscreen memory initialized.\n");
        cleanup(&a); return 0;
    }
    init_x11(&a);
    if (a.present != 0 && !init_wsi(&a)) {
        if (wsi_probe || a.present == 1) {
            fprintf(stderr,"WSI TEST FAILED; offscreen Vulkan mode remains available.\n");
            cleanup(&a); return 4;
        }
        fprintf(stderr,"WSI setup failed. Using readback/XPutImage instead.\n");
        a.present = 0;
    }
    if (wsi_probe) {
        fprintf(stderr,"WSI PROBE SUCCESS: surface and swapchain created.\n");
        cleanup(&a); return 0;
    }
    fprintf(stderr, "Rendering rotating cube via %s. Press Q or Escape.\n",
        a.wsi_active ? "Vulkan Xlib swapchain" : "Vulkan readback + XPutImage");
    unsigned frames = 0;
    double last_fps = seconds_now(), start = last_fps;
    int running = 1;
    while (running) {
        while (XPending(a.display)) {
            XEvent e;
            XNextEvent(a.display, &e);
            if (e.type == KeyPress) {
                KeySym key = XLookupKeysym(&e.xkey, 0);
                if (key == XK_Escape || key == XK_q || key == XK_Q) running = 0;
            }
            if (e.type == DestroyNotify) running = 0;
        }
        if (!running) break;
        double tick = seconds_now();
        Vec2 projected[8];
        render_frame(&a, (float)((tick-start)*0.72 + 0.25), projected);
        if (!a.wsi_active) {
            update_ximage(&a);
            XPutImage(a.display, a.window, a.gc, a.ximage, 0,0,0,0,
                (unsigned)a.width, (unsigned)a.height);
            XSetForeground(a.display, a.gc, WhitePixel(a.display, a.xscreen));
            const char *caption = "Vulkan / Lavapipe -> XPutImage (no DRI3 needed)";
            XDrawString(a.display, a.window, a.gc, 12, 20,
                caption, (int)strlen(caption));
            XFlush(a.display);
        }
        ++frames;
        if (tick-last_fps >= 5.0) {
            fprintf(stderr, "Frames: %u; %.1f FPS (%s)\n",
                frames, (double)frames/(tick-last_fps), a.wsi_active ? "swapchain" : "XPutImage");
            frames = 0; last_fps = tick;
        }
        sleep_remaining(1.0/(double)a.fps - (seconds_now()-tick));
    }
    cleanup(&a);
    return 0;
}
