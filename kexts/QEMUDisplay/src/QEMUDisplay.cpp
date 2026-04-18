#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "QEMUDisplay.hpp"
#include <IOKit/IOLib.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <architecture/i386/pio.h>

#define LOG(fmt, ...) IOLog("QEMUDisplay: " fmt "\n", ##__VA_ARGS__)

// EDID for iMac 27" display — 128 bytes, checksum valid
static const uint8_t mos15_edid[128] = {
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x06, 0x10, 0xc3, 0x9c, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x22, 0x01, 0x03, 0x80, 0x3c, 0x22, 0x78, 0x0a, 0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26,
    0x0f, 0x50, 0x54, 0x21, 0x08, 0x00, 0xd1, 0xc0, 0x81, 0xc0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c,
    0x45, 0x00, 0x06, 0x44, 0x21, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0xfc, 0x00, 0x69, 0x4d, 0x61,
    0x63, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xfd, 0x00, 0x38,
    0x4c, 0x1e, 0x51, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    0x00, 0x4d, 0x4f, 0x53, 0x31, 0x35, 0x56, 0x4d, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x71,
};

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
    connectProc = nullptr;
    connectTarget = nullptr;
    connectRef = nullptr;
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

    // Read hardware info but DON'T enable SVGA mode.
    // SVGA mode requires FIFO UPDATE commands for VNC display refresh.
    // VGA mode auto-updates the display from VRAM — VNC works automatically.
    // WindowServer writes pixels to VRAM (BAR1), VGA displays them.

    // Set VRAM property for system_profiler
    OSNumber *vram = OSNumber::withNumber((uint64_t)vramSize, 64);
    if (vram) {
        setProperty("IOFBMemorySize", vram);
        vram->release();
    }

    // Tell IOFramebuffer this is a framebuffer-only device (no vsync needed)
    setProperty("IOFB0Hz", kOSBooleanTrue);

    // Gamma table support — WindowServer requires this for display setup
    setProperty("IOFBGammaCount", (uint64_t)256, 32);
    setProperty("IOFBGammaWidth", (uint64_t)8, 32);

    if (!super::start(provider)) {
        LOG("super::start failed");
        return false;
    }

    // Signal that a display is connected and online
    setProperty("IOFBConnectChange", kOSBooleanTrue);

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

IOReturn QEMUDisplay::setPowerState(unsigned long powerStateOrdinal, IOService *device) {
    LOG("setPowerState %lu", powerStateOrdinal);
    return IOPMAckImplied;
}

// Write a key to the Apple SMC via port I/O
// SMC protocol: CMD port 0x304, DATA port 0x300, ERR port 0x31e
static void smcWriteKey(const char *key, uint8_t len, const uint8_t *data) {
    // Send WRITE command
    outb(0x304, 0x11);  // APPLESMC_WRITE_CMD
    for (int i = 0; i < 100; i++) { if (inb(0x304) & 0x04) break; IODelay(100); }

    // Send 4-byte key name
    for (int i = 0; i < 4; i++) {
        outb(0x300, key[i]);
        for (int j = 0; j < 100; j++) { if (inb(0x304) & 0x04) break; IODelay(100); }
    }

    // Send data length
    outb(0x300, len);
    for (int i = 0; i < 100; i++) { if (inb(0x304) & 0x04) break; IODelay(100); }

    // Send data bytes
    for (int i = 0; i < len; i++) {
        outb(0x300, data[i]);
        for (int j = 0; j < 100; j++) { if (!(inb(0x304) & 0x02) || (inb(0x304) & 0x04)) break; IODelay(100); }
    }
}

IOReturn QEMUDisplay::enableController() {
    LOG("enableController");

    // Tell SMC that GPU power is on — AGPM reads HE0N to manage display power
    uint8_t powerOn = 0x01;
    smcWriteKey("HE0N", 1, &powerOn);
    smcWriteKey("HE2N", 1, &powerOn);
    LOG("SMC GPU power keys set to enabled");

    // Set VRAM property
    IODeviceMemory *vramMem = pciDevice->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
    if (vramMem) {
        setProperty(kIOFBMemorySizeKey, (uint64_t)vramMem->getLength(), 64);
    }

    // Power management — 3 states matching IOFramebuffer expectations
    static IOPMPowerState powerStates[] = {
        {1, 0,                 0,           0,           0, 0, 0, 0, 0, 0, 0, 0},
        {1, 0,                 IOPMPowerOn, IOPMPowerOn, 0, 0, 0, 0, 0, 0, 0, 0},
        {1, IOPMDeviceUsable,  IOPMPowerOn, IOPMPowerOn, 0, 0, 0, 0, 0, 0, 0, 0}
    };
    PMinit();
    registerPowerDriver(this, powerStates, 3);
    changePowerStateTo(2);

    return kIOReturnSuccess;
}

