//
//  kern_patcher.cpp
//  QEMUDisplayPatcher
//
//  Mirrors the proven QEMUDisplay kext via Lilu hooks on IONDRVFramebuffer.
//  We hook the same 4 methods QEMUDisplay implemented its core P1 behaviour in
//  (enableController, hasDDCConnect, getDDCBlock, setGammaTable). Each does
//  exactly what QEMUDisplay does for that method.
//
//  The full ~44-route passthrough version had Lilu silently abort the batch
//  on an unresolved mangled name in the 5th+ slot (truncated log line). We'll
//  add more routes one at a time later to identify the bad name; for now this
//  4-route surface is proven (verified wrapping in earlier deploys).
//

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_patcher.hpp>

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/graphics/IOFramebuffer.h>
#include <libkern/c++/OSNumber.h>
#include <architecture/i386/pio.h>

#include "qdp_patcher.hpp"

// === EDID — 128 bytes ========================================================
// Custom EDID describing a generic Apple display at 1920x1080 (matches our
// actual framebuffer mode). PnP "APP" + product 0x9CC3, name "iMac" via the
// FC display descriptor, serial "MOS15VM". macOS classifies it as "Color LCD"
// (not "iMac") because the product ID isn't in macOS's display product DB,
// but the EDID landing cleanly is what matters — it gets attached to
// IONDRVFramebuffer as IODisplayEDID and creates the IODisplayConnect node.
//
// Earlier attempt to use the real iMac20,1 EDID (PnP APP, product 0xAE31)
// failed: that EDID describes 5120x2880 5K timings, and macOS rejected it
// against our actual 1920x1080 framebuffer — IODisplayConnect wasn't created
// and the Displays: subtree disappeared from system_profiler. Display name
// is cosmetic; functional EDID landing is the win.
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

