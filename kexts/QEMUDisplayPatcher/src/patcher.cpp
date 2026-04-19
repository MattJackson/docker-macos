//
// patcher.cpp — QEMUDisplayPatcher (mos15-patcher edition)
//
// Patches IONDRVFramebuffer methods to mirror QEMUDisplay's behaviour.
// Uses mos15-patcher (our own framework) for kext-load detection +
// symbol lookup + function patching. No Lilu dependency.
//

#include <mos15_patcher.h>

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/graphics/IOFramebuffer.h>
#include <libkern/c++/OSNumber.h>
#include <architecture/i386/pio.h>

// === EDID =====================================================================
static const uint8_t mos15_edid[128] = {
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x06, 0x10, 0xc3, 0x9c, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x22, 0x01, 0x03, 0x80, 0x3c, 0x22, 0x78, 0x0a, 0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26,
    0x0f, 0x50, 0x54, 0x21, 0x08, 0x00, 0xd1, 0xc0, 0x81, 0xc0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c,
    0x45, 0x00, 0x06, 0x44, 0x21, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0xfc, 0x00, 0x69, 0x4d, 0x61,
    0x63, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xfd, 0x00, 0x38,
    0x4c, 0x1e, 0x51, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    0x00, 0x4d, 0x4f, 0x53, 0x31, 0x35, 0x56, 0x4d, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x71,
};

// === SMC port-I/O =============================================================
static void smcWriteKey(const char *key, uint8_t len, const uint8_t *data) {
    outb(0x304, 0x11);
    for (int i = 0; i < 100; i++) { if (inb(0x304) & 0x04) break; IODelay(100); }
    for (int i = 0; i < 4; i++) {
        outb(0x300, key[i]);
        for (int j = 0; j < 100; j++) { if (inb(0x304) & 0x04) break; IODelay(100); }
    }
    outb(0x300, len);
    for (int i = 0; i < 100; i++) { if (inb(0x304) & 0x04) break; IODelay(100); }
    for (int i = 0; i < len; i++) {
        outb(0x300, data[i]);
        for (int j = 0; j < 100; j++) { if (!(inb(0x304) & 0x02) || (inb(0x304) & 0x04)) break; IODelay(100); }
    }
}

// === Display modes — iMac20,1 HiDPI ladder ====================================
struct ModeInfo {
    uint32_t id;
    uint32_t width;
    uint32_t height;
    uint32_t refreshRate;
};
static const ModeInfo modes[] = {
    {1, 1920, 1080, 60 << 16},  /* default */
    {2, 2560, 1440, 60 << 16},
    {3, 5120, 2880, 60 << 16},  /* native 5K */
    {4, 3840, 2160, 60 << 16},
    {5, 3008, 1692, 60 << 16},
    {6, 2048, 1152, 60 << 16},
    {7, 1680,  945, 60 << 16},
    {8, 1280,  720, 60 << 16},
};
static const int numModes = sizeof(modes) / sizeof(modes[0]);
static uint32_t gCurrentWidth  = 1920;
static uint32_t gCurrentHeight = 1080;

// === Trampolines (filled by mp_route_kext) ====================================
static IOReturn         (*orgEnableController)(void *) = nullptr;
static bool             (*orgHasDDCConnect)(void *, int32_t) = nullptr;
static IOReturn         (*orgGetDDCBlock)(void *, int32_t, uint32_t, uint32_t, uint32_t, uint8_t *, uint64_t *) = nullptr;
static IOReturn         (*orgSetGammaTable)(void *, uint32_t, uint32_t, uint32_t, void *) = nullptr;
static IODeviceMemory * (*orgGetVRAMRange)(void *) = nullptr;
static IOReturn         (*orgSetAttributeForConnection)(void *, int32_t, uint32_t, uintptr_t) = nullptr;
static IODeviceMemory * (*orgGetApertureRange)(void *, int32_t) = nullptr;
static const char *     (*orgGetPixelFormats)(void *) = nullptr;
static uint32_t         (*orgGetDisplayModeCount)(void *) = nullptr;
static IOReturn         (*orgGetDisplayModes)(void *, int32_t *) = nullptr;
static IOReturn         (*orgGetInformationForDisplayMode)(void *, int32_t, IODisplayModeInformation *) = nullptr;
static IOReturn         (*orgGetPixelInformation)(void *, int32_t, int32_t, int32_t, IOPixelInformation *) = nullptr;
static IOReturn         (*orgGetCurrentDisplayMode)(void *, int32_t *, int32_t *) = nullptr;
static IOReturn         (*orgSetDisplayMode)(void *, int32_t, int32_t) = nullptr;
static uint64_t         (*orgGetPixelFormatsForDisplayMode)(void *, int32_t, int32_t) = nullptr;
static IOReturn         (*orgGetTimingInfoForDisplayMode)(void *, int32_t, IOTimingInformation *) = nullptr;
static uint32_t         (*orgGetConnectionCount)(void *) = nullptr;
static IOReturn         (*orgSetupForCurrentConfig)(void *) = nullptr;

// === Patched methods ==========================================================

