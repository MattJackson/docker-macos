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
// Real iMac20,1 (Retina 5K, 27", 2020) EDID — 2 blocks, 256 bytes total.
// Manufacturer APP (Apple), product 0xae31, monitor name "iMac".
// Source: /Users/mjackson/mos/imac20-1-hardware-reference.md §2.
// The extension-flag byte (126) = 0x01 signals to macOS that block 2 exists,
// so getDDCBlock is called with bn=2 for the CTA-861 extension.
static const uint8_t imac20_edid_block0[128] = {
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x06, 0x10, 0x31, 0xae, 0x20, 0x33, 0x6a, 0x63,
    0x16, 0x1d, 0x01, 0x04, 0xb5, 0x3c, 0x22, 0x78, 0x20, 0x0e, 0x21, 0xae, 0x52, 0x41, 0xb2, 0x26,
    0x0e, 0x50, 0x54, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x4d, 0xd0, 0x00, 0xa0, 0xf0, 0x70, 0x3e, 0x80, 0x30, 0x20,
    0x35, 0x00, 0x55, 0x50, 0x21, 0x00, 0x00, 0x1a, 0x56, 0x5e, 0x00, 0xa0, 0xa0, 0xa0, 0x29, 0x50,
    0x30, 0x20, 0x35, 0x00, 0x55, 0x50, 0x21, 0x00, 0x00, 0x1a, 0x00, 0x00, 0x00, 0xfc, 0x00, 0x69,
    0x4d, 0x61, 0x63, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xff,
    0x00, 0x39, 0x38, 0x34, 0x44, 0x38, 0x43, 0x42, 0x32, 0x30, 0x33, 0x33, 0x32, 0x41, 0x01, 0xf1,
};
static const uint8_t imac20_edid_block1[128] = {
    0x02, 0x03, 0x1f, 0x80, 0x70, 0xfa, 0x10, 0x00, 0x00, 0x12, 0x76, 0x31, 0xfc, 0x78, 0xfb, 0xff,
    0x02, 0x10, 0x88, 0x62, 0xd3, 0x69, 0xfa, 0x10, 0x00, 0xfa, 0xf8, 0xf8, 0xfe, 0xff, 0xff, 0xcd,
    0x91, 0x80, 0xa0, 0xc0, 0x08, 0x34, 0x70, 0x30, 0x20, 0x35, 0x00, 0x55, 0x50, 0x21, 0x00, 0x00,
    0x1a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x44,
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
/* Phase 2: the 5 methods QEMUDisplay implemented but QDP was missing.
 * Without these, IONDRVFramebuffer's original NDRV-backed versions run
 * and macOS may reject modes based on what NDRV reports. */
typedef void (*QDPInterruptProc)(OSObject *target, void *ref);
static IOReturn         (*orgGetAttribute)(void *, uint32_t, uintptr_t *) = nullptr;
static IOReturn         (*orgGetAttributeForConnection)(void *, int32_t, uint32_t, uintptr_t *) = nullptr;
static IOReturn         (*orgRegisterForInterruptType)(void *, uint32_t, QDPInterruptProc, OSObject *, void *, void **) = nullptr;
static IOReturn         (*orgUnregisterInterrupt)(void *, void *) = nullptr;
static IOReturn         (*orgSetInterruptState)(void *, void *, uint32_t) = nullptr;
/* Phase 3: connectFlags queries per-mode visibility. IONDRVFramebuffer's
 * default asks the NDRV driver, which doesn't know about our custom modes
 * and returns 0 (= hidden). We return Valid|Safe for every advertised mode. */
static IOReturn         (*orgConnectFlags)(void *, int32_t, int32_t, uint32_t *) = nullptr;

// === Patched methods ==========================================================

// First-call logger per hook — logs the FIRST invocation to avoid spamming.
// If a hook never logs, the hook is dead code (macOS reaches that functionality
// via a different path). Call count is captured separately via gHookCounters[].
#define QDP_FIRST_CALL(name, fmt, ...) do { \
    static uint32_t __cnt = 0; \
    if (__sync_fetch_and_add(&__cnt, 1) == 0) IOLog("QDP: " name " called " fmt "\n", ##__VA_ARGS__); \
} while (0)

// Per-hook call counters — exposed via ioreg on the IOFramebuffer via
// setProperty("QDPCallCounts", ...) in setupForCurrentConfig. Index order
// matches gHookNames[]. Every hook increments its slot atomically.
enum QDPHook {
    QDP_enableController = 0,
    QDP_hasDDCConnect,
    QDP_getDDCBlock,
    QDP_setGammaTable,
    QDP_getVRAMRange,
    QDP_setAttributeForConnection,
    QDP_getApertureRange,
    QDP_getPixelFormats,
    QDP_getDisplayModeCount,
    QDP_getDisplayModes,
    QDP_getInformationForDisplayMode,
    QDP_getPixelInformation,
    QDP_getCurrentDisplayMode,
    QDP_setDisplayMode,
    QDP_getPixelFormatsForDisplayMode,
    QDP_getTimingInfoForDisplayMode,
    QDP_getConnectionCount,
    QDP_setupForCurrentConfig,
    QDP_getAttribute,
    QDP_getAttributeForConnection,
    QDP_registerForInterruptType,
    QDP_unregisterInterrupt,
    QDP_setInterruptState,
    QDP_connectFlags,
    QDP_HOOK_COUNT
};
static const char *gHookNames[QDP_HOOK_COUNT] = {
    "enableController", "hasDDCConnect", "getDDCBlock", "setGammaTable",
    "getVRAMRange", "setAttributeForConnection", "getApertureRange",
    "getPixelFormats", "getDisplayModeCount", "getDisplayModes",
    "getInformationForDisplayMode", "getPixelInformation",
    "getCurrentDisplayMode", "setDisplayMode", "getPixelFormatsForDisplayMode",
    "getTimingInfoForDisplayMode", "getConnectionCount", "setupForCurrentConfig",
    "getAttribute", "getAttributeForConnection",
    "registerForInterruptType", "unregisterInterrupt", "setInterruptState",
    "connectFlags",
};
static uint32_t gHookCounters[QDP_HOOK_COUNT];

// Bitmap of which display-mode IDs have been queried. If this mask equals
// (1<<numModes)-1 after boot, every mode we advertise was actually asked
// about by CoreGraphics — proves our mode list is reaching userspace.
static uint64_t gModesQueriedMask = 0;
static IOService *gFramebuffer = nullptr;  // captured in enableController

#define QDP_COUNT(hook) __sync_fetch_and_add(&gHookCounters[QDP_##hook], 1)

static IOReturn patchedEnableController(void *that) {
    QDP_COUNT(enableController);
    if (!orgEnableController) { IOLog("QDP: orgEnableController NULL — skipping\n"); return 0; }
    IOReturn r = orgEnableController(that);

    uint8_t on = 0x01;
    smcWriteKey("HE0N", 1, &on);
    smcWriteKey("HE2N", 1, &on);

    uint64_t vramBytes = 0;
    if (that) {
        IOService *fb = static_cast<IOService *>(that);
        gFramebuffer = fb;  // remember for property dumps
        IOService *prov = fb->getProvider();
        IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, prov);
        if (pci) {
            IODeviceMemory *bar1 = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
            if (bar1) {
                vramBytes = bar1->getLength();
                fb->setProperty("IOFBMemorySize", vramBytes, 64);
            }
            /* Identity props on the IOPCIDevice ONLY (not also on framebuffer
             * — that caused system_profiler to report two GPUs). system_profiler
             * reads these: `model` for the chipset name, `AAPL,slot-name` for
             * the slot label. Without them VMware SVGA shows as "Unknown Unknown". */
            pci->setProperty("model", "VMware SVGA II");
            pci->setProperty("device_type", "display");
            pci->setProperty("AAPL,slot-name", "Built-in");
            uint8_t one = 1;
            pci->setProperty("built-in", &one, sizeof(one));
        }
        /* Explicitly do NOT set AAPL,GraphicsClass — the previous "IOBuiltInGraphics"
         * value triggered Metal=Supported in system_profiler, inviting macOS to
         * route 3D/GPU work to us. We have no Metal backing. Leaving the property
         * absent keeps macOS in "no GPU accelerator present" mode.
         *
         * EXPERIMENT: does setProperty override CFBundleIdentifier for system_profiler's
         * "Kernel Extension Info" check? The real kext that matched is IONDRVSupport
         * (generic Apple fallback), but we can see if a spoofed bundle ID here gets
         * picked up. Pretend to be VMsvga2 — system_profiler would recognize that. */
        fb->setProperty("CFBundleIdentifier", "com.vmware.kext.VMsvga2");
    }

    IOLog("QDP: enableController -> 0x%x (VRAM=%lluMB)\n",
          (unsigned)r, vramBytes / (1024 * 1024));
    return r;
}