// === Apple SMC port-I/O write ===============================================
// CMD=0x304, DATA=0x300. qemu-mos15's applesmc.c registers HE0N/HE2N
// (and accepts WRITE_CMD); we flip them to 0x01 so AGPM doesn't crash on
// dynamic wallpaper changes.
static void smcWriteKey(const char *key, uint8_t len, const uint8_t *data) {
    outb(0x304, 0x11);  /* APPLESMC_WRITE_CMD */
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

// === Trampolines ============================================================
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

// === Runtime mode flag ======================================================
// gBasicMode = true → every hook is pure passthrough to original (no SMC,
// no setProperty, no EDID substitution). Toggled by `-qdpbasic` boot-arg.
// Default false → full QDP behaviour. See kern_start.cpp for the bootarg.
static bool gBasicMode = false;

// === Display modes — iMac20,1 HiDPI ladder ==================================
// Real iMac20,1 ships a 5120x2880 native 5K Retina panel; macOS Displays.app
// exposes these scaled options around it. Mode 1 is the default ("looks like
// 2560x1440" — what macOS picks out of the box on iMac).
struct ModeInfo {
    uint32_t id;            /* IODisplayModeID */
    uint32_t width;
    uint32_t height;
    uint32_t refreshRate;   /* fixed-point 16.16 */
};
static const ModeInfo modes[] = {
    {1, 1920, 1080, 60 << 16},  /* default — what's actually run on this host */
    {2, 2560, 1440, 60 << 16},  /* "looks like 1440p" — iMac default scaled */
    {3, 5120, 2880, 60 << 16},  /* native 5K (Retina) */
    {4, 3840, 2160, 60 << 16},  /* 4K */
    {5, 3008, 1692, 60 << 16},  /* "more space" */
    {6, 2048, 1152, 60 << 16},  /* medium */
    {7, 1680,  945, 60 << 16},  /* "larger text" */
    {8, 1280,  720, 60 << 16},  /* HD */
};
static const int numModes = sizeof(modes) / sizeof(modes[0]);

/* Tracks the currently selected mode (default = mode 1 = 1920x1080).
 * Used by getApertureRange to return a BAR1 sub-range sized to the mode. */
static uint32_t gCurrentWidth  = 1920;
static uint32_t gCurrentHeight = 1080;

// === Hooks ==================================================================

// enableController — mirrors QEMUDisplay::enableController():
// QEMUDisplay does NOT call super::enableController(). We follow suit —
// calling orgEnableController() page-faults the kernel (DISCOVERY #56's
// curse, not actually resolved by patched Lilu). Skip OEM NDRV init and
// own this method completely.
//
// Steps (mirror of QEMUDisplay):
// 1. SMC HE0N=1, HE2N=1 (AGPM happy on wallpaper change).
// 2. Read PCI BAR1 size and setProperty IOFBMemorySize.
// 3. Return kIOReturnSuccess.
// enableController:
// fancy: call orig, write SMC HE0N/HE2N=1 (AGPM happy on wallpaper change),
//        setProperty IOFBMemorySize from PCI BAR1 length (qemu's vgamem_mb=256
//        → 256MB shown in About This Mac). Mirrors QEMUDisplay::enableController.
//        Requires com.apple.iokit.IOPCIFamily in OSBundleLibraries.
// basic: pure passthrough.
static IOReturn patchedEnableController(void *that) {
    IOReturn r = orgEnableController(that);
    if (gBasicMode) {
        IOLog("QDP: enableController -> 0x%x (basic)\n", (unsigned)r);
        return r;
    }

    /* SMC GPU power on. */
    uint8_t on = 0x01;
    smcWriteKey("HE0N", 1, &on);
    smcWriteKey("HE2N", 1, &on);

    /* VRAM property from PCI BAR1. */
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

    IOLog("QDP: enableController -> 0x%x (fancy: SMC+VRAM=%lluMB)\n",
          (unsigned)r, vramBytes / (1024 * 1024));
    return r;
}

// hasDDCConnect:
// fancy: always true (we have an EDID to provide).
// basic: passthrough.
static bool patchedHasDDCConnect(void *that, int32_t connectIndex) {
    if (gBasicMode) return orgHasDDCConnect(that, connectIndex);
    return true;
}

// getDDCBlock:
// fancy: block 1 = iMac EDID (substitute our identity).
// basic: passthrough.
static IOReturn patchedGetDDCBlock(void *that, int32_t connectIndex, uint32_t blockNumber,
                                   uint32_t blockType, uint32_t options,
                                   uint8_t *data, uint64_t *length) {
    if (gBasicMode) return orgGetDDCBlock(that, connectIndex, blockNumber, blockType, options, data, length);
    if (blockNumber != 1 || data == NULL || length == NULL) {
        return 0xE00002BC; /* kIOReturnBadArgument */
    }
    uint64_t copyLen = (*length < 128) ? *length : 128;
    memcpy(data, mos15_edid, (size_t)copyLen);
    *length = copyLen;
    return 0;
}

// setGammaTable:
// fancy: accept, do nothing (matches QEMUDisplay; AppleDisplay needs success
//        to drive ChildrenPowerState → 2).
// basic: passthrough.
static IOReturn patchedSetGammaTable(void *that, uint32_t channelCount, uint32_t dataCount,
                                     uint32_t dataWidth, void *data) {
    if (gBasicMode) return orgSetGammaTable(that, channelCount, dataCount, dataWidth, data);
    return 0;
}

// getVRAMRange:
// fancy: return PCI BAR1 (qemu vmware-svga's framebuffer aperture, sized by
//        vgamem_mb=256 → 256MB). OEM IONDRV's getVRAMRange falls back to the
//        7.91MB hardcoded NDRV value; this overrides that everywhere macOS
//        derives VRAM size from the live query.
// basic: passthrough.
static IODeviceMemory *patchedGetVRAMRange(void *that) {
    if (gBasicMode || !that) return orgGetVRAMRange(that);
    IOService *fb = static_cast<IOService *>(that);
    IOService *prov = fb->getProvider();
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, prov);
    if (pci) {
        IODeviceMemory *bar1 = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
        if (bar1) {
            bar1->retain();  /* IODeviceMemory caller-owned per IOFB convention */
            return bar1;
        }
    }
    return orgGetVRAMRange(that);
}

// setAttributeForConnection:
// fancy: accept all writes (return success) — mirrors QEMUDisplay. IOFramebuffer
//        sends these during connect processing; rejecting any can stall init.
// basic: passthrough.
static IOReturn patchedSetAttributeForConnection(void *that, int32_t connectIndex,
                                                 uint32_t attribute, uintptr_t value) {
    if (gBasicMode) return orgSetAttributeForConnection(that, connectIndex, attribute, value);
    return 0; /* kIOReturnSuccess */
}

