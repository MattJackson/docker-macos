#!/bin/bash
set -eu

cd /opt/macos

# ---------------------------------------------------------------------------
# apple-gfx-pci gpu_cores plumbing.
#
# GPU_CORES env var controls the lavapipe worker-thread pool for the
# apple-gfx-pci display device.
#   unset / 0    -> emit "-device apple-gfx-pci" (lavapipe picks host core count)
#   1..          -> emit "-device apple-gfx-pci,gpu_cores=N"
#   non-numeric, negative, or "host" -> warn, fall back to unset behavior
#
# Spec: /Users/mjackson/mos/paravirt-re/gpu-cores-implementation-spec.md
# Curve: /Users/mjackson/mos/memory/project_tunable_gpu_cores.md
# ---------------------------------------------------------------------------
GPU_CORES_RAW="${GPU_CORES:-0}"
APPLE_GFX_DEVICE="-device apple-gfx-pci"
if [[ "${GPU_CORES_RAW}" =~ ^[0-9]+$ ]]; then
    if [ "${GPU_CORES_RAW}" -eq 0 ]; then
        echo "apple-gfx-pci: GPU_CORES=0 (unset) -> lavapipe uses host core count"
    else
        APPLE_GFX_DEVICE="-device apple-gfx-pci,gpu_cores=${GPU_CORES_RAW}"
        echo "apple-gfx-pci: GPU_CORES=${GPU_CORES_RAW} -> LP_NUM_THREADS=${GPU_CORES_RAW}"
    fi
else
    echo "apple-gfx-pci: WARN: GPU_CORES='${GPU_CORES_RAW}' is not a non-negative integer;" \
         "falling back to unset (lavapipe picks host core count)." \
         "'host' auto-detect is reserved for a future release." >&2
fi

# Fail fast if the QEMU build in this image doesn't know about apple-gfx-pci.
# (A missing device is the failure mode when someone runs an older Dockerfile
# build against a compose file that sets GPU_CORES.)
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '^name "apple-gfx-pci"'; then
    echo "launch.sh: ERROR: this QEMU build does not expose the apple-gfx-pci device." >&2
    echo "  Rebuild the container image from a Dockerfile that includes" >&2
    echo "  libapplegfx-vulkan + the qemu-mos15 apple-gfx-pci-linux.c patch." >&2
    echo "  See the Dockerfile builder stage; check the image build date." >&2
    exit 1
fi

# Reset NVRAM if requested (touch /data/.reset-nvram to trigger)
if [ -f /data/.reset-nvram ]; then
    echo "NVRAM reset requested"
    cp /usr/share/OVMF/OVMF_VARS.clean.fd /usr/share/OVMF/OVMF_VARS.fd
    rm -f /data/.reset-nvram
fi

# ---------------------------------------------------------------------------
# Boot diagnostics: serial log file + HMP/QMP monitor sockets.
#
# Why:
#   - Serial log: captures the QEMU guest's first serial line (OVMF + kernel
#     early prints when console=ttyS0 is asked for). Lands on a host-mounted
#     volume (see docker-compose.yml: ./logs:/data/logs) so the capture/analyze
#     scripts in tests/ can read it without docker-exec gymnastics.
#   - HMP monitor socket: human-readable QEMU monitor, exposed on a host-mounted
#     unix socket (./run:/data/run). An operator outside the container can run
#     `socat - unix:$(pwd)/run/qemu-monitor.sock` and issue commands like
#     `info qtree`, `screendump /data/logs/frame.ppm`, `quit`.
#   - QMP socket: structured JSON protocol, same semantics as HMP but scriptable.
#
# Log rotation policy:
#   Each boot writes a fresh timestamped serial log (append=off). No in-container
#   rotation daemon — operator is expected to prune /data/logs on the host. See
#   README.md "Logging" section for a sample `find ... -mtime +N -delete` line.
#   At ~1 line/ms during a kernel panic this can grow to ~100 MB/hour; size-cap
#   with host-level logrotate if you intend to leave a VM running for days.
#
# Spec: tests/capture-boot-log.sh (produced by the capture/analyze agent) reads
# /data/logs/serial-*.log via the bind-mount.
# ---------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/data/logs}"
RUN_DIR="${RUN_DIR:-/data/run}"
mkdir -p "${LOG_DIR}" "${RUN_DIR}"
BOOT_TS="$(date +%Y%m%d-%H%M%S)"
SERIAL_LOG="${LOG_DIR}/serial-${BOOT_TS}.log"
HMP_SOCK="${RUN_DIR}/qemu-monitor.sock"
QMP_SOCK="${RUN_DIR}/qemu-qmp.sock"
# Stale sockets from a previous boot block `server=on`; clear them.
rm -f "${HMP_SOCK}" "${QMP_SOCK}"
echo "Serial log:             ${SERIAL_LOG}"
echo "Monitor socket (HMP):   ${HMP_SOCK}"
echo "QMP socket:             ${QMP_SOCK}"
echo "  -> from host: socat - unix:\$(pwd)/run/qemu-monitor.sock"

