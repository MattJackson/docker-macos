#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>

#define MODULE_SHORT "qemuhelp"

static const char *kextIONDRVPath[] = {"/System/Library/Extensions/IONDRVSupport.kext/IONDRVSupport"};

static KernelPatcher::KextInfo kextList[] = {
    {"com.apple.iokit.IONDRVSupport", kextIONDRVPath, arrsize(kextIONDRVPath), {true}, {}, KernelPatcher::KextInfo::Unloaded}
};

static void processKext(void *user, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
    if (kextList[0].loadIndex != index) return;

    SYSLOG(MODULE_SHORT, "IONDRVSupport loaded, patching VRAM");

    // Search for 0x700000 (7MB) as mov immediate and replace with 0x10000000 (256MB)
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
