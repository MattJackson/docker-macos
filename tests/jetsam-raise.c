/*
 * jetsam-raise.c — raise per-process jetsam memory limits for macOS
 * processes that do heavy work when GPU acceleration is unavailable.
 *
 * Why: our VM has no GPU accelerator. WindowServer, Dock, dynamic-wallpaper
 * agent, etc. have to CPU-composite UI at 4K. That uses way more RAM than
 * the default per-process jetsam limits (~30-128 MB) allow. When the limit
 * hits they're throttled or killed → dynamic wallpapers white / UI stalls.
 *
 * What: polls running processes every 5 seconds. For target process names,
 * calls memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, ...)
 * to raise their active + inactive memory limits to 1024 MB.
 *
 * Runs as a LaunchDaemon at boot (root). memorystatus_control isn't a public
 * API but is callable via direct syscall #440 with root.
 *
 * Build (on host Mac, cross-compile for target):
 *   clang -arch x86_64 -mmacosx-version-min=10.15 -O2 jetsam-raise.c -o jetsam-raise
 *
 * Install (on VM):
 *   sudo cp jetsam-raise /usr/local/bin/
 *   sudo cp com.pq.jetsam-raise.plist /Library/LaunchDaemons/
 *   sudo launchctl load -w /Library/LaunchDaemons/com.pq.jetsam-raise.plist
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <libproc.h>
#include <sys/syscall.h>

#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES   7   /* legacy */
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES2  8   /* Big Sur+ */

typedef struct memorystatus_memlimit_properties {
    int32_t  memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t  memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

static int memorystatus_control(uint32_t cmd, int32_t pid, uint32_t flags,
                                void *buffer, size_t buffersize) {
    return (int)syscall(SYS_memorystatus_control, cmd, pid, flags, buffer, buffersize);
}

/* Target processes — name must match the kernel's p_comm (16 chars max).
 * Limit is MB. 1024 MB gives software-compositing at 4K real headroom. */
struct target {
    const char *name;
    int32_t     limit_mb;
};

static const struct target gTargets[] = {
    { "WindowServer",        1024 },   /* compositor — heaviest */
    { "wallpaperexportd",     512 },   /* dynamic wallpaper renderer */
    { "Dock",                 512 },   /* menu bar / app switcher */
    { "Finder",               512 },   /* UI */
    { "SystemUIServer",       256 },   /* menu bar items */
    { "ControlCenter",        256 },
    { "NotificationCenter",   256 },
    { "Spotlight",            256 },
    { "cfprefsd",             256 },   /* hit when many apps read prefs */
    { "loginwindow",          256 },   /* first-login RAM spikes */
    { "coreaudiod",           256 },
    { "coreduetd",            256 },
    { "assistantd",           256 },
    { "mdworker_shared",      512 },   /* Spotlight indexing */
    { NULL, 0 },
};

static int seen_pids[4096];
static int seen_count = 0;

static int is_seen(int pid) {
    for (int i = 0; i < seen_count; i++) if (seen_pids[i] == pid) return 1;
    if (seen_count < (int)(sizeof(seen_pids) / sizeof(seen_pids[0])))
        seen_pids[seen_count++] = pid;
    return 0;
}

static const struct target *match_target(const char *name) {
    for (int i = 0; gTargets[i].name; i++) {
        if (strcmp(gTargets[i].name, name) == 0) return &gTargets[i];
    }
    return NULL;
}

static void raise_process(int pid, const struct target *t) {
    memorystatus_memlimit_properties_t props = {0};
    props.memlimit_active = t->limit_mb;
    props.memlimit_active_attr = 0;   /* non-fatal */
    props.memlimit_inactive = t->limit_mb;
    props.memlimit_inactive_attr = 0;

    /* Try the Big Sur+ command first, fall back to legacy. */
    int r = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES2,
                                 pid, 0, &props, sizeof(props));
    if (r < 0 && errno == EINVAL) {
        r = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                                 pid, 0, &props, sizeof(props));
    }

    if (r < 0) {
        fprintf(stderr, "jetsam-raise: pid %d (%s): FAILED %d %s\n",
                pid, t->name, errno, strerror(errno));
    } else {
        fprintf(stderr, "jetsam-raise: pid %d (%s) -> %d MB OK\n",
                pid, t->name, t->limit_mb);
    }
}

static void scan_once(void) {
    pid_t pids[8192];
    int n = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    if (n <= 0) return;
    int count = n / (int)sizeof(pid_t);

    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        if (is_seen(pid)) continue;

        char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_name(pid, name, sizeof(name)) <= 0) continue;

        const struct target *t = match_target(name);
        if (!t) continue;
        raise_process(pid, t);
    }
}

int main(int argc, char **argv) {
    setvbuf(stderr, NULL, _IOLBF, 0);
    fprintf(stderr, "jetsam-raise: starting, pid=%d\n", getpid());

    for (;;) {
        scan_once();
        sleep(5);
    }
    return 0;
}