static bool patchedHasDDCConnect(void *, int32_t) {
    QDP_COUNT(hasDDCConnect);
    QDP_FIRST_CALL("hasDDCConnect", "-> true");
    return true;
}

static IOReturn patchedGetDDCBlock(void *that, int32_t ci, uint32_t bn,
                                   uint32_t bt, uint32_t opts,
                                   uint8_t *data, uint64_t *length) {
    QDP_COUNT(getDDCBlock);
    QDP_FIRST_CALL("getDDCBlock", "bn=%u bt=%u", bn, bt);
    if (!data || !length) return 0xE00002BC;
    const uint8_t *src;
    if      (bn == 1) src = imac20_edid_block0;
    else if (bn == 2) src = imac20_edid_block1;
    else              return 0xE00002BC;  /* invalid block */
    uint64_t copyLen = (*length < 128) ? *length : 128;
    memcpy(data, src, (size_t)copyLen);
    *length = copyLen;
    return 0;
}

static IOReturn patchedSetGammaTable(void *, uint32_t, uint32_t, uint32_t, void *) {
    QDP_COUNT(setGammaTable);
    return 0;
}

static IODeviceMemory *patchedGetVRAMRange(void *that) {
    QDP_COUNT(getVRAMRange);
    if (!that || !orgGetVRAMRange) return orgGetVRAMRange ? orgGetVRAMRange(that) : nullptr;
    IOService *fb = static_cast<IOService *>(that);
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, fb->getProvider());
    if (pci) {
        IODeviceMemory *bar1 = pci->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
        if (bar1) { bar1->retain(); return bar1; }
    }
    return orgGetVRAMRange(that);
}

