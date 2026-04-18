#include <mach/mach_types.h>

extern kern_return_t QEMUDisplayPatcher_kern_start(kmod_info_t *ki, void *d);
extern kern_return_t QEMUDisplayPatcher_kern_stop(kmod_info_t *ki, void *d);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL(com.docker-macos.driver.QEMUDisplayPatcher, "1.0.0", QEMUDisplayPatcher_kern_start, QEMUDisplayPatcher_kern_stop)
__attribute__((used, section("__DATA,__kmod_info")));