static IOReturn patchedEnableController(void *that) {
    IOReturn r = orgEnableController(that);

    uint8_t on = 0x01;
    smcWriteKey("HE0N", 1, &on);
    smcWriteKey("HE2N", 1, &on);

    uint64_t vramBytes = 0;
    if (that) {
        IOService *fb = static_cast<IOService *>(that);
        IOService *prov = fb->getProvider();
        IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, prov);
        if (pci) {
            IODeviceMemory *bar1 = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
            if (bar1) {
                vramBytes = bar1->getLength();
                fb->setProperty("IOFBMemorySize", vramBytes, 64);
            }
        }
    }

    IOLog("QDP: enableController -> 0x%x (SMC+VRAM=%lluMB)\n",
          (unsigned)r, vramBytes / (1024 * 1024));
    return r;
}

static bool patchedHasDDCConnect(void *, int32_t) { return true; }

static IOReturn patchedGetDDCBlock(void *that, int32_t ci, uint32_t bn,
                                   uint32_t bt, uint32_t opts,
                                   uint8_t *data, uint64_t *length) {
    if (bn != 1 || !data || !length) return 0xE00002BC;
    uint64_t copyLen = (*length < 128) ? *length : 128;
    memcpy(data, mos15_edid, (size_t)copyLen);
    *length = copyLen;
    return 0;
}

static IOReturn patchedSetGammaTable(void *, uint32_t, uint32_t, uint32_t, void *) { return 0; }

static IODeviceMemory *patchedGetVRAMRange(void *that) {
    if (!that) return orgGetVRAMRange(that);
    IOService *fb = static_cast<IOService *>(that);
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, fb->getProvider());
    if (pci) {
        IODeviceMemory *bar1 = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
        if (bar1) { bar1->retain(); return bar1; }
    }
    return orgGetVRAMRange(that);
}

static IOReturn patchedSetAttributeForConnection(void *, int32_t, uint32_t, uintptr_t) { return 0; }

static IODeviceMemory *patchedGetApertureRange(void *that, int32_t aperture) {
    if (!that || aperture != 0) return orgGetApertureRange(that, aperture);
    IOService *fb = static_cast<IOService *>(that);
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, fb->getProvider());
    if (pci) {
        IODeviceMemory *bar1 = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
        if (bar1) {
            uint64_t fbSize = (uint64_t)gCurrentWidth * gCurrentHeight * 4;
            IODeviceMemory *sub = IODeviceMemory::withSubRange(bar1, 0, fbSize);
            if (sub) return sub;
        }
    }
    return orgGetApertureRange(that, aperture);
}

static const char *patchedGetPixelFormats(void *) {
    static const char fmts[] = IO32BitDirectPixels "\0";
    return fmts;
}

static uint32_t patchedGetDisplayModeCount(void *) { return numModes; }

static IOReturn patchedGetDisplayModes(void *, int32_t *allModes) {
    if (!allModes) return 0xE00002BC;
    for (int i = 0; i < numModes; i++) allModes[i] = (int32_t)modes[i].id;
    return 0;
}

static IOReturn patchedGetInformationForDisplayMode(void *, int32_t mode, IODisplayModeInformation *info) {
    if (!info) return 0xE00002BC;
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            bzero(info, sizeof(*info));
            info->maxDepthIndex = 0;
            info->nominalWidth  = modes[i].width;
            info->nominalHeight = modes[i].height;
            info->refreshRate   = modes[i].refreshRate;
            return 0;
        }
    }
    return 0xE00002C2;
}

static IOReturn patchedGetPixelInformation(void *, int32_t mode, int32_t depth, int32_t, IOPixelInformation *info) {
    if (!info || depth != 0) return 0xE00002BC;
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            bzero(info, sizeof(*info));
            info->bytesPerRow      = modes[i].width * 4;
            info->bitsPerPixel     = 32;
            info->pixelType        = kIORGBDirectPixels;
            info->componentCount   = 3;
            info->bitsPerComponent = 8;
            info->activeWidth      = modes[i].width;
            info->activeHeight     = modes[i].height;
            strlcpy(info->pixelFormat, IO32BitDirectPixels, sizeof(info->pixelFormat));
            return 0;
        }
    }
    return 0xE00002C2;
}

static IOReturn patchedGetCurrentDisplayMode(void *, int32_t *mode, int32_t *depth) {
    if (mode) *mode = 1;
    if (depth) *depth = 0;
    return 0;
}

static IOReturn patchedSetDisplayMode(void *, int32_t mode, int32_t) {
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            gCurrentWidth  = modes[i].width;
            gCurrentHeight = modes[i].height;
            return 0;
        }
    }
    return 0xE00002C2;
}

static uint64_t patchedGetPixelFormatsForDisplayMode(void *, int32_t, int32_t) { return 0; }

