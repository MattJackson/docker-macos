//
//  kern_start.cpp
//  QEMUDisplayPatcher
//
//  Lilu plugin that patches IONDRVFramebuffer to behave as QEMUDisplay.
//  Runs from Boot KC — no System KC dependency.
//

#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>

#include "qdp_patcher.hpp"

static const char *bootargOff[] { "-qdpoff" };
static const char *bootargDbg[] { "-qdpdbg" };
static const char *bootargBeta[] { "-qdpbeta" };

PluginConfiguration ADDPR(config) {
    xStringify(PRODUCT_NAME),
    parseModuleVersion(xStringify(MODULE_VERSION)),
    LiluAPI::AllowNormal | LiluAPI::AllowInstallerRecovery,
    bootargOff, arrsize(bootargOff),
    bootargDbg, arrsize(bootargDbg),
    bootargBeta, arrsize(bootargBeta),
    KernelVersion::Sequoia,   // min
    KernelVersion::Sequoia,   // max
    pluginStart
};
