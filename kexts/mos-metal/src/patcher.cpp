//
// patcher.cpp — mos-metal, Phase -1.D.5 hook.
//
// Hooks AppleParavirtGPUControl::setupMMIO() in Apple's own
// com.apple.driver.AppleParavirtGPU. The real setupMMIO maps the
// paravirt device's MMIO BAR (BAR0) and writes a pointer (map+0x1000)
// into this->field_0x168. Subsequent code in start() dereferences
// that field to read capability/feature values.
//
// Our fake QEMU device (Phase -1.D.1: VMware SVGA with Apple PCI
// IDs) has BAR0 as I/O space, not memory. Apple's
// mapDeviceMemoryWithRegister fails → setupMMIO's second error
// path → returns false (and start() should bail). In practice the
// VM panic-loops at start+0x7c anyway.
//
// We replace setupMMIO with a stub that allocates a zero-filled
// buffer and stores it at this->field_0x168. Apple's subsequent
// code reads zeros (= "no optional capabilities"), takes safe
// paths, publishes child services (AppleParavirtAccelerator,
// AppleParavirtFramebuffer). Metal then enumerates.
//
// Phase -1.D.4 disassembly is the source of truth for field
// offsets. Rev this hook when Apple revs the kext.
//

#include <mos15_patcher.h>

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <libkern/c++/OSObject.h>
#include <mach/mach_types.h>
#include <string.h>

/* Offsets into AppleParavirtGPUControl, from phase-1d4-disasm.txt. */
static const size_t kPVGPUC_Field_0x160 = 0x160;  /* IOMemoryMap* (we fake with our buffer ptr) */
static const size_t kPVGPUC_Field_0x168 = 0x168;  /* paravirt-metadata pointer */

/* Size of the fake metadata buffer. Apple's code reads at least
 * [field+0x22c] during start(). Later code may read more. 0x1000
 * (4 KB, one page) is a conservative ceiling — all zeros, all safe. */
static const size_t kFakeMetaSize = 0x1000;

/* Trampoline for Apple's original setupMMIO (unused — we fully
 * replace — but mp_route_kext needs somewhere to stash the prologue
 * bytes). */
static bool (*orgSetupMMIO)(void *self) = nullptr;

/* Our replacement. Called with rdi = this (AppleParavirtGPUControl*). */
static bool patchedSetupMMIO(void *self)
{
    IOLog("mos-metal: patchedSetupMMIO entered, self=%p\n", self);

    /* Idempotence — if something else populated field_0x168 already,
     * leave it. */
    void **f168 = (void **)((uint8_t *)self + kPVGPUC_Field_0x168);
    if (*f168) {
        IOLog("mos-metal: setupMMIO field_0x168 already %p — skipping\n", *f168);
        return true;
    }

    void *meta = IOMallocAligned(kFakeMetaSize, sizeof(void *));
    if (!meta) {
        IOLog("mos-metal: setupMMIO IOMallocAligned(%zu) failed\n",
              kFakeMetaSize);
        return false;
    }
    bzero(meta, kFakeMetaSize);
    *f168 = meta;

    /* Apple's setupMMIO also sets field_0x160 to the IOMemoryMap
     * pointer. We have no map, so leave NULL for now — if downstream
     * code dereferences field_0x160 we'll iterate. */

    IOLog("mos-metal: setupMMIO fake metadata %p (size %zu) stored at this+0x%zx\n",
          meta, kFakeMetaSize, kPVGPUC_Field_0x168);
    return true;
}

class MOSMetalAccelerator : public IOService {
    OSDeclareDefaultStructors(MOSMetalAccelerator)
public:
    virtual bool start(IOService *provider) override;
    virtual void stop(IOService *provider) override;
};

OSDefineMetaClassAndStructors(MOSMetalAccelerator, IOService)

bool MOSMetalAccelerator::start(IOService *provider)
{
    IOLog("mos-metal: MOSMetalAccelerator::start provider=%p\n", provider);
    if (!IOService::start(provider)) {
        IOLog("mos-metal: super::start failed\n");
        return false;
    }

    /* Install the AppleParavirtGPU setupMMIO hook. mp_route_kext
     * does prologue-patching; orgSetupMMIO becomes the trampoline
     * address (unused since we fully replace, but required by API). */
    mp_route_request_t reqs[] = {
        MP_ROUTE_EXACT(
            "__ZN23AppleParavirtGPUControl9setupMMIOEv",
            (void *)patchedSetupMMIO,
            orgSetupMMIO)
    };
    int rc = mp_route_kext("com.apple.driver.AppleParavirtGPU",
                            reqs, sizeof(reqs) / sizeof(*reqs));
    IOLog("mos-metal: mp_route_kext(AppleParavirtGPU setupMMIO) -> %d\n", rc);
    /* rc: 0 = applied, 1 = queued (kext not yet loaded), negative = error.
     * Even if queued, the live-chain fallback in mos-patcher will
     * eventually resolve once AppleParavirtGPU arrives. */

    registerService();
    return true;
}

void MOSMetalAccelerator::stop(IOService *provider)
{
    IOLog("mos-metal: stop\n");
    IOService::stop(provider);
}

extern "C" kern_return_t mos_metal_start(kmod_info_t *, void *) {
    IOLog("mos-metal: kmod start (Phase -1.D.5 — setupMMIO hook)\n");
    return KERN_SUCCESS;
}

extern "C" kern_return_t mos_metal_stop(kmod_info_t *, void *) {
    /* Patches live in shared kernel pages — don't allow unload. */
    return KERN_FAILURE;
}
