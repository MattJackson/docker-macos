//
// patcher.cpp — mos15-metal, Phase -1.A scaffold.
//
// Empty start/stop that only emits an IOLog breadcrumb. No mos-patcher
// dependency yet (Phase -1.A.4 decides the fallback story). No
// IOKitPersonality-side IOService subclass — the kext just needs to
// *load* and run its kmod start func. Later Phase -1 sub-phases
// replace this with a real IOService and route table.
//

#include <IOKit/IOLib.h>
#include <mach/mach_types.h>

extern "C" kern_return_t mos15_metal_start(kmod_info_t *ki, void *) {
    IOLog("mos15-metal: start (scaffold, Phase -1.A)\n");
    return KERN_SUCCESS;
}

extern "C" kern_return_t mos15_metal_stop(kmod_info_t *, void *) {
    IOLog("mos15-metal: stop\n");
    return KERN_SUCCESS;
}