// getApertureRange:
// fancy: return BAR1 sub-range sized to the current mode's framebuffer
//        (width * height * 4). Mirrors QEMUDisplay::getApertureRange.
// basic: passthrough.
static IODeviceMemory *patchedGetApertureRange(void *that, int32_t aperture) {
    if (gBasicMode || !that || aperture != 0) return orgGetApertureRange(that, aperture);
    IOService *fb = static_cast<IOService *>(that);
    IOService *prov = fb->getProvider();
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, prov);
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

// getPixelFormats — verbatim from QEMUDisplay: 32-bit direct pixels.
static const char *patchedGetPixelFormats(void *that) {
    if (gBasicMode) return orgGetPixelFormats(that);
    static const char fmts[] = IO32BitDirectPixels "\0";
    return fmts;
}

// getDisplayModeCount — number of modes we expose.
static uint32_t patchedGetDisplayModeCount(void *that) {
    if (gBasicMode) return orgGetDisplayModeCount(that);
    return numModes;
}

// getDisplayModes — copy our mode IDs into the array macOS provides.
static IOReturn patchedGetDisplayModes(void *that, int32_t *allModes) {
    if (gBasicMode) return orgGetDisplayModes(that, allModes);
    if (!allModes) return 0xE00002BC; /* kIOReturnBadArgument */
    for (int i = 0; i < numModes; i++)
        allModes[i] = (int32_t)modes[i].id;
    return 0;
}

// getInformationForDisplayMode — describe one mode (dimensions + refresh).
static IOReturn patchedGetInformationForDisplayMode(void *that, int32_t mode, IODisplayModeInformation *info) {
    if (gBasicMode) return orgGetInformationForDisplayMode(that, mode, info);
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
    return 0xE00002C2; /* kIOReturnBadArgument */
}

// getPixelInformation — pixel layout for a mode (32bpp BGRA, full active size).
static IOReturn patchedGetPixelInformation(void *that, int32_t mode, int32_t depth,
                                           int32_t aperture, IOPixelInformation *info) {
    if (gBasicMode) return orgGetPixelInformation(that, mode, depth, aperture, info);
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

// getCurrentDisplayMode — what mode is active right now.
static IOReturn patchedGetCurrentDisplayMode(void *that, int32_t *mode, int32_t *depth) {
    if (gBasicMode) return orgGetCurrentDisplayMode(that, mode, depth);
    if (mode) *mode = 1;   /* default: 1920x1080 */
    if (depth) *depth = 0;
    return 0;
}

// setDisplayMode — accept a switch + remember the geometry.
// QEMUDisplay deliberately does NOT touch SVGA registers — we stay in VGA
// auto-refresh mode so VNC keeps updating without explicit FIFO commands.
static IOReturn patchedSetDisplayMode(void *that, int32_t mode, int32_t depth) {
    if (gBasicMode) return orgSetDisplayMode(that, mode, depth);
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            gCurrentWidth  = modes[i].width;
            gCurrentHeight = modes[i].height;
            return 0;
        }
    }
    return 0xE00002C2;
}

// getPixelFormatsForDisplayMode — bitmask of formats; QEMUDisplay returns 0.
static uint64_t patchedGetPixelFormatsForDisplayMode(void *that, int32_t mode, int32_t depth) {
    if (gBasicMode) return orgGetPixelFormatsForDisplayMode(that, mode, depth);
    return 0;
}

// getTimingInfoForDisplayMode — operator-defined detailed timing.
static IOReturn patchedGetTimingInfoForDisplayMode(void *that, int32_t mode, IOTimingInformation *info) {
    if (gBasicMode) return orgGetTimingInfoForDisplayMode(that, mode, info);
    if (!info) return 0xE00002BC;
    bzero(info, sizeof(*info));
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            info->appleTimingID = (IOAppleTimingID)0xFFFFFFFF; /* operator-defined */
            info->flags = kIODetailedTimingValid;
            info->detailedInfo.v2.horizontalActive = modes[i].width;
            info->detailedInfo.v2.verticalActive   = modes[i].height;
            info->detailedInfo.v2.pixelClock = (uint64_t)modes[i].width * modes[i].height * 60;
            return 0;
        }
    }
    return 0xE00002C2;
}

// getConnectionCount — single attached display.
static uint32_t patchedGetConnectionCount(void *that) {
    if (gBasicMode) return orgGetConnectionCount(that);
    return 1;
}

