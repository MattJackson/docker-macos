#pragma once

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include <IOKit/graphics/IOFramebuffer.h>
#include <IOKit/pci/IOPCIDevice.h>

// VMware SVGA II registers
enum SVGARegister : uint32_t {
    SVGA_REG_ID              = 0,
    SVGA_REG_ENABLE          = 1,
    SVGA_REG_WIDTH           = 2,
    SVGA_REG_HEIGHT          = 3,
    SVGA_REG_MAX_WIDTH       = 4,
    SVGA_REG_MAX_HEIGHT      = 5,
    SVGA_REG_DEPTH           = 6,
    SVGA_REG_BITS_PER_PIXEL  = 7,
    SVGA_REG_PSEUDOCOLOR     = 8,
    SVGA_REG_RED_MASK        = 9,
    SVGA_REG_GREEN_MASK      = 10,
    SVGA_REG_BLUE_MASK       = 11,
    SVGA_REG_BYTES_PER_LINE  = 12,
    SVGA_REG_FB_START        = 13,
    SVGA_REG_FB_OFFSET       = 14,
    SVGA_REG_VRAM_SIZE       = 15,
    SVGA_REG_FB_SIZE         = 16,
    SVGA_REG_CAPABILITIES    = 17,
    SVGA_REG_CONFIG_DONE     = 20,
};

class QEMUDisplay : public IOFramebuffer {
    OSDeclareDefaultStructors(QEMUDisplay)

public:
    // IOService
    bool init(OSDictionary *dict = nullptr) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    // IOFramebuffer — required
    IOReturn getAttribute(IOSelect attribute, uintptr_t *value) override;
    IOReturn getAttributeForConnection(IOIndex connectIndex, IOSelect attribute, uintptr_t *value) override;
    IODeviceMemory *getVRAMRange() override;
    IODeviceMemory *getApertureRange(IOPixelAperture aperture) override;
    const char *getPixelFormats() override;
    IOItemCount getDisplayModeCount() override;
    IOReturn getDisplayModes(IODisplayModeID *allDisplayModes) override;
    IOReturn getInformationForDisplayMode(IODisplayModeID mode, IODisplayModeInformation *info) override;
    IOReturn getPixelInformation(IODisplayModeID mode, IOIndex depth, IOPixelAperture ap, IOPixelInformation *info) override;
    IOReturn getCurrentDisplayMode(IODisplayModeID *mode, IOIndex *depth) override;
    IOReturn setDisplayMode(IODisplayModeID mode, IOIndex depth) override;
    UInt64 getPixelFormatsForDisplayMode(IODisplayModeID mode, IOIndex depth) override;
    bool hasDDCConnect(IOIndex connectIndex) override;
    IOReturn getTimingInfoForDisplayMode(IODisplayModeID mode, IOTimingInformation *info) override;
    IOItemCount getConnectionCount() override;

private:
    IOPCIDevice *pciDevice;
    IOMemoryMap *ioMap;
    uint16_t ioPort;  /* BAR0 I/O port base address */
    uint32_t vramSize;
    uint32_t maxWidth;
    uint32_t maxHeight;
    uint32_t currentWidth;
    uint32_t currentHeight;

    uint32_t readReg(SVGARegister reg);
    void writeReg(SVGARegister reg, uint32_t val);
    void initDevice();
};

#pragma clang diagnostic pop