# ---------------------------------------------------------------------------
# Install vs boot mode.
#
# Contract: IMAGE_PATH is a bind-mounted file on the host (see
# docker-compose.yml: ./volumes/disk.img:/image). It must be a regular file
# — if it's missing, a directory, or otherwise unusable we fail loudly
# rather than silently racing qemu-img against a bind-mount that docker
# already materialised as an empty directory (the classic footgun when the
# host path doesn't exist: docker creates a directory at the mount point).
#
# Install mode is triggered by an empty or tiny (<1 MiB) regular file. The
# operator creates `./volumes/disk.img` empty via setup.sh; launch.sh then
# qemu-img's it up to $DISK_SIZE on first boot and attaches the recovery
# image as InstallMedia.
# ---------------------------------------------------------------------------
INSTALL_MEDIA=""
if [ ! -e "${IMAGE_PATH}" ]; then
    echo "launch.sh: ERROR: IMAGE_PATH '${IMAGE_PATH}' does not exist." >&2
    echo "  Run ./setup.sh on the host to stage ./volumes/disk.img." >&2
    exit 1
fi
if [ -d "${IMAGE_PATH}" ]; then
    echo "launch.sh: ERROR: IMAGE_PATH '${IMAGE_PATH}' is a directory." >&2
    echo "  Docker created a directory at the bind-mount target because the" >&2
    echo "  host-side file does not exist. Remove it, then run ./setup.sh." >&2
    exit 1
fi
CURRENT_SIZE=$(stat -Lc%s "${IMAGE_PATH}" 2>/dev/null || echo 0)
if [ "${CURRENT_SIZE}" -lt 1048576 ]; then
    echo "Empty disk (${CURRENT_SIZE} bytes) -- install mode"
    qemu-img create -f raw "${IMAGE_PATH}" "${DISK_SIZE:-256G}"
    # snapshot=on overlays writes in a temp file; lets QEMU keep its
    # read-write block semantics while the host bind-mount stays :ro.
    # The recovery image is stateless from boot to boot anyway.
    INSTALL_MEDIA="-drive id=InstallMedia,if=none,file=/opt/macos/recovery.img,format=raw,snapshot=on -device ide-hd,bus=sata.3,drive=InstallMedia"
else
    echo "Boot mode (disk ${CURRENT_SIZE} bytes)"
fi

# ---------------------------------------------------------------------------
# Memory backend — MUST be memfd-backed with share=on.
#
# The apple-gfx-pci path's libapplegfx-vulkan uses mremap(old_size=0) to alias
# QEMU's guest RAM pages into the host library's task VA (see
# lagfx_task_map_host_memory). mremap's duplicate-VMA semantics require the
# source VMA to be MAP_SHARED. QEMU's default "-m N" path uses anonymous
# MAP_PRIVATE pages, which fails the precondition and forces the library into
# its copy-on-map fallback — breaking Phase 2 guest-writable coherence
# (CmdExecIndirect2 indirect buffer re-reads, etc.).
#
# Spec: /Users/mjackson/libapplegfx-vulkan/docs/memory-coherence-audit.md §4
#       /Users/mjackson/mos/paravirt-re/phase-2-first-pixel-plan.md §8 item 4
# ---------------------------------------------------------------------------
RAM_GB="${RAM:-4}"
RAM_MB_STR="${RAM_GB}000"   # legacy GB-ish scaling kept (16 GB -> "16000" MB)
MEM_BACKEND="memory-backend-memfd,id=mem,size=${RAM_MB_STR}M,share=on"
echo "Memory backend: memfd (share=on), size=${RAM_MB_STR}M"
echo "  -> required by apple-gfx-pci mremap-alias path for Phase 2 coherence"

