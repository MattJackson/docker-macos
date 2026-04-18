//
//  kern_patcher.cpp
//  QEMUDisplayPatcher
//
//  Phase 1: Prove the Lilu plugin pipeline works.
//  Hook IONDRVFramebuffer::enableController with IOLog.
//  Once this fires, add the full QEMUDisplay behavior.
//

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_patcher.hpp>

#include "qdp_patcher.hpp"

// Original function pointer
static IOReturn (*orgEnableController)(void *that) = nullptr;

// Our replacement — just log and call original for now
static IOReturn patchedEnableController(void *that) {
    IOLog("QDP: >>>>>> enableController HOOKED — plugin is working! <<<<<<\n");

    // Call original so the driver still works
    if (orgEnableController)
        return orgEnableController(that);
    return 0; // kIOReturnSuccess
}

// Kext info for IONDRVSupport — the kext that contains IONDRVFramebuffer
static const char *kextPath[] {
    "/System/Library/Extensions/IONDRVSupport.kext/IONDRVSupport"
};

static KernelPatcher::KextInfo kextInfo {
    "com.apple.iokit.IONDRVSupport",
    kextPath,
    1,
    {true},   // loaded = true (look for already-loaded kext)
    {},       // user flags
    KernelPatcher::KextInfo::Unloaded
};

// Callback when IONDRVSupport loads
static void onKextLoad(void *user, KernelPatcher &patcher, size_t id, mach_vm_address_t slide, size_t size) {
    IOLog("QDP: onKextLoad fired for IONDRVSupport (id=%lu slide=0x%llx size=%lu)\n",
          (unsigned long)id, (unsigned long long)slide, (unsigned long)size);

    // Route IONDRVFramebuffer::enableController
    KernelPatcher::RouteRequest req {
        "__ZN18IONDRVFramebuffer16enableControllerEv",
        patchedEnableController,
        orgEnableController
    };

    if (patcher.routeMultiple(id, &req, 1, slide, size)) {
        IOLog("QDP: enableController routed OK\n");
    } else {
        IOLog("QDP: enableController route FAILED (error %d)\n", patcher.getError());
        patcher.clearError();
    }
}

// Plugin entry point — called by Lilu from kern_start
void pluginStart() {
    IOLog("QDP: pluginStart called\n");

    lilu.onKextLoadForce(&kextInfo, 1, onKextLoad);

    IOLog("QDP: registered for IONDRVSupport kext load\n");
}
