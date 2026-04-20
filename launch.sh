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

# Detect install vs running mode
CURRENT_SIZE=$(stat -c%s "${IMAGE_PATH}" 2>/dev/null || echo 0)
INSTALL_MEDIA=""
if [[ "${CURRENT_SIZE}" -lt 1048576 ]]; then
    echo "Empty disk — install mode"
    qemu-img create -f raw "${IMAGE_PATH}" "${DISK_SIZE:-256G}"
    INSTALL_MEDIA="-drive id=InstallMedia,if=none,file=/opt/macos/recovery.img,format=raw -device ide-hd,bus=sata.3,drive=InstallMedia"
else
    echo "Boot mode"
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

# Bridged networking via macvtap
HOST_IFACE="${HOST_IFACE:-enp131s0f0}"
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
    -drive id=OpenCoreBoot,if=none,format=raw,file=/opt/macos/OpenCore.img \
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
    ${INSTALL_MEDIA} \
    -drive id=MacHDD,if=none,file="${IMAGE_PATH}",format=raw,cache=none,aio=native \
    -device virtio-blk-pci,drive=MacHDD \
    -netdev tap,id=net0,fd=3 \
    -device virtio-net-pci,netdev=net0,mac="${MAC}" \
    -display none \
    -vnc 127.0.0.1:1 \
    -vga none \
    -device vmware-svga,vgamem_mb="${VGAMEM_MB:-512}" \
    ${APPLE_GFX_DEVICE} \
    ${EXTRA:-}