// === Routing =================================================================
static const char *kextPath[] {
    "/System/Library/Extensions/IONDRVSupport.kext/IONDRVSupport"
};

static KernelPatcher::KextInfo kextInfo {
    "com.apple.iokit.IONDRVSupport",
    kextPath, 1,
    {true, false, false, false, true},
    {},
    KernelPatcher::KextInfo::Unloaded
};

static void onKextLoad(void *user, KernelPatcher &patcher, size_t id, mach_vm_address_t slide, size_t size) {
    IOLog("QDP: onKextLoad id=%lu\n", (unsigned long)id);

    KernelPatcher::RouteRequest reqs[] = {
        /* P1 — proven set */
        {"__ZN17IONDRVFramebuffer16enableControllerEv",            patchedEnableController,           orgEnableController},
        {"__ZN17IONDRVFramebuffer13hasDDCConnectEi",               patchedHasDDCConnect,              orgHasDDCConnect},
        {"__ZN17IONDRVFramebuffer11getDDCBlockEijjjPhPy",          patchedGetDDCBlock,                orgGetDDCBlock},
        {"__ZN17IONDRVFramebuffer13setGammaTableEjjjPv",           patchedSetGammaTable,              orgSetGammaTable},
        {"__ZN17IONDRVFramebuffer12getVRAMRangeEv",                patchedGetVRAMRange,               orgGetVRAMRange},
        /* Aperture & connection plumbing */
        {"__ZN17IONDRVFramebuffer25setAttributeForConnectionEijm",      patchedSetAttributeForConnection, orgSetAttributeForConnection},
        {"__ZN17IONDRVFramebuffer16getApertureRangeE15IOPixelAperture", patchedGetApertureRange,          orgGetApertureRange},
        /* Mode list (so user gets a resolution picker, not just OEM default) */
        {"__ZN17IONDRVFramebuffer15getPixelFormatsEv",             patchedGetPixelFormats,            orgGetPixelFormats},
        {"__ZN17IONDRVFramebuffer19getDisplayModeCountEv",         patchedGetDisplayModeCount,        orgGetDisplayModeCount},
        {"__ZN17IONDRVFramebuffer15getDisplayModesEPi",            patchedGetDisplayModes,            orgGetDisplayModes},
        {"__ZN17IONDRVFramebuffer28getInformationForDisplayModeEiP24IODisplayModeInformation", patchedGetInformationForDisplayMode, orgGetInformationForDisplayMode},
        {"__ZN17IONDRVFramebuffer19getPixelInformationEiiiP18IOPixelInformation",              patchedGetPixelInformation,          orgGetPixelInformation},
        {"__ZN17IONDRVFramebuffer21getCurrentDisplayModeEPiS0_",   patchedGetCurrentDisplayMode,      orgGetCurrentDisplayMode},
        {"__ZN17IONDRVFramebuffer14setDisplayModeEii",             patchedSetDisplayMode,             orgSetDisplayMode},
        {"__ZN17IONDRVFramebuffer29getPixelFormatsForDisplayModeEii", patchedGetPixelFormatsForDisplayMode, orgGetPixelFormatsForDisplayMode},
        {"__ZN17IONDRVFramebuffer27getTimingInfoForDisplayModeEiP19IOTimingInformation", patchedGetTimingInfoForDisplayMode, orgGetTimingInfoForDisplayMode},
        {"__ZN17IONDRVFramebuffer18getConnectionCountEv",          patchedGetConnectionCount,         orgGetConnectionCount},
    };
    patcher.routeMultiple(id, reqs, arrsize(reqs), slide, size);

    if (patcher.getError() == KernelPatcher::Error::NoError)
        IOLog("QDP: %lu/%lu routed (P1 + aperture + mode list)\n", arrsize(reqs), arrsize(reqs));
    else {
        IOLog("QDP: routeMultiple err %d\n", patcher.getError());
        patcher.clearError();
    }
}

void pluginStart() {
    gBasicMode = checkKernelArgument("-qdpbasic");
    IOLog("QDP: pluginStart (mode=%s)\n", gBasicMode ? "basic (passthrough)" : "fancy (QDP behaviour)");
    lilu.onKextLoadForce(&kextInfo, 1, onKextLoad);
}
