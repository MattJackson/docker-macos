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
#include <libkern/c++/OSNumber.h>
#include <architecture/i386/pio.h>

#include "qdp_patcher.hpp"

// === iMac EDID (128 bytes, name "iMac") ======================================
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

// === Runtime mode flag ======================================================
// gBasicMode = true → every hook is pure passthrough to original (no SMC,
// no setProperty, no EDID substitution). Toggled by `-qdpbasic` boot-arg.
// Default false → full QDP behaviour. See kern_start.cpp for the bootarg.
static bool gBasicMode = false;

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
        {"__ZN17IONDRVFramebuffer16enableControllerEv",  patchedEnableController, orgEnableController},
        {"__ZN17IONDRVFramebuffer13hasDDCConnectEi",     patchedHasDDCConnect,    orgHasDDCConnect},
        {"__ZN17IONDRVFramebuffer11getDDCBlockEijjjPhPy", patchedGetDDCBlock,     orgGetDDCBlock},
        {"__ZN17IONDRVFramebuffer13setGammaTableEjjjPv", patchedSetGammaTable,    orgSetGammaTable},
        {"__ZN17IONDRVFramebuffer12getVRAMRangeEv",      patchedGetVRAMRange,     orgGetVRAMRange},
    };
    patcher.routeMultiple(id, reqs, arrsize(reqs), slide, size);

    if (patcher.getError() == KernelPatcher::Error::NoError)
        IOLog("QDP: 5/5 routed (P1 mirror + getVRAMRange)\n");
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
