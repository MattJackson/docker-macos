#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <mach/mach_types.h>

class QEMUHelper : public IOService {
    OSDeclareDefaultStructors(QEMUHelper)
public:
    static bool framebufferMatched(void *target, void *refCon, IOService *newService, IONotifier *notifier) {
        IOLog("QEMUHelper: framebuffer appeared! class=%s\n", newService->getMetaClass()->getClassName());
        OSNumber *vramSize = OSNumber::withNumber((uint64_t)268435456, 64);
        if (vramSize) {
            newService->setProperty("IOFBMemorySize", vramSize);
            vramSize->release();
            IOLog("QEMUHelper: IOFBMemorySize set to 256MB!\n");
        }
        return true;
    }

    bool start(IOService *provider) override {
        IOLog("QEMUHelper::start called!\n");
        if (!IOService::start(provider)) return false;

        // Register notification for when IONDRVFramebuffer appears
        IOLog("QEMUHelper: registering notification for IOFramebuffer\n");
        OSDictionary *matching = IOService::serviceMatching("IOFramebuffer");
        if (matching) {
            IONotifier *notifier = addMatchingNotification(
                gIOFirstMatchNotification,
                matching,
                &QEMUHelper::framebufferMatched,
                this);
            if (notifier) {
                IOLog("QEMUHelper: notification registered, waiting for framebuffer...\n");
            } else {
                IOLog("QEMUHelper: failed to register notification\n");
            }
        }
        return true;
    }
    void stop(IOService *provider) override {
        IOLog("QEMUHelper::stop called\n");
        IOService::stop(provider);
    }
};

OSDefineMetaClassAndStructors(QEMUHelper, IOService)
