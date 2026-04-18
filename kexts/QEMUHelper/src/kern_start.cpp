#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <mach/mach_types.h>
#include <mach/task.h>
#include <sys/proc.h>

// Private kernel API — resolved at link time against the kernel
extern "C" task_t proc_task(proc_t proc);

// Processes to raise jetsam limits for (name, limit in MB)
static struct { const char *name; int limitMB; } jetsam_overrides[] = {
    {"WallpaperAgent",      128},
    {"wallpaperexportd",     64},
    {"BiomeAgent",           64},
    {"PerfPowerService",     64},  // truncated to 16 chars by kernel
    {"WallpaperVideoEx",    128},  // WallpaperVideoExtension
    {nullptr, 0}
};

// iMac 27" Retina display EDID — Apple vendor, 1920x1080@60Hz, P3 color
static const uint8_t iMacEDID[] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x06, 0x10, 0x34, 0xA0, 0x00, 0x00, 0x00, 0x00,
    0x30, 0x1E, 0x01, 0x04, 0xB5, 0x3C, 0x22, 0x78, 0x3A, 0xD6, 0x65, 0xA6, 0x56, 0x51, 0xA0, 0x26,
    0x0D, 0x50, 0x54, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C,
    0x45, 0x00, 0xC0, 0x58, 0x21, 0x00, 0x00, 0x1E, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x69, 0x4D, 0x61,
    0x63, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xFD, 0x00, 0x30,
    0x3E, 0x1E, 0x64, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68,
};

static IOService *gFramebuffer = nullptr;

class QEMUHelper : public IOService {
    OSDeclareDefaultStructors(QEMUHelper)

    IOTimerEventSource *timer;
    IOWorkLoop *workLoop;
    int patchAttempts;

    // Set EDID on the framebuffer so AppleDisplay reads it
    static void patchEDID(IOService *fb) {
        OSData *edidData = OSData::withBytes(iMacEDID, sizeof(iMacEDID));
        if (edidData) {
            fb->setProperty("IODisplayEDID", edidData);
            fb->setProperty("IODisplayEDIDOriginal", edidData);
            edidData->release();
        }
        // Also set vendor/product directly on framebuffer
        OSNumber *vendorID = OSNumber::withNumber((uint32_t)0x610, 32);
        OSNumber *productID = OSNumber::withNumber((uint32_t)0xA034, 32);
        if (vendorID) { fb->setProperty("DisplayVendorID", vendorID); vendorID->release(); }
        if (productID) { fb->setProperty("DisplayProductID", productID); productID->release(); }
    }

    static void patchVRAM(IOService *fb) {
        OSNumber *vramSize = OSNumber::withNumber((uint64_t)268435456, 64);
        if (vramSize) {
            fb->setProperty("IOFBMemorySize", vramSize);
            vramSize->release();
        }
    }

public:
    // Catch IODisplayConnect BEFORE AppleDisplay matches — inject EDID
    static bool displayConnectMatched(void *target, void *refCon, IOService *newService, IONotifier *notifier) {
        IOLog("QEMUHelper: IODisplayConnect appeared, injecting EDID\n");
        // Get the parent framebuffer
        IOService *fb = newService->getProvider();
        if (fb) {
            patchEDID(fb);
            IOLog("QEMUHelper: EDID injected on framebuffer\n");
        }
        // Also set on the connect itself
        OSData *edidData = OSData::withBytes(iMacEDID, sizeof(iMacEDID));
        if (edidData) {
            newService->setProperty("IODisplayEDID", edidData);
            edidData->release();
        }
        return true;
    }

    // Catch framebuffer for VRAM patching (delayed)
    static bool framebufferMatched(void *target, void *refCon, IOService *newService, IONotifier *notifier) {
        IOLog("QEMUHelper: framebuffer appeared\n");
        newService->retain();
        gFramebuffer = newService;
        patchEDID(newService); // Set EDID early too
        QEMUHelper *self = (QEMUHelper *)target;
        if (self->timer) {
            self->timer->setTimeoutMS(5000);
        }
        return true;
    }

    static void raiseJetsamLimits() {
        IOLog("QEMUHelper: scanning processes for jetsam limits...\n");
        char name[256];
        bzero(name, sizeof(name));
        int found = 0;
        for (pid_t pid = 1; pid < 2000; pid++) {
            proc_t p = proc_find(pid);
            if (!p) continue;
            proc_name(pid, name, sizeof(name));
            for (int i = 0; jetsam_overrides[i].name; i++) {
                if (strncmp(name, jetsam_overrides[i].name, strlen(jetsam_overrides[i].name)) == 0) {
                    found++;
                    task_t task = proc_task(p);
                    if (task) {
                        int old_limit = 0;
                        kern_return_t kr = task_set_phys_footprint_limit(task, jetsam_overrides[i].limitMB, &old_limit);
                        IOLog("QEMUHelper: %s (pid %d) limit %d -> %d MB (kr=%d)\n",
                              name, pid, old_limit, jetsam_overrides[i].limitMB, kr);
                    } else {
                        IOLog("QEMUHelper: %s (pid %d) — proc_task returned null\n", name, pid);
                    }
                }
            }
            proc_rele(p);
        }
        IOLog("QEMUHelper: jetsam scan done, %d processes found\n", found);
    }

    static void timerFired(OSObject *owner, IOTimerEventSource *sender) {
        if (!gFramebuffer) return;
        QEMUHelper *self = (QEMUHelper *)owner;
        self->patchAttempts++;

        patchVRAM(gFramebuffer);
        patchEDID(gFramebuffer);

        // Raise jetsam limits on attempts 2 and 4 (15s and 35s after boot)
        if (self->patchAttempts == 2 || self->patchAttempts == 4) {
            raiseJetsamLimits();
        }

        IOLog("QEMUHelper: patched (attempt %d)\n", self->patchAttempts);

        if (self->patchAttempts < 5) {
            sender->setTimeoutMS(10000);
        } else {
            IOLog("QEMUHelper: complete\n");
        }
    }

    bool start(IOService *provider) override {
        IOLog("QEMUHelper::start\n");
        if (!IOService::start(provider)) return false;

        patchAttempts = 0;
        workLoop = getWorkLoop();
        if (workLoop) {
            timer = IOTimerEventSource::timerEventSource(this, timerFired);
            if (timer) workLoop->addEventSource(timer);
        }

        // Watch for framebuffer (VRAM patch)
        OSDictionary *fbMatch = IOService::serviceMatching("IOFramebuffer");
        if (fbMatch) {
            addMatchingNotification(gIOPublishNotification, fbMatch,
                &QEMUHelper::framebufferMatched, this);
        }

        // Watch for display connect (EDID injection — before AppleDisplay)
        OSDictionary *dcMatch = IOService::serviceMatching("IODisplayConnect");
        if (dcMatch) {
            addMatchingNotification(gIOFirstMatchNotification, dcMatch,
                &QEMUHelper::displayConnectMatched, this);
        }

        IOLog("QEMUHelper: watching for framebuffer + display connect\n");
        return true;
    }

    void stop(IOService *provider) override {
        if (timer) {
            timer->cancelTimeout();
            if (workLoop) workLoop->removeEventSource(timer);
            timer->release();
            timer = nullptr;
        }
        if (gFramebuffer) { gFramebuffer->release(); gFramebuffer = nullptr; }
        IOService::stop(provider);
    }
};

OSDefineMetaClassAndStructors(QEMUHelper, IOService)