static IOReturn patchedGetTimingInfoForDisplayMode(void *, int32_t mode, IOTimingInformation *info) {
    if (!info) return 0xE00002BC;
    bzero(info, sizeof(*info));
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            info->appleTimingID = (IOAppleTimingID)0xFFFFFFFF;
            info->flags = kIODetailedTimingValid;
            info->detailedInfo.v2.horizontalActive = modes[i].width;
            info->detailedInfo.v2.verticalActive   = modes[i].height;
            info->detailedInfo.v2.pixelClock = (uint64_t)modes[i].width * modes[i].height * 60;
            return 0;
        }
    }
    return 0xE00002C2;
}

static uint32_t patchedGetConnectionCount(void *) { return 1; }

static IOReturn patchedSetupForCurrentConfig(void *that) {
    IOReturn r = orgSetupForCurrentConfig(that);
    if (that) {
        IOService *fb = static_cast<IOService *>(that);
        IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, fb->getProvider());
        if (pci) {
            IODeviceMemory *bar1 = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
            if (bar1) {
                fb->setProperty("IOFBMemorySize", (uint64_t)bar1->getLength(), 64);
            }
        }
    }
    return r;
}

// === Mangled-name helper ======================================================
static char gMangleBufs[40][128];
static int  gMangleNext = 0;

static const char *mangleNDRV(const char *method, const char *paramSig) {
    if (gMangleNext >= 40) return "";
    char *out = gMangleBufs[gMangleNext++];
    snprintf(out, 128, "__ZN17IONDRVFramebuffer%d%sE%s",
             (int)strlen(method), method, paramSig);
    return out;
}

// === Kext entry — register routes via mos15-patcher ===========================

extern "C"
kern_return_t qdp_start(kmod_info_t *ki, void *d)
{
    IOLog("QDP: starting (mos15-patcher edition)\n");

    mp_route_request_t reqs[] = {
        { mangleNDRV("enableController",              "v"),                            (void *)patchedEnableController,           (void **)&orgEnableController },
        { mangleNDRV("hasDDCConnect",                 "i"),                            (void *)patchedHasDDCConnect,              (void **)&orgHasDDCConnect },
        { mangleNDRV("getDDCBlock",                   "ijjjPhPy"),                     (void *)patchedGetDDCBlock,                (void **)&orgGetDDCBlock },
        { mangleNDRV("setGammaTable",                 "jjjPv"),                        (void *)patchedSetGammaTable,              (void **)&orgSetGammaTable },
        { mangleNDRV("getVRAMRange",                  "v"),                            (void *)patchedGetVRAMRange,               (void **)&orgGetVRAMRange },
        { mangleNDRV("setAttributeForConnection",     "ijm"),                          (void *)patchedSetAttributeForConnection,  (void **)&orgSetAttributeForConnection },
        { mangleNDRV("getApertureRange",              "15IOPixelAperture"),            (void *)patchedGetApertureRange,           (void **)&orgGetApertureRange },
        { mangleNDRV("getPixelFormats",               "v"),                            (void *)patchedGetPixelFormats,            (void **)&orgGetPixelFormats },
        { mangleNDRV("getDisplayModeCount",           "v"),                            (void *)patchedGetDisplayModeCount,        (void **)&orgGetDisplayModeCount },
        { mangleNDRV("getDisplayModes",               "Pi"),                           (void *)patchedGetDisplayModes,            (void **)&orgGetDisplayModes },
        { mangleNDRV("getInformationForDisplayMode",  "iP24IODisplayModeInformation"), (void *)patchedGetInformationForDisplayMode, (void **)&orgGetInformationForDisplayMode },
        { mangleNDRV("getPixelInformation",           "iiiP18IOPixelInformation"),     (void *)patchedGetPixelInformation,        (void **)&orgGetPixelInformation },
        { mangleNDRV("getCurrentDisplayMode",         "PiS0_"),                        (void *)patchedGetCurrentDisplayMode,      (void **)&orgGetCurrentDisplayMode },
        { mangleNDRV("setDisplayMode",                "ii"),                           (void *)patchedSetDisplayMode,             (void **)&orgSetDisplayMode },
        { mangleNDRV("getPixelFormatsForDisplayMode", "ii"),                           (void *)patchedGetPixelFormatsForDisplayMode, (void **)&orgGetPixelFormatsForDisplayMode },
        { mangleNDRV("getTimingInfoForDisplayMode",   "iP19IOTimingInformation"),      (void *)patchedGetTimingInfoForDisplayMode, (void **)&orgGetTimingInfoForDisplayMode },
        { mangleNDRV("getConnectionCount",            "v"),                            (void *)patchedGetConnectionCount,         (void **)&orgGetConnectionCount },
        { mangleNDRV("setupForCurrentConfig",         "v"),                            (void *)patchedSetupForCurrentConfig,      (void **)&orgSetupForCurrentConfig },
    };
    int n = sizeof(reqs) / sizeof(*reqs);

    int rc = mp_route_kext("com.apple.iokit.IONDRVSupport", reqs, n);
    IOLog("QDP: mp_route_kext returned %d (n=%d routes)\n", rc, n);

    return KERN_SUCCESS;
}

extern "C"
kern_return_t qdp_stop(kmod_info_t *ki, void *d)
{
    /* Don't allow unload — our hooks live in shared kernel pages. */
    return KERN_FAILURE;
}
