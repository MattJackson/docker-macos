#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <Headers/kern_util.hpp>

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>

#define MODULE_SHORT "qemuhelp"

// IOService class required by Lilu for plugin discovery
OSDefineMetaClassAndStructors(QEMUHelper, IOService)

bool ADDPR(startSuccess) = false;

IOService *QEMUHelper::probe(IOService *provider, SInt32 *score) {
    auto service = IOService::probe(provider, score);
    return ADDPR(startSuccess) ? service : nullptr;
}

bool QEMUHelper::start(IOService *provider) {
    if (!IOService::start(provider))
        return false;
    return ADDPR(startSuccess);
}

void QEMUHelper::stop(IOService *provider) {
    IOService::stop(provider);
}

// Lilu plugin logic
static const char *kextIONDRVPath[] = {"/System/Library/Extensions/IONDRVSupport.kext/IONDRVSupport"};

static KernelPatcher::KextInfo kextList[] = {
    {"com.apple.iokit.IONDRVSupport", kextIONDRVPath, arrsize(kextIONDRVPath), {true}, {}, KernelPatcher::KextInfo::Unloaded}
};

static void processKext(void *user, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
    if (kextList[0].loadIndex != index) return;

    SYSLOG(MODULE_SHORT, "IONDRVSupport loaded, patching VRAM");

    static const uint8_t find[] = {0x00, 0x00, 0x70, 0x00};
    static const uint8_t repl[] = {0x00, 0x00, 0x00, 0x10};

    KernelPatcher::LookupPatch vramPatch = {
        &kextList[0],
        find, repl,
        sizeof(find),
        0
    };

    patcher.applyLookupPatch(&vramPatch);
    if (patcher.getError() != KernelPatcher::Error::NoError) {
        SYSLOG(MODULE_SHORT, "VRAM patch failed: %d", patcher.getError());
        patcher.clearError();
    } else {
        SYSLOG(MODULE_SHORT, "VRAM patched: 7MB -> 256MB");
    }
}

static void pluginStart() {
    SYSLOG(MODULE_SHORT, "QEMUHelper starting");
    lilu.onKextLoadForce(kextList, 1, processKext);
}

static const char *bootargOff[] = {"-qemuhelperoff"};
static const char *bootargDebug[] = {"-qemuhelperdbg"};

PluginConfiguration ADDPR(config) {
    xStringify(PRODUCT_NAME),
    parseModuleVersion(xStringify(MODULE_VERSION)),
    LiluAPI::AllowNormal | LiluAPI::AllowInstallerRecovery | LiluAPI::AllowSafeMode,
    bootargOff, arrsize(bootargOff),
    bootargDebug, arrsize(bootargDebug),
    nullptr, 0,
    KernelVersion::Sequoia,
    KernelVersion::Sequoia,
    pluginStart
};