static IOReturn patchedSetAttributeForConnection(void *, int32_t, uint32_t, uintptr_t) {
    QDP_COUNT(setAttributeForConnection);
    return 0;
}

static IODeviceMemory *patchedGetApertureRange(void *that, int32_t aperture) {
    QDP_COUNT(getApertureRange);
    if (!orgGetApertureRange) return nullptr;
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
    QDP_COUNT(getPixelFormats);
    static const char fmts[] = IO32BitDirectPixels "\0";
    return fmts;
}

static uint32_t patchedGetDisplayModeCount(void *) {
    QDP_COUNT(getDisplayModeCount);
    QDP_FIRST_CALL("getDisplayModeCount", "-> %d", numModes);
    return numModes;
}

static IOReturn patchedGetDisplayModes(void *, int32_t *allModes) {
    QDP_COUNT(getDisplayModes);
    QDP_FIRST_CALL("getDisplayModes", "(n=%d)", numModes);
    if (!allModes) return 0xE00002BC;
    for (int i = 0; i < numModes; i++) allModes[i] = (int32_t)modes[i].id;
    return 0;
}

static IOReturn patchedGetInformationForDisplayMode(void *, int32_t mode, IODisplayModeInformation *info) {
    QDP_COUNT(getInformationForDisplayMode);
    QDP_FIRST_CALL("getInformationForDisplayMode", "mode=%d", mode);
    if (!info) return 0xE00002BC;
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            __sync_fetch_and_or(&gModesQueriedMask, (uint64_t)1 << i);
            bzero(info, sizeof(*info));
            info->maxDepthIndex = 0;
            info->nominalWidth  = modes[i].width;
            info->nominalHeight = modes[i].height;
            info->refreshRate   = modes[i].refreshRate;
            /* flags=0 (bzero default) caused macOS to silently reject every
             * mode beyond the first queried — it only called back for mode=1
             * and dropped modes 2-8. Valid+Safe is the minimum; Default on
             * mode 1 marks it as the preferred startup mode. */
            info->flags = kDisplayModeValidFlag | kDisplayModeSafeFlag;
            if (i == 0) info->flags |= kDisplayModeDefaultFlag;
            return 0;
        }
    }
    return 0xE00002C2;
}

