#include <mach/mach_types.h>

extern kern_return_t mos15_metal_start(kmod_info_t *ki, void *d);
extern kern_return_t mos15_metal_stop(kmod_info_t *ki, void *d);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL(com.docker-macos.kext.mos15Metal, "0.1.0", mos15_metal_start, mos15_metal_stop)
__attribute__((used, section("__DATA,__kmod_info")));
