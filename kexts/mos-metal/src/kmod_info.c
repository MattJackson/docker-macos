#include <mach/mach_types.h>

extern kern_return_t mos_metal_start(kmod_info_t *ki, void *d);
extern kern_return_t mos_metal_stop(kmod_info_t *ki, void *d);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL(com.docker-macos.kext.mosMetal, "0.1.0", mos_metal_start, mos_metal_stop)
__attribute__((used, section("__DATA,__kmod_info")));