static IOReturn patchedGetPixelInformation(void *, int32_t mode, int32_t depth, int32_t, IOPixelInformation *info) {
    QDP_COUNT(getPixelInformation);
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
    QDP_COUNT(getCurrentDisplayMode);
    if (mode) *mode = 1;
    if (depth) *depth = 0;
    return 0;
}

static IOReturn patchedSetDisplayMode(void *, int32_t mode, int32_t) {
    QDP_COUNT(setDisplayMode);
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == mode) {
            gCurrentWidth  = modes[i].width;
            gCurrentHeight = modes[i].height;
            return 0;
        }
    }
    return 0xE00002C2;
}

static uint64_t patchedGetPixelFormatsForDisplayMode(void *, int32_t, int32_t) {
    QDP_COUNT(getPixelFormatsForDisplayMode);
    return 0;
}

static IOReturn patchedGetTimingInfoForDisplayMode(void *, int32_t mode, IOTimingInformation *info) {
    QDP_COUNT(getTimingInfoForDisplayMode);
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

static uint32_t patchedGetConnectionCount(void *) {
    QDP_COUNT(getConnectionCount);
    return 1;
}

/* Phase 2 additions — methods our standalone QEMUDisplay.kext overrode but
 * QDP was leaving to IONDRVFramebuffer's NDRV-backed defaults. Mirrors the
 * behavior of kexts/QEMUDisplay/src/QEMUDisplay.cpp verbatim — that kext
 * worked, these functions are the diff between "working driver" and "hook
 * façade with NDRV leaking through". */

static IOReturn patchedGetAttribute(void *that, uint32_t attr, uintptr_t *value) {
    QDP_COUNT(getAttribute);
    QDP_FIRST_CALL("getAttribute", "attr=0x%x", attr);
    if (attr == kIOHardwareCursorAttribute) {
        if (value) *value = 0;
        return kIOReturnSuccess;
    }
    /* Delegate unknown attributes to the original impl — IOFramebuffer has
     * defaults (probe options, wait-cursor frames, etc.) that macOS expects
     * to get success for. Returning kIOReturnUnsupported for everything
     * broke EDID delivery (DisplayVendorID came back as 'unkn'). */
    if (orgGetAttribute) return orgGetAttribute(that, attr, value);
    return kIOReturnUnsupported;
}

static IOReturn patchedGetAttributeForConnection(void *that, int32_t ci, uint32_t attr, uintptr_t *value) {
    QDP_COUNT(getAttributeForConnection);
    QDP_FIRST_CALL("getAttributeForConnection", "ci=%d attr=0x%x", ci, attr);
    switch (attr) {
        case kConnectionEnable:
        case kConnectionCheckEnable:
            /* "Yes, this connection is live." Without this, macOS may treat
             * the connection as unreliable and clamp modes to a safe fallback. */
            if (value) *value = 1;
            return kIOReturnSuccess;
        case kConnectionFlags:
            if (value) *value = 0;
            return kIOReturnSuccess;
        case kConnectionSupportsHLDDCSense:
            /* We DO support high-level DDC (hasDDCConnect + getDDCBlock both
             * implemented). Per IOFramebuffer.h:814, return success (no value)
             * so macOS takes the EDID path instead of the Apple-sense path. */
            return kIOReturnSuccess;
        case kConnectionSupportsAppleSense:
            return kIOReturnUnsupported;
        default:
            /* Delegate unknown to original — dozens of kConnection* attrs
             * exist. Wholesale-rejecting broke EDID. */
            if (orgGetAttributeForConnection)
                return orgGetAttributeForConnection(that, ci, attr, value);
            return kIOReturnUnsupported;
    }
}

static IOReturn patchedRegisterForInterruptType(void *that, uint32_t type,
                                                QDPInterruptProc proc, OSObject *target,
                                                void *ref, void **interruptRef) {
    QDP_COUNT(registerForInterruptType);
    QDP_FIRST_CALL("registerForInterruptType", "type=0x%x", type);
    /* Give each interrupt type a unique non-null handle. macOS stores this
     * and passes it back to setInterruptState / unregisterInterrupt. */
    if (interruptRef) *interruptRef = (void *)(uintptr_t)(type + 1);
    return kIOReturnSuccess;
}

static IOReturn patchedUnregisterInterrupt(void *that, void *interruptRef) {
    QDP_COUNT(unregisterInterrupt);
    return kIOReturnSuccess;
}

static IOReturn patchedSetInterruptState(void *that, void *interruptRef, uint32_t state) {
    QDP_COUNT(setInterruptState);
    return kIOReturnSuccess;
}

static IOReturn patchedConnectFlags(void *that, int32_t ci, int32_t modeID, uint32_t *flags) {
    QDP_COUNT(connectFlags);
    QDP_FIRST_CALL("connectFlags", "ci=%d mode=%d", ci, modeID);
    if (!flags) return 0xE00002BC;
    /* Every mode we advertise is valid + safe; mark mode 1 as default. Modes
     * not in our list: delegate to org (let IONDRVFramebuffer's NDRV path
     * decide for standard VESA modes macOS might synthesize). */
    for (int i = 0; i < numModes; i++) {
        if ((int32_t)modes[i].id == modeID) {
            *flags = kDisplayModeValidFlag | kDisplayModeSafeFlag;
            if (i == 0) *flags |= kDisplayModeDefaultFlag;
            return kIOReturnSuccess;
        }
    }
    if (orgConnectFlags) return orgConnectFlags(that, ci, modeID, flags);
    *flags = 0;
    return kIOReturnSuccess;
}

static IOReturn patchedSetupForCurrentConfig(void *that) {
    QDP_COUNT(setupForCurrentConfig);
    if (!orgSetupForCurrentConfig) { IOLog("QDP: orgSetupForCurrentConfig NULL — skipping\n"); return 0; }
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

    /* Opportunistic counter flush. setupForCurrentConfig gets called at least
     * once during init and later on reconfig events. Each call, snapshot our
     * counters into IOService properties so verify-modes.sh can read them. */
    if (that) {
        IOService *fb = static_cast<IOService *>(that);
        OSArray *arr = OSArray::withCapacity(QDP_HOOK_COUNT);
        if (arr) {
            for (int i = 0; i < QDP_HOOK_COUNT; i++) {
                char line[128];
                snprintf(line, sizeof(line), "%s=%u",
                         gHookNames[i], gHookCounters[i]);
                OSString *s = OSString::withCString(line);
                if (s) { arr->setObject(s); s->release(); }
            }
            fb->setProperty("QDPCallCounts", arr);
            arr->release();
        }
        fb->setProperty("QDPModesQueriedMask",
                        (unsigned long long)gModesQueriedMask, 64);
    }
    return r;
}

// === Kext entry — register routes via mos15-patcher ===========================
//
// Two routes per method (derived IONDRVFramebuffer + base IOFramebuffer)
// cover both overridden methods and those inherited unchanged. Whichever
// symbol the patcher finds first in the kext's __LINKEDIT wins its vtable
// slot; the other is a harmless no-op. MP_ROUTE_PAIR from mos15_patcher.h
// takes care of both the dual-class registration and the prefix-based
// symbol lookup, so we don't write Itanium paramSigs by hand anymore.

extern "C"
kern_return_t qdp_start(kmod_info_t *ki, void *d)
{
    IOLog("QDP: starting (mos15-patcher edition)\n");

    #define PAIR(method, replacement, org) \
        MP_ROUTE_PAIR("IONDRVFramebuffer", "IOFramebuffer", (method), (replacement), (org))

    mp_route_request_t reqs[] = {
        PAIR("enableController",              patchedEnableController,              orgEnableController),
        PAIR("hasDDCConnect",                 patchedHasDDCConnect,                 orgHasDDCConnect),
        PAIR("getDDCBlock",                   patchedGetDDCBlock,                   orgGetDDCBlock),
        /* setGammaTable is overloaded (4-arg + 5-arg-with-bool in IONDRVFramebuffer.h),
         * so prefix match is ambiguous. Disambiguate with the 4-arg sig. */
        MP_ROUTE_PAIR_SIG("IONDRVFramebuffer", "IOFramebuffer",
                          "setGammaTable", "jjjPv",
                          patchedSetGammaTable, orgSetGammaTable),
        PAIR("getVRAMRange",                  patchedGetVRAMRange,                  orgGetVRAMRange),
        PAIR("setAttributeForConnection",     patchedSetAttributeForConnection,     orgSetAttributeForConnection),
        PAIR("getApertureRange",              patchedGetApertureRange,              orgGetApertureRange),
        PAIR("getPixelFormats",               patchedGetPixelFormats,               orgGetPixelFormats),
        PAIR("getDisplayModeCount",           patchedGetDisplayModeCount,           orgGetDisplayModeCount),
        PAIR("getDisplayModes",               patchedGetDisplayModes,               orgGetDisplayModes),
        PAIR("getInformationForDisplayMode",  patchedGetInformationForDisplayMode,  orgGetInformationForDisplayMode),
        PAIR("getPixelInformation",           patchedGetPixelInformation,           orgGetPixelInformation),
        PAIR("getCurrentDisplayMode",         patchedGetCurrentDisplayMode,         orgGetCurrentDisplayMode),
        PAIR("setDisplayMode",                patchedSetDisplayMode,                orgSetDisplayMode),
        PAIR("getPixelFormatsForDisplayMode", patchedGetPixelFormatsForDisplayMode, orgGetPixelFormatsForDisplayMode),
        PAIR("getTimingInfoForDisplayMode",   patchedGetTimingInfoForDisplayMode,   orgGetTimingInfoForDisplayMode),
        PAIR("getConnectionCount",            patchedGetConnectionCount,            orgGetConnectionCount),
        PAIR("setupForCurrentConfig",         patchedSetupForCurrentConfig,         orgSetupForCurrentConfig),
        /* Phase 2 — matches QEMUDisplay.kext's override set exactly. */
        PAIR("getAttribute",                  patchedGetAttribute,                  orgGetAttribute),
        PAIR("getAttributeForConnection",     patchedGetAttributeForConnection,     orgGetAttributeForConnection),
        PAIR("registerForInterruptType",      patchedRegisterForInterruptType,      orgRegisterForInterruptType),
        PAIR("unregisterInterrupt",           patchedUnregisterInterrupt,           orgUnregisterInterrupt),
        PAIR("setInterruptState",             patchedSetInterruptState,             orgSetInterruptState),
        /* Phase 3 — per-mode visibility; IONDRVFramebuffer's default delegates to NDRV. */
        PAIR("connectFlags",                  patchedConnectFlags,                  orgConnectFlags),
    };
    int n = sizeof(reqs) / sizeof(*reqs);
    #undef PAIR

    int rc = mp_route_on_publish("IONDRVFramebuffer",
                                  "com.apple.iokit.IONDRVSupport",
                                  reqs, n);
    IOLog("QDP: mp_route_on_publish returned %d (n=%d routes)\n", rc, n);

    return KERN_SUCCESS;
}

extern "C"
kern_return_t qdp_stop(kmod_info_t *ki, void *d)
{
    /* Don't allow unload — our hooks live in shared kernel pages. */
    return KERN_FAILURE;
}
