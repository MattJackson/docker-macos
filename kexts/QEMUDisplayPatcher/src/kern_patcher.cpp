//
//  kern_patcher.cpp
//  QEMUDisplayPatcher
//
//  Pass-through hooks: route every IONDRVFramebuffer override as transparent
//  call-original. Behaviour identical to baseline (OEM IONDRV). Once boot is
//  confirmed for the full hook surface, swap individual hooks to actual
//  custom behaviour.
//
//  Each wrapper logs only its first invocation via a static counter — avoids
//  flooding the boot log with hot-path methods.
//
//  TODO: registerForInterruptType skipped for now (function-pointer parameter
//  signature is fiddly to mangle; not on the critical path).
//

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_patcher.hpp>

#include <IOKit/IOLib.h>

#include "qdp_patcher.hpp"

// Forward decls of opaque types we don't need definitions for in wrappers.
class IOService;
class OSObject;
class OSArray;
struct IODisplayModeInformation;
struct IOPixelInformation;
struct IOTimingInformation;
struct IOColorEntry;
struct IOI2CBusTiming;
struct IOI2CRequest;
class IODeviceMemory;

// === Trampolines (set by Lilu when route applies) ============================

// IOService overrides
static IOService *(*orgProbe)(void *, IOService *, int32_t *) = nullptr;
static bool       (*orgStart)(void *, IOService *) = nullptr;
static void       (*orgStop)(void *, IOService *) = nullptr;
static void       (*orgFree)(void *) = nullptr;
static IOReturn   (*orgSetProperties)(void *, OSObject *) = nullptr;

// IOService power-mgmt
static unsigned long (*orgMaxCapabilityForDomainState)(void *, unsigned long) = nullptr;
static unsigned long (*orgInitialPowerStateForDomainState)(void *, unsigned long) = nullptr;
static unsigned long (*orgPowerStateForDomainState)(void *, unsigned long) = nullptr;

// IOFramebuffer overrides
static IOReturn        (*orgRequestProbe)(void *, uint32_t) = nullptr;
static IOReturn        (*orgEnableController)(void *) = nullptr;
static IODeviceMemory *(*orgGetApertureRange)(void *, int32_t) = nullptr;
static IODeviceMemory *(*orgGetVRAMRange)(void *) = nullptr;
static bool            (*orgIsConsoleDevice)(void *) = nullptr;
static const char *    (*orgGetPixelFormats)(void *) = nullptr;
static uint32_t        (*orgGetDisplayModeCount)(void *) = nullptr;
static IOReturn        (*orgGetDisplayModes)(void *, int32_t *) = nullptr;
static IOReturn        (*orgGetInformationForDisplayMode)(void *, int32_t, IODisplayModeInformation *) = nullptr;
static uint64_t        (*orgGetPixelFormatsForDisplayMode)(void *, int32_t, int32_t) = nullptr;
static IOReturn        (*orgGetPixelInformation)(void *, int32_t, int32_t, int32_t, IOPixelInformation *) = nullptr;
static IOReturn        (*orgSetupForCurrentConfig)(void *) = nullptr;
static IOReturn        (*orgGetCurrentDisplayMode)(void *, int32_t *, int32_t *) = nullptr;
static IOReturn        (*orgSetDisplayMode)(void *, int32_t, int32_t) = nullptr;
static IOReturn        (*orgSetApertureEnable)(void *, int32_t, uint32_t) = nullptr;
static IOReturn        (*orgSetStartupDisplayMode)(void *, int32_t, int32_t) = nullptr;
static IOReturn        (*orgGetStartupDisplayMode)(void *, int32_t *, int32_t *) = nullptr;
static IOReturn        (*orgSetCLUTWithEntries)(void *, IOColorEntry *, uint32_t, uint32_t, uint32_t) = nullptr;
static IOReturn        (*orgSetGammaTable)(void *, uint32_t, uint32_t, uint32_t, void *) = nullptr;
static IOReturn        (*orgGetTimingInfoForDisplayMode)(void *, int32_t, IOTimingInformation *) = nullptr;
static IOReturn        (*orgValidateDetailedTiming)(void *, void *, uint64_t) = nullptr;
static IOReturn        (*orgSetDetailedTimings)(void *, OSArray *) = nullptr;
static IOReturn        (*orgSetAttribute)(void *, uint32_t, uintptr_t) = nullptr;
static IOReturn        (*orgGetAttribute)(void *, uint32_t, uintptr_t *) = nullptr;
static uint32_t        (*orgGetConnectionCount)(void *) = nullptr;
static IOReturn        (*orgGetAttributeForConnection)(void *, int32_t, uint32_t, uintptr_t *) = nullptr;
static IOReturn        (*orgSetAttributeForConnection)(void *, int32_t, uint32_t, uintptr_t) = nullptr;
static IOReturn        (*orgGetAppleSense)(void *, int32_t, uint32_t *, uint32_t *, uint32_t *, uint32_t *) = nullptr;
static IOReturn        (*orgConnectFlags)(void *, int32_t, int32_t, uint32_t *) = nullptr;
static bool            (*orgHasDDCConnect)(void *, int32_t) = nullptr;
static IOReturn        (*orgGetDDCBlock)(void *, int32_t, uint32_t, uint32_t, uint32_t, uint8_t *, uint64_t *) = nullptr;
static IOReturn        (*orgUnregisterInterrupt)(void *, void *) = nullptr;
static IOReturn        (*orgSetInterruptState)(void *, void *, uint32_t) = nullptr;
static IOReturn        (*orgSetCursorImage)(void *, void *) = nullptr;
static IOReturn        (*orgSetCursorState)(void *, int32_t, int32_t, bool) = nullptr;
static IOReturn        (*orgDoI2CRequest)(void *, uint32_t, IOI2CBusTiming *, IOI2CRequest *) = nullptr;

