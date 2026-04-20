//
// patcher.cpp — mos15-metal, Phase -1.B scaffold.
//
// Publishes a fake IOAccelerator-typed IOService so we can observe
// Metal.framework's enumeration pass and classify its
// plugin-bundle validation behavior. Does NOT yet hook anything or
// pretend to service commands — the goal is diagnostic logging,
// not functionality.
//
// The AcceleratorProperties dict in Info.plist carries
// MetalPluginName=AppleParavirtGPUMetal, which points Metal at
// /System/Library/Extensions/AppleParavirtGPUMetal.bundle (ships
// with the guest macOS install — Apple's own paravirt plugin
// bundle, not one we forge).
//

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSString.h>
#include <mach/mach_types.h>

class MOSMetalAccelerator : public IOService {
    OSDeclareDefaultStructors(MOSMetalAccelerator)
public:
    virtual bool start(IOService *provider) override;
    virtual void stop(IOService *provider) override;
};

OSDefineMetaClassAndStructors(MOSMetalAccelerator, IOService)

bool MOSMetalAccelerator::start(IOService *provider)
{
    IOLog("mos15-metal: MOSMetalAccelerator::start provider=%p\n", provider);
    if (!IOService::start(provider)) {
        IOLog("mos15-metal: super::start failed\n");
        return false;
    }

    /* AcceleratorProperties from Info.plist is already copied into our
     * registry entry by IOKit's matching machinery. We just need to be
     * discoverable — registerService publishes us so Metal.framework can
     * enumerate. */
    registerService();
    IOLog("mos15-metal: registerService called\n");
    return true;
}

void MOSMetalAccelerator::stop(IOService *provider)
{
    IOLog("mos15-metal: stop\n");
    IOService::stop(provider);
}

extern "C" kern_return_t mos15_metal_start(kmod_info_t *, void *) {
    IOLog("mos15-metal: kmod start (Phase -1.B scaffold — fake IOAccelerator publish)\n");
    return KERN_SUCCESS;
}

extern "C" kern_return_t mos15_metal_stop(kmod_info_t *, void *) {
    /* Don't allow unload — our IOService subclass is referenced by
     * the running instance. */
    return KERN_FAILURE;
}
