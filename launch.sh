#!/bin/bash
set -eu

cd /opt/macos

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
exec qemu-system-x86_64 -m "${RAM:-4}000" \
    -cpu "${CPU_MODEL:-host}",vendor=GenuineIntel,vmware-cpuid-freq=on \
    -machine q35,accel=kvm \
    -smp "${SMP:-4}",cores="${CORES:-4}" \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 \
    -device usb-tablet,bus=xhci.0 \
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
    ${EXTRA:-}