# ---------------------------------------------------------------------------
# Bridged networking via macvtap.
#
# Interface selection:
#   1. If HOST_IFACE is explicitly set in the environment (compose file,
#      shell export), use it. Required for hosts with multiple physical NICs
#      where the operator wants to pin a specific one.
#   2. Otherwise auto-detect: first "UP" physical interface — not loopback,
#      not docker0, not a bridge (br-*), not a veth pair, not macvtap itself.
#      This Just Works on most single-NIC servers (eth0, enp1s0, enp131s0f0,
#      ens18, etc) and avoids hardcoding any particular interface name.
#
# If nothing is found we exit loudly — silent fallback to "eth0" (or any
# hardcoded name) is what was biting us before this block landed.
# ---------------------------------------------------------------------------
if [ -z "${HOST_IFACE:-}" ]; then
    HOST_IFACE="$(ip -br link show 2>/dev/null | \
        awk '$1 !~ /^(lo|docker|br-|veth|macvtap|virbr|tailscale)/ && \
             $1 != "" && $2 == "UP" {print $1; exit}')"
    if [ -z "${HOST_IFACE}" ]; then
        echo "launch.sh: ERROR: could not auto-detect a physical host interface." >&2
        echo "  Available interfaces:" >&2
        ip -br link show >&2
        echo "  Set HOST_IFACE=<name> in docker-compose.yml or the environment." >&2
        exit 1
    fi
    echo "Host interface (auto-detected): ${HOST_IFACE}"
else
    echo "Host interface (from HOST_IFACE env): ${HOST_IFACE}"
fi
if ! ip link show "${HOST_IFACE}" >/dev/null 2>&1; then
    echo "launch.sh: ERROR: host interface '${HOST_IFACE}' not found." >&2
    echo "  Available interfaces:" >&2
    ip -br link show >&2
    exit 1
fi
ip link del macvtap0 2>/dev/null || true
ip link add link "${HOST_IFACE}" name macvtap0 type macvtap mode bridge
ip link set macvtap0 allmulticast on
ip link set macvtap0 up

IFX=$(cat /sys/class/net/macvtap0/ifindex)
TAP_DEV="/dev/tap${IFX}"
if [ ! -e "${TAP_DEV}" ]; then
    mknod "${TAP_DEV}" c \
        $(cat /sys/devices/virtual/net/macvtap0/tap*/dev | cut -d: -f1) \
        $(cat /sys/devices/virtual/net/macvtap0/tap*/dev | cut -d: -f2)
fi
MAC=$(cat /sys/class/net/macvtap0/address)
exec 3<>"${TAP_DEV}"

echo "Starting macOS VM (MAC=${MAC})..."
exec qemu-system-x86_64 -m "${RAM_MB_STR}" \
    -object "${MEM_BACKEND}" \
    -cpu "${CPU_MODEL:-host}",vendor=GenuineIntel,vmware-cpuid-freq=on \
    -machine q35,accel=kvm,memory-backend=mem \
    -smp "${SMP:-4}",cores="${CORES:-4}" \
    -device qemu-xhci,id=xhci \
    -device apple-kbd,bus=xhci.0 \
    -device apple-tablet,bus=xhci.0 \
    -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc' \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
    -global ICH9-LPC.disable_s3=1 \
    -global ICH9-LPC.disable_s4=1 \
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
    -smbios type=2 \
    -device ich9-ahci,id=sata \
    -drive id=OpenCoreBoot,if=none,format=raw,file=/opt/macos/OpenCore.img,snapshot=on \
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
    ${INSTALL_MEDIA} \
    -drive id=MacHDD,if=none,file="${IMAGE_PATH}",format=raw,cache=none,aio=native \
    -device virtio-blk-pci,drive=MacHDD \
    -netdev tap,id=net0,fd=3 \
    -device virtio-net-pci,netdev=net0,mac="${MAC}" \
    -chardev file,id=serial_file,path="${SERIAL_LOG}",append=off \
    -serial chardev:serial_file \
    -chardev socket,id=hmp_sock,path="${HMP_SOCK}",server=on,wait=off \
    -monitor chardev:hmp_sock \
    -qmp unix:"${QMP_SOCK}",server=on,wait=off \
    -display none \
    -vnc 127.0.0.1:1 \
    -vga none \
    -device vmware-svga,vgamem_mb="${VGAMEM_MB:-512}" \
    ${APPLE_GFX_DEVICE} \
    ${EXTRA:-}
