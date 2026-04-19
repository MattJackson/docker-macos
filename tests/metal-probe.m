// metal-probe.m — enumerate Metal devices macOS reports.
// Tells us whether any Metal device (even software) is registered.
//
// Build on host: clang -framework Foundation -framework Metal -framework CoreGraphics metal-probe.m -o metal-probe
// Run on VM   : sudo launchctl asuser 501 /tmp/metal-probe
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        printf("=== MTLCopyAllDevices ===\n");
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        printf("count: %lu\n", (unsigned long)devices.count);
        for (id<MTLDevice> d in devices) {
            printf("  name:       %s\n", [[d name] UTF8String]);
            printf("  registryID: 0x%llx\n", [d registryID]);
            printf("  lowPower:   %d\n", [d isLowPower]);
            printf("  headless:   %d\n", [d isHeadless]);
            printf("  removable:  %d\n", [d isRemovable]);
            if (@available(macOS 11.0, *)) {
                printf("  hasUnifiedMemory: %d\n", [d hasUnifiedMemory]);
            }
            printf("  maxBufferLen: %lu\n", (unsigned long)[d maxBufferLength]);
            printf("\n");
        }

        printf("=== MTLCreateSystemDefaultDevice ===\n");
        id<MTLDevice> def = MTLCreateSystemDefaultDevice();
        if (def) {
            printf("default name: %s\n", [[def name] UTF8String]);
        } else {
            printf("default: (null)\n");
        }

        printf("\n=== CGDirectDisplay Metal accelerated? ===\n");
        uint32_t count = 0;
        CGGetOnlineDisplayList(16, NULL, &count);
        CGDirectDisplayID ids[16];
        CGGetOnlineDisplayList(count, ids, &count);
        for (uint32_t i = 0; i < count; i++) {
            printf("display 0x%x\n", ids[i]);
            // Metal availability per display is not a direct API; indirect
            // via CGDirectDisplayCopyCurrentMetalDevice:
            if (@available(macOS 10.11, *)) {
                id<MTLDevice> dd = CGDirectDisplayCopyCurrentMetalDevice(ids[i]);
                printf("  metal-device for display: %s\n",
                       dd ? [[dd name] UTF8String] : "(null)");
            }
        }
    }
    return 0;
}
