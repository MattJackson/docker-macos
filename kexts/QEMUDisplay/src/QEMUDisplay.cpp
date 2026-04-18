#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "QEMUDisplay.hpp"
#include <IOKit/IOLib.h>

#define LOG(fmt, ...) IOLog("QEMUDisplay: " fmt "\n", ##__VA_ARGS__)

#define super IOFramebuffer
OSDefineMetaClassAndStructors(QEMUDisplay, IOFramebuffer)

// Display modes: common resolutions
struct ModeInfo {
    IODisplayModeID id;
    uint32_t width;
    uint32_t height;
    uint32_t refreshRate; // fixed-point 16.16
};

static const ModeInfo modes[] = {
    {1, 1920, 1080, 60 << 16},
    {2, 2560, 1440, 60 << 16},
    {3, 1280,  720, 60 << 16},
    {4, 1600,  900, 60 << 16},
    {5, 3840, 2160, 30 << 16},
};
static const int numModes = sizeof(modes) / sizeof(modes[0]);

// SVGA register access — port-mapped I/O (BAR0 is I/O space, not memory)
uint32_t QEMUDisplay::readReg(SVGARegister reg) {
    pciDevice->ioWrite32(ioPort + 0, reg);      // index port
    return pciDevice->ioRead32(ioPort + 1);      // value port
}

void QEMUDisplay::writeReg(SVGARegister reg, uint32_t val) {
    pciDevice->ioWrite32(ioPort + 0, reg);
    pciDevice->ioWrite32(ioPort + 1, val);
}

void QEMUDisplay::initDevice() {
    // Read capabilities
    vramSize  = readReg(SVGA_REG_VRAM_SIZE);
    maxWidth  = readReg(SVGA_REG_MAX_WIDTH);
    maxHeight = readReg(SVGA_REG_MAX_HEIGHT);

    // Default mode
    currentWidth  = 1920;
    currentHeight = 1080;

    LOG("VRAM=%uMB max=%ux%u", vramSize / (1024*1024), maxWidth, maxHeight);
}

// IOService

bool QEMUDisplay::init(OSDictionary *dict) {
    if (!super::init(dict)) return false;
    pciDevice = nullptr;
    ioMap = nullptr;
    ioPort = 0;
    return true;
}

bool QEMUDisplay::start(IOService *provider) {
    LOG("start");

    pciDevice = OSDynamicCast(IOPCIDevice, provider);
    if (!pciDevice) {
        LOG("provider is not IOPCIDevice");
        return false;
    }

    pciDevice->setMemoryEnable(true);
    pciDevice->setIOEnable(true);

    // BAR0 = I/O port space for SVGA register access
    // VMware SVGA uses port-mapped I/O, not memory-mapped I/O
    ioPort = (uint16_t)(pciDevice->configRead32(kIOPCIConfigBaseAddress0) & 0xFFFC);
    if (ioPort == 0) {
        LOG("failed to get BAR0 I/O port");
        return false;
    }
    LOG("BAR0 I/O port = 0x%x", ioPort);

    initDevice();

    // Set initial mode
    writeReg(SVGA_REG_WIDTH, currentWidth);
    writeReg(SVGA_REG_HEIGHT, currentHeight);
    writeReg(SVGA_REG_BITS_PER_PIXEL, 32);
    writeReg(SVGA_REG_ENABLE, 1);
    writeReg(SVGA_REG_CONFIG_DONE, 1);

    // Set VRAM property for system_profiler
    OSNumber *vram = OSNumber::withNumber((uint64_t)vramSize, 64);
    if (vram) {
        setProperty("IOFBMemorySize", vram);
        vram->release();
    }

    if (!super::start(provider)) {
        LOG("super::start failed");
        return false;
    }

    LOG("started — %ux%u, VRAM=%uMB", currentWidth, currentHeight, vramSize / (1024*1024));
    return true;
}

void QEMUDisplay::stop(IOService *provider) {
    LOG("stop");
    if (ioMap) { ioMap->release(); ioMap = nullptr; }
    super::stop(provider);
}

void QEMUDisplay::free() {
    super::free();
}

// IOFramebuffer

IOReturn QEMUDisplay::getAttribute(IOSelect attribute, uintptr_t *value) {
    if (attribute == kIOHardwareCursorAttribute) {
        *value = 0; // No hardware cursor for now
        return kIOReturnSuccess;
    }
    return super::getAttribute(attribute, value);
}

