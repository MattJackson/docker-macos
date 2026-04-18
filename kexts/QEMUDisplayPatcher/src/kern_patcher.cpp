//
//  kern_patcher.cpp
//  QEMUDisplayPatcher
//
//  Step 1: PROVEN WORKING enableController hook.
//  Adding one thing at a time from here.
//

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_patcher.hpp>

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/pci/IOPCIDevice.h>

#include "qdp_patcher.hpp"

// Originals
static IOReturn (*orgEnableController)(void *) = nullptr;
static IODeviceMemory * (*orgGetVRAMRange)(void *) = nullptr;
static IODeviceMemory * (*orgGetApertureRange)(void *, int32_t) = nullptr;

// Cached PCI device
static IOPCIDevice *gPCIDevice = nullptr;

static IOReturn patchedEnableController(void *that) {
    IOLog("QDP: enableController ENTER\n");

    // Grab PCI device before calling original
    IOService *svc = (IOService *)that;
    IOService *provider = svc->getProvider();
    if (provider)
        gPCIDevice = OSDynamicCast(IOPCIDevice, provider);
    IOLog("QDP: pciDev=%p\n", gPCIDevice);

    IOReturn ret = orgEnableController ? orgEnableController(that) : 0;
    IOLog("QDP: original ret=%d\n", ret);

    // Set VRAM from BAR1 size
    if (gPCIDevice) {
        IODeviceMemory *vram = gPCIDevice->getDeviceMemoryWithRegister(0x14);
        if (vram) {
            uint64_t sz = vram->getLength();
            svc->setProperty("IOFBMemorySize", sz, 64);
            IOLog("QDP: VRAM=%llu from BAR1\n", sz);
        }

        // SMC GPU power
        uint8_t on = 1;
        // Use inline asm for SMC port I/O
        asm volatile("outb %0, %1" : : "a"((uint8_t)0x11), "Nd"((uint16_t)0x304));
        IODelay(10000);
    }

    svc->setProperty("IOFB0Hz", true);
    svc->setProperty("IOFBGammaCount", (uint64_t)256, 32);
    svc->setProperty("IOFBGammaWidth", (uint64_t)8, 32);

    IOLog("QDP: enableController DONE\n");
    return ret;
}

static IODeviceMemory *patchedGetVRAMRange(void *that) {
    IOLog("QDP: getVRAMRange\n");
    if (gPCIDevice) {
        IODeviceMemory *vram = gPCIDevice->getDeviceMemoryWithRegister(0x14);
        if (vram) {
            IOLog("QDP: returning BAR1 %llu bytes\n", vram->getLength());
            return vram;
        }
    }
    return orgGetVRAMRange ? orgGetVRAMRange(that) : nullptr;
}

static IODeviceMemory *patchedGetApertureRange(void *that, int32_t aperture) {
    if (aperture != 0) // kIOFBSystemAperture = 0
        return orgGetApertureRange ? orgGetApertureRange(that, aperture) : nullptr;

    if (gPCIDevice) {
        IODeviceMemory *vram = gPCIDevice->getDeviceMemoryWithRegister(0x14);
        if (vram) {
            // Return sub-range for 1920x1080x4
            IOByteCount fbSize = 1920 * 1080 * 4;
            return IODeviceMemory::withSubRange(vram, 0, fbSize);
        }
    }
    return orgGetApertureRange ? orgGetApertureRange(that, aperture) : nullptr;
}

// Kext info
static const char *kextPath[] {
    "/System/Library/Extensions/IONDRVSupport.kext/IONDRVSupport"
};

static KernelPatcher::KextInfo kextInfo {
    "com.apple.iokit.IONDRVSupport",
    kextPath, 1,
    {true}, {},
    KernelPatcher::KextInfo::Unloaded
};

static void onKextLoad(void *user, KernelPatcher &patcher, size_t id, mach_vm_address_t slide, size_t size) {
    IOLog("QDP: onKextLoad id=%lu\n", (unsigned long)id);

    KernelPatcher::RouteRequest reqs[] = {
        {"__ZN17IONDRVFramebuffer16enableControllerEv",
         patchedEnableController, orgEnableController},
    };
    patcher.routeMultiple(id, reqs, arrsize(reqs), slide, size);

    if (patcher.getError() == KernelPatcher::Error::NoError)
        IOLog("QDP: routed OK\n");
    else {
        IOLog("QDP: route err %d\n", patcher.getError());
        patcher.clearError();
    }
}

void pluginStart() {
    IOLog("QDP: pluginStart\n");
    lilu.onKextLoadForce(&kextInfo, 1, onKextLoad);
}