// === Helpers =================================================================

// First-call logger. ONCE("name") prints the first time the line executes.
#define ONCE(name) do { static int __c = 0; if (++__c == 1) IOLog("QDP: %s (first call)\n", name); } while (0)

// === Patched wrappers ========================================================

#define PT0_RET(name, ret_t) \
    static ret_t patched##name(void *that) { ONCE(#name); return org##name(that); }

#define PT_VOID(name) \
    static void patched##name(void *that) { ONCE(#name); org##name(that); }

#define PT0_VOID_OBJ(name) \
    static void patched##name(void *that, IOService *p) { ONCE(#name); org##name(that, p); }

PT0_RET(EnableController,            IOReturn)
PT0_RET(GetVRAMRange,                IODeviceMemory *)
PT0_RET(IsConsoleDevice,             bool)
PT0_RET(GetPixelFormats,             const char *)
PT0_RET(GetDisplayModeCount,         uint32_t)
PT0_RET(SetupForCurrentConfig,       IOReturn)
PT0_RET(GetConnectionCount,          uint32_t)

static void patchedFree(void *that) { ONCE("Free"); orgFree(that); }
static void patchedStop(void *that, IOService *p) { ONCE("Stop"); orgStop(that, p); }
static bool patchedStart(void *that, IOService *p) { ONCE("Start"); return orgStart(that, p); }
static IOService *patchedProbe(void *that, IOService *p, int32_t *score) { ONCE("Probe"); return orgProbe(that, p, score); }
static IOReturn patchedSetProperties(void *that, OSObject *o) { ONCE("SetProperties"); return orgSetProperties(that, o); }

static unsigned long patchedMaxCapabilityForDomainState(void *that, unsigned long s) { ONCE("MaxCapForDomainState"); return orgMaxCapabilityForDomainState(that, s); }
static unsigned long patchedInitialPowerStateForDomainState(void *that, unsigned long s) { ONCE("InitialPowerStateForDomainState"); return orgInitialPowerStateForDomainState(that, s); }
static unsigned long patchedPowerStateForDomainState(void *that, unsigned long s) { ONCE("PowerStateForDomainState"); return orgPowerStateForDomainState(that, s); }