IOReturn QEMUDisplay::getAttributeForConnection(IOIndex connectIndex, IOSelect attribute, uintptr_t *value) {
    switch (attribute) {
        case kConnectionSupportsHLDDCSense:
        case kConnectionSupportsAppleSense:
            return kIOReturnUnsupported;
        default:
            return super::getAttributeForConnection(connectIndex, attribute, value);
    }
}

IODeviceMemory *QEMUDisplay::getVRAMRange() {
    // BAR1 = framebuffer memory
    return pciDevice->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
}

IODeviceMemory *QEMUDisplay::getApertureRange(IOPixelAperture aperture) {
    if (aperture != kIOFBSystemAperture) return nullptr;
    IODeviceMemory *mem = pciDevice->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
    if (mem) mem->retain();
    return mem;
}

const char *QEMUDisplay::getPixelFormats() {
    static const char fmts[] = IO32BitDirectPixels "\0";
    return fmts;
}

IOItemCount QEMUDisplay::getDisplayModeCount() {
    return numModes;
}

IOReturn QEMUDisplay::getDisplayModes(IODisplayModeID *allModes) {
    for (int i = 0; i < numModes; i++)
        allModes[i] = modes[i].id;
    return kIOReturnSuccess;
}

IOReturn QEMUDisplay::getInformationForDisplayMode(IODisplayModeID mode, IODisplayModeInformation *info) {
    for (int i = 0; i < numModes; i++) {
        if (modes[i].id == mode) {
            bzero(info, sizeof(*info));
            info->maxDepthIndex = 0;
            info->nominalWidth  = modes[i].width;
            info->nominalHeight = modes[i].height;
            info->refreshRate   = modes[i].refreshRate;
            return kIOReturnSuccess;
        }
    }
    return kIOReturnBadArgument;
}

IOReturn QEMUDisplay::getPixelInformation(IODisplayModeID mode, IOIndex depth, IOPixelAperture ap, IOPixelInformation *info) {
    if (depth != 0) return kIOReturnBadArgument;
    for (int i = 0; i < numModes; i++) {
        if (modes[i].id == mode) {
            bzero(info, sizeof(*info));
            info->bytesPerRow      = modes[i].width * 4;
            info->bitsPerPixel     = 32;
            info->pixelType        = kIORGBDirectPixels;
            info->componentCount   = 3;
            info->bitsPerComponent = 8;
            info->activeWidth      = modes[i].width;
            info->activeHeight     = modes[i].height;
            strlcpy(info->pixelFormat, IO32BitDirectPixels, sizeof(info->pixelFormat));
            return kIOReturnSuccess;
        }
    }
    return kIOReturnBadArgument;
}

IOReturn QEMUDisplay::getCurrentDisplayMode(IODisplayModeID *mode, IOIndex *depth) {
    *mode = 1; // Default to 1920x1080
    *depth = 0;
    return kIOReturnSuccess;
}

IOReturn QEMUDisplay::setDisplayMode(IODisplayModeID mode, IOIndex depth) {
    for (int i = 0; i < numModes; i++) {
        if (modes[i].id == mode) {
            currentWidth  = modes[i].width;
            currentHeight = modes[i].height;
            writeReg(SVGA_REG_WIDTH, currentWidth);
            writeReg(SVGA_REG_HEIGHT, currentHeight);
            writeReg(SVGA_REG_BITS_PER_PIXEL, 32);
            writeReg(SVGA_REG_ENABLE, 1);
            writeReg(SVGA_REG_CONFIG_DONE, 1);
            LOG("mode set to %ux%u", currentWidth, currentHeight);
            return kIOReturnSuccess;
        }
    }
    return kIOReturnBadArgument;
}

UInt64 QEMUDisplay::getPixelFormatsForDisplayMode(IODisplayModeID mode, IOIndex depth) {
    return 0;
}

bool QEMUDisplay::hasDDCConnect(IOIndex connectIndex) {
    return false;
}

IOReturn QEMUDisplay::getTimingInfoForDisplayMode(IODisplayModeID mode, IOTimingInformation *info) {
    info->appleTimingID = kIOTimingIDVESA_1920x1440_60hz; // Closest available
    info->flags = 0;
    return kIOReturnSuccess;
}

IOItemCount QEMUDisplay::getConnectionCount() {
    return 1;
}

#pragma clang diagnostic pop
