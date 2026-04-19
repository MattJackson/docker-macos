#include <mach/mach_types.h>

extern kern_return_t qdp_start(kmod_info_t *ki, void *d);
extern kern_return_t qdp_stop(kmod_info_t *ki, void *d);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL(com.docker-macos.driver.QEMUDisplayPatcher, "1.0.0", qdp_start, qdp_stop)
__attribute__((used, section("__DATA,__kmod_info")));
