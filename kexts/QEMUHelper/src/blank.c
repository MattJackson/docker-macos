#include <mach/mach_types.h>

kern_return_t QEMUHelper_start(kmod_info_t *ki, void *data) {
    return KERN_SUCCESS;
}

kern_return_t QEMUHelper_stop(kmod_info_t *ki, void *data) {
    return KERN_SUCCESS;
}

kmod_info_t KMOD_INFO_NAME = {
    .next = 0,
    .info_version = KMOD_INFO_VERSION,
    .id = 0,
    .name = "com.docker-macos.kext.QEMUHelper",
    .version = "1.0.0",
    .reference_count = 0,
    .reference_list = 0,
    .address = 0,
    .size = 0,
    .hdr_size = 0,
    .start = (kmod_start_func_t *)QEMUHelper_start,
    .stop = (kmod_stop_func_t *)QEMUHelper_stop
};
kmod_start_func_t *_realmain = 0;
kmod_stop_func_t *_antimain = 0;
int _kext_apple_cc = 0;