static IOReturn patchedRequestProbe(void *that, uint32_t opts) { ONCE("RequestProbe"); return orgRequestProbe(that, opts); }
static IODeviceMemory *patchedGetApertureRange(void *that, int32_t ap) { ONCE("GetApertureRange"); return orgGetApertureRange(that, ap); }
static IOReturn patchedGetDisplayModes(void *that, int32_t *modes) { ONCE("GetDisplayModes"); return orgGetDisplayModes(that, modes); }
static IOReturn patchedGetInformationForDisplayMode(void *that, int32_t m, IODisplayModeInformation *info) { ONCE("GetInformationForDisplayMode"); return orgGetInformationForDisplayMode(that, m, info); }
static uint64_t patchedGetPixelFormatsForDisplayMode(void *that, int32_t m, int32_t d) { ONCE("GetPixelFormatsForDisplayMode"); return orgGetPixelFormatsForDisplayMode(that, m, d); }
static IOReturn patchedGetPixelInformation(void *that, int32_t m, int32_t d, int32_t ap, IOPixelInformation *info) { ONCE("GetPixelInformation"); return orgGetPixelInformation(that, m, d, ap, info); }
static IOReturn patchedGetCurrentDisplayMode(void *that, int32_t *m, int32_t *d) { ONCE("GetCurrentDisplayMode"); return orgGetCurrentDisplayMode(that, m, d); }
static IOReturn patchedSetDisplayMode(void *that, int32_t m, int32_t d) { ONCE("SetDisplayMode"); return orgSetDisplayMode(that, m, d); }
static IOReturn patchedSetApertureEnable(void *that, int32_t ap, uint32_t en) { ONCE("SetApertureEnable"); return orgSetApertureEnable(that, ap, en); }
static IOReturn patchedSetStartupDisplayMode(void *that, int32_t m, int32_t d) { ONCE("SetStartupDisplayMode"); return orgSetStartupDisplayMode(that, m, d); }
static IOReturn patchedGetStartupDisplayMode(void *that, int32_t *m, int32_t *d) { ONCE("GetStartupDisplayMode"); return orgGetStartupDisplayMode(that, m, d); }
static IOReturn patchedSetCLUTWithEntries(void *that, IOColorEntry *colors, uint32_t idx, uint32_t n, uint32_t opts) { ONCE("SetCLUTWithEntries"); return orgSetCLUTWithEntries(that, colors, idx, n, opts); }
static IOReturn patchedSetGammaTable(void *that, uint32_t cc, uint32_t dc, uint32_t dw, void *data) { ONCE("SetGammaTable"); return orgSetGammaTable(that, cc, dc, dw, data); }
static IOReturn patchedGetTimingInfoForDisplayMode(void *that, int32_t m, IOTimingInformation *info) { ONCE("GetTimingInfoForDisplayMode"); return orgGetTimingInfoForDisplayMode(that, m, info); }
static IOReturn patchedValidateDetailedTiming(void *that, void *desc, uint64_t size) { ONCE("ValidateDetailedTiming"); return orgValidateDetailedTiming(that, desc, size); }
static IOReturn patchedSetDetailedTimings(void *that, OSArray *arr) { ONCE("SetDetailedTimings"); return orgSetDetailedTimings(that, arr); }
static IOReturn patchedSetAttribute(void *that, uint32_t attr, uintptr_t v) { ONCE("SetAttribute"); return orgSetAttribute(that, attr, v); }
static IOReturn patchedGetAttribute(void *that, uint32_t attr, uintptr_t *v) { ONCE("GetAttribute"); return orgGetAttribute(that, attr, v); }
static IOReturn patchedGetAttributeForConnection(void *that, int32_t ci, uint32_t attr, uintptr_t *v) { ONCE("GetAttributeForConnection"); return orgGetAttributeForConnection(that, ci, attr, v); }
static IOReturn patchedSetAttributeForConnection(void *that, int32_t ci, uint32_t attr, uintptr_t v) { ONCE("SetAttributeForConnection"); return orgSetAttributeForConnection(that, ci, attr, v); }
static IOReturn patchedGetAppleSense(void *that, int32_t ci, uint32_t *st, uint32_t *p, uint32_t *e, uint32_t *dt) { ONCE("GetAppleSense"); return orgGetAppleSense(that, ci, st, p, e, dt); }
static IOReturn patchedConnectFlags(void *that, int32_t ci, int32_t m, uint32_t *flags) { ONCE("ConnectFlags"); return orgConnectFlags(that, ci, m, flags); }
static bool patchedHasDDCConnect(void *that, int32_t ci) { ONCE("HasDDCConnect"); return orgHasDDCConnect(that, ci); }
static IOReturn patchedGetDDCBlock(void *that, int32_t ci, uint32_t bn, uint32_t bt, uint32_t opts, uint8_t *data, uint64_t *length) { ONCE("GetDDCBlock"); return orgGetDDCBlock(that, ci, bn, bt, opts, data, length); }
static IOReturn patchedUnregisterInterrupt(void *that, void *ref) { ONCE("UnregisterInterrupt"); return orgUnregisterInterrupt(that, ref); }
static IOReturn patchedSetInterruptState(void *that, void *ref, uint32_t st) { ONCE("SetInterruptState"); return orgSetInterruptState(that, ref, st); }
static IOReturn patchedSetCursorImage(void *that, void *img) { ONCE("SetCursorImage"); return orgSetCursorImage(that, img); }
static IOReturn patchedSetCursorState(void *that, int32_t x, int32_t y, bool vis) { ONCE("SetCursorState"); return orgSetCursorState(that, x, y, vis); }
static IOReturn patchedDoI2CRequest(void *that, uint32_t bus, IOI2CBusTiming *t, IOI2CRequest *r) { ONCE("DoI2CRequest"); return orgDoI2CRequest(that, bus, t, r); }

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
    IOLog("QDP: onKextLoad id=%lu — installing %d routes\n", (unsigned long)id, 0);

    // Mangled-name guesses below. After deploy, Lilu will log per-route resolution.
    // Failures here mean the symbol either doesn't exist on IONDRVFramebuffer
    // (inherited from IOFramebuffer without override → different mangled prefix)
    // or the parameter mangling needs adjustment. Iterate.
    KernelPatcher::RouteRequest reqs[] = {
        // IOService overrides
        {"__ZN17IONDRVFramebuffer5probeEP9IOServicePi",                         patchedProbe,                          orgProbe},
        {"__ZN17IONDRVFramebuffer5startEP9IOService",                           patchedStart,                          orgStart},
        {"__ZN17IONDRVFramebuffer4stopEP9IOService",                            patchedStop,                           orgStop},
        {"__ZN17IONDRVFramebuffer4freeEv",                                      patchedFree,                           orgFree},
        {"__ZN17IONDRVFramebuffer13setPropertiesEP8OSObject",                   patchedSetProperties,                  orgSetProperties},

        // Power-mgmt
        {"__ZN17IONDRVFramebuffer25maxCapabilityForDomainStateEm",              patchedMaxCapabilityForDomainState,    orgMaxCapabilityForDomainState},
        {"__ZN17IONDRVFramebuffer31initialPowerStateForDomainStateEm",          patchedInitialPowerStateForDomainState, orgInitialPowerStateForDomainState},
        {"__ZN17IONDRVFramebuffer24powerStateForDomainStateEm",                 patchedPowerStateForDomainState,       orgPowerStateForDomainState},

        // IOFramebuffer
        {"__ZN17IONDRVFramebuffer12requestProbeEj",                             patchedRequestProbe,                   orgRequestProbe},
        {"__ZN17IONDRVFramebuffer16enableControllerEv",                         patchedEnableController,               orgEnableController},
        {"__ZN17IONDRVFramebuffer16getApertureRangeE15IOPixelAperture",         patchedGetApertureRange,               orgGetApertureRange},
        {"__ZN17IONDRVFramebuffer12getVRAMRangeEv",                             patchedGetVRAMRange,                   orgGetVRAMRange},
        {"__ZN17IONDRVFramebuffer15isConsoleDeviceEv",                          patchedIsConsoleDevice,                orgIsConsoleDevice},
        {"__ZN17IONDRVFramebuffer15getPixelFormatsEv",                          patchedGetPixelFormats,                orgGetPixelFormats},
        {"__ZN17IONDRVFramebuffer19getDisplayModeCountEv",                      patchedGetDisplayModeCount,            orgGetDisplayModeCount},
        {"__ZN17IONDRVFramebuffer15getDisplayModesEPi",                         patchedGetDisplayModes,                orgGetDisplayModes},
        {"__ZN17IONDRVFramebuffer28getInformationForDisplayModeEiP24IODisplayModeInformation", patchedGetInformationForDisplayMode, orgGetInformationForDisplayMode},
        {"__ZN17IONDRVFramebuffer29getPixelFormatsForDisplayModeEii",           patchedGetPixelFormatsForDisplayMode,  orgGetPixelFormatsForDisplayMode},
        {"__ZN17IONDRVFramebuffer19getPixelInformationEiiiP18IOPixelInformation", patchedGetPixelInformation,          orgGetPixelInformation},
        {"__ZN17IONDRVFramebuffer20setupForCurrentConfigEv",                    patchedSetupForCurrentConfig,          orgSetupForCurrentConfig},
        {"__ZN17IONDRVFramebuffer21getCurrentDisplayModeEPiS0_",                patchedGetCurrentDisplayMode,          orgGetCurrentDisplayMode},
        {"__ZN17IONDRVFramebuffer14setDisplayModeEii",                          patchedSetDisplayMode,                 orgSetDisplayMode},
        {"__ZN17IONDRVFramebuffer18setApertureEnableE15IOPixelAperturej",       patchedSetApertureEnable,              orgSetApertureEnable},
        {"__ZN17IONDRVFramebuffer21setStartupDisplayModeEii",                   patchedSetStartupDisplayMode,          orgSetStartupDisplayMode},
        {"__ZN17IONDRVFramebuffer21getStartupDisplayModeEPiS0_",                patchedGetStartupDisplayMode,          orgGetStartupDisplayMode},
        {"__ZN17IONDRVFramebuffer18setCLUTWithEntriesEP12IOColorEntryjjj",      patchedSetCLUTWithEntries,             orgSetCLUTWithEntries},
        {"__ZN17IONDRVFramebuffer13setGammaTableEjjjPv",                        patchedSetGammaTable,                  orgSetGammaTable},
        {"__ZN17IONDRVFramebuffer27getTimingInfoForDisplayModeEiP19IOTimingInformation", patchedGetTimingInfoForDisplayMode, orgGetTimingInfoForDisplayMode},
        {"__ZN17IONDRVFramebuffer22validateDetailedTimingEPvy",                 patchedValidateDetailedTiming,         orgValidateDetailedTiming},
        {"__ZN17IONDRVFramebuffer18setDetailedTimingsEP7OSArray",               patchedSetDetailedTimings,             orgSetDetailedTimings},
        {"__ZN17IONDRVFramebuffer12setAttributeEjm",                            patchedSetAttribute,                   orgSetAttribute},
        {"__ZN17IONDRVFramebuffer12getAttributeEjPm",                           patchedGetAttribute,                   orgGetAttribute},
        {"__ZN17IONDRVFramebuffer18getConnectionCountEv",                       patchedGetConnectionCount,             orgGetConnectionCount},
        {"__ZN17IONDRVFramebuffer25getAttributeForConnectionEijPm",             patchedGetAttributeForConnection,      orgGetAttributeForConnection},
        {"__ZN17IONDRVFramebuffer25setAttributeForConnectionEijm",              patchedSetAttributeForConnection,      orgSetAttributeForConnection},
        {"__ZN17IONDRVFramebuffer13getAppleSenseEiPjS0_S0_S0_",                 patchedGetAppleSense,                  orgGetAppleSense},
        {"__ZN17IONDRVFramebuffer12connectFlagsEiiPj",                          patchedConnectFlags,                   orgConnectFlags},
        {"__ZN17IONDRVFramebuffer13hasDDCConnectEi",                            patchedHasDDCConnect,                  orgHasDDCConnect},
        {"__ZN17IONDRVFramebuffer11getDDCBlockEijjjPhPy",                       patchedGetDDCBlock,                    orgGetDDCBlock},
        {"__ZN17IONDRVFramebuffer19unregisterInterruptEPv",                     patchedUnregisterInterrupt,            orgUnregisterInterrupt},
        {"__ZN17IONDRVFramebuffer17setInterruptStateEPvj",                      patchedSetInterruptState,              orgSetInterruptState},
        {"__ZN17IONDRVFramebuffer14setCursorImageEPv",                          patchedSetCursorImage,                 orgSetCursorImage},
        {"__ZN17IONDRVFramebuffer14setCursorStateEiib",                         patchedSetCursorState,                 orgSetCursorState},
        {"__ZN17IONDRVFramebuffer12doI2CRequestEjP14IOI2CBusTimingP12IOI2CRequest", patchedDoI2CRequest,               orgDoI2CRequest},
    };
    patcher.routeMultiple(id, reqs, arrsize(reqs), slide, size);

    if (patcher.getError() == KernelPatcher::Error::NoError)
        IOLog("QDP: %lu/%lu routed (passthrough)\n", arrsize(reqs), arrsize(reqs));
    else {
        IOLog("QDP: routeMultiple err %d (some symbols may not exist — check Lilu mach: log)\n", patcher.getError());
        patcher.clearError();
    }
}

void pluginStart() {
    IOLog("QDP: pluginStart (full passthrough surface — first-call logging)\n");
    lilu.onKextLoadForce(&kextInfo, 1, onKextLoad);
}