IOReturn QEMUDisplay::getAttribute(IOSelect attribute, uintptr_t *value) {
    if (attribute == kIOHardwareCursorAttribute) {
        *value = 0; // No hardware cursor for now
        return kIOReturnSuccess;
    }
    return super::getAttribute(attribute, value);
}

IOReturn QEMUDisplay::getAttributeForConnection(IOIndex connectIndex, IOSelect attribute, uintptr_t *value) {
    switch (attribute) {
        case kConnectionEnable:
        case kConnectionCheckEnable:
            *value = 1;
            return kIOReturnSuccess;
        case kConnectionFlags:
            *value = 0;
            return kIOReturnSuccess;
        case kConnectionSupportsHLDDCSense:
        case kConnectionSupportsAppleSense:
            return kIOReturnUnsupported;
        default:
            return super::getAttributeForConnection(connectIndex, attribute, value);
    }
}

IOReturn QEMUDisplay::setAttributeForConnection(IOIndex connectIndex, IOSelect attribute, uintptr_t value) {
    // Accept all connection attribute sets — IOFramebuffer sends these during connect processing
    return kIOReturnSuccess;
}

IODeviceMemory *QEMUDisplay::getVRAMRange() {
    // BAR1 = framebuffer memory
    return pciDevice->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
}

IODeviceMemory *QEMUDisplay::getApertureRange(IOPixelAperture aperture) {
    if (aperture != kIOFBSystemAperture) return nullptr;
    // Return a sub-range matching the current mode's framebuffer size
    IODeviceMemory *vram = pciDevice->getDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
    if (!vram) return nullptr;
    IOByteCount fbSize = (IOByteCount)currentWidth * currentHeight * 4;
    IODeviceMemory *sub = IODeviceMemory::withSubRange(vram, 0, fbSize);
    return sub;
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
            // Don't write SVGA registers — stay in VGA mode for auto-display
            LOG("mode set to %ux%u (VGA mode)", currentWidth, currentHeight);
            return kIOReturnSuccess;
        }
    }
    return kIOReturnBadArgument;
}

UInt64 QEMUDisplay::getPixelFormatsForDisplayMode(IODisplayModeID mode, IOIndex depth) {
    return 0;
}

IOReturn QEMUDisplay::registerForInterruptType(IOSelect interruptType, IOFBInterruptProc proc,
    OSObject *target, void *ref, void **interruptRef) {
    LOG("registerForInterruptType %u", (unsigned)interruptType);
    *interruptRef = (void *)(uintptr_t)(interruptType + 1);

    // Save the connect interrupt callback so we can fire it to signal "display connected"
    if (interruptType == kIOFBConnectInterruptType) {
        connectProc = proc;
        connectTarget = target;
        connectRef = ref;
        LOG("connect interrupt registered — will fire after open");
    }

    return kIOReturnSuccess;
}

IOReturn QEMUDisplay::unregisterInterrupt(void *interruptRef) {
    return kIOReturnSuccess;
}

IOReturn QEMUDisplay::setInterruptState(void *interruptRef, UInt32 state) {
    return kIOReturnSuccess;
}

IOReturn QEMUDisplay::setGammaTable(UInt32 channelCount, UInt32 dataCount, UInt32 dataWidth, void *data) {
    // Accept gamma table — we don't have hardware gamma but WindowServer/AppleDisplay
    // requires this to succeed for the display to fully power on (ChildrenPowerState → 2)
    return kIOReturnSuccess;
}

bool QEMUDisplay::hasDDCConnect(IOIndex connectIndex) {
    return true;  // We provide EDID
}

IOReturn QEMUDisplay::getDDCBlock(IOIndex connectIndex, UInt32 blockNumber,
    IOSelect blockType, IOOptionBits options, UInt8 *data, IOByteCount *length) {
    if (blockNumber != 1 || data == NULL || length == NULL) {
        return kIOReturnBadArgument;
    }
    IOByteCount copyLen = (*length < 128) ? *length : 128;
    memcpy(data, mos15_edid, copyLen);
    *length = copyLen;
    LOG("getDDCBlock: returned %u bytes of EDID", (unsigned)copyLen);
    return kIOReturnSuccess;
}

IOReturn QEMUDisplay::getTimingInfoForDisplayMode(IODisplayModeID mode, IOTimingInformation *info) {
    bzero(info, sizeof(*info));
    for (int i = 0; i < numModes; i++) {
        if (modes[i].id == mode) {
            info->appleTimingID = (IOAppleTimingID)0xFFFFFFFF; /* operator-defined */
            info->flags = kIODetailedTimingValid;
            info->detailedInfo.v2.horizontalActive = modes[i].width;
            info->detailedInfo.v2.verticalActive = modes[i].height;
            info->detailedInfo.v2.pixelClock = (uint64_t)modes[i].width * modes[i].height * 60;
            return kIOReturnSuccess;
        }
    }
    return kIOReturnBadArgument;
}

IOItemCount QEMUDisplay::getConnectionCount() {
    return 1;
}

#pragma clang diagnostic pop
