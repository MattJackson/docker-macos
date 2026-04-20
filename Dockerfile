# mos suite — docker-macos
# https://github.com/MattJackson/mos-docker
#
# Layered build:
#   1. Alpine 3.21 builder stage compiles QEMU 10.2.2 with our qemu-mos15 patches
#   2. Final Alpine runtime stage bundles QEMU + OVMF + recovery image + EFI image + launch.sh
#
# OpenCore: vanilla acidanthera/OpenCorePkg 1.0.7 (see OPENCORE_VERSION below).
# The OpenCore EFI binaries (OpenCore.efi, BOOTx64.efi, Drivers/, Resources/) and
# the assembled bootable OpenCore.img live in the build context — they are extracted
# from the upstream release, NOT built from a fork. The retired mos-opencore fork
# is now upstream-PR staging only; nothing in this image depends on it.
#
# IMPORTANT — required files in the build context (this directory):
#   - sequoia_recovery.img   ← Apple recovery image, ~3.2 GB. See SETUP.md step 2.
#   - OpenCore.img           ← Bootable EFI image. Run ./build-mos15-img.sh && cp mos15.img OpenCore.img
#
# Without these the build fails with "COPY failed: file not found".

# Pinned upstream versions. Bump + rebuild to upgrade.
ARG QEMU_VERSION=10.2.2
ARG OPENCORE_VERSION=1.0.7

FROM alpine:3.21 AS builder
ARG QEMU_VERSION
ARG OPENCORE_VERSION

# Build QEMU from source with our qemu-mos15 patches.
# Alpine package list is exact — `dtc-dev` is correct (NOT libfdt-dev), and
# do NOT add libmount-dev (doesn't exist in Alpine 3.21 and isn't needed).
RUN apk add --no-cache \
    build-base python3 ninja meson pkgconf \
    glib-dev pixman-dev libcap-ng-dev libseccomp-dev \
    libslirp-dev libaio-dev curl bash git dtc-dev \
    mesa-vulkan-swrast vulkan-loader vulkan-headers vulkan-tools

# Clone and build libapplegfx-vulkan
RUN git clone https://github.com/MattJackson/libapplegfx-vulkan.git /tmp/libapplegfx-vulkan \
    && cd /tmp/libapplegfx-vulkan \
    && meson setup --prefix=/usr --libdir=lib builddir \
    && ninja -C builddir install

RUN curl -sL https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz | tar xJ -C /tmp \
    && cd /tmp/qemu-${QEMU_VERSION} \
    && curl -sL https://github.com/MattJackson/mos-qemu/archive/refs/heads/main.tar.gz | tar xz -C /tmp \
    && cp /tmp/qemu-mos15-main/hw/misc/applesmc.c hw/misc/applesmc.c \
    && cp /tmp/qemu-mos15-main/hw/display/vmware_vga.c hw/display/vmware_vga.c \
    && cp /tmp/qemu-mos15-main/hw/usb/dev-hid.c hw/usb/dev-hid.c \
    && cp /tmp/qemu-mos15-main/hw/display/apple-gfx-pci-linux.c hw/display/ \
    && cp /tmp/qemu-mos15-main/hw/display/apple-gfx-common-linux.c hw/display/ \
    && cp /tmp/qemu-mos15-main/hw/display/apple-gfx-linux.h hw/display/ \
    && cp /tmp/qemu-mos15-main/hw/display/meson.build hw/display/meson.build \
    && cp /tmp/qemu-mos15-main/hw/display/Kconfig hw/display/Kconfig \
    && cp /tmp/qemu-mos15-main/pc-bios/meson.build pc-bios/meson.build \
    && cp /tmp/qemu-mos15-main/pc-bios/apple-gfx-pci.rom pc-bios/apple-gfx-pci.rom \
    && ./configure \
        --target-list=x86_64-softmmu \
        --prefix=/usr \
        --enable-kvm \
        --enable-slirp \
        --enable-linux-aio \
        --enable-cap-ng \
        --enable-seccomp \
        --enable-vnc \
        --disable-docs \
        --disable-debug-info \
        --disable-werror \
    && make -j$(nproc) \
    && make DESTDIR=/tmp/qemu-install install

# Final image — layer order: alpine → recovery → qemu → ovmf → opencore → launch
FROM alpine:3.21

# 1. Alpine + runtime deps (changes rarely)
RUN apk add --no-cache \
    glib pixman libcap-ng libseccomp libslirp \
    libaio libbz2 dtc bash iproute2 ovmf \
    vulkan-loader mesa-vulkan-swrast

# 2. Recovery image (3.2GB, never changes after initial download)
COPY sequoia_recovery.img /opt/macos/recovery.img

# 3. QEMU binaries (changes only when QEMU version or patches change)
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-system-x86_64 /usr/bin/
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-img /usr/bin/
COPY --from=builder /tmp/qemu-install/usr/share/qemu/ /usr/share/qemu/

# 4. Clean OVMF_VARS template for NVRAM reset (changes only when ovmf package updates)
RUN cp /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.clean.fd

# 5. OpenCore bootdisk (changes when kexts/config change)
COPY OpenCore.img /opt/macos/OpenCore.img

# 6. Launch script (changes most often)
COPY launch.sh /opt/macos/launch.sh
RUN chmod +x /opt/macos/launch.sh

WORKDIR /opt/macos

ENV RAM=4 SMP=4 CORES=4 IMAGE_PATH=/opt/macos/mac_hdd_ng.img DISK_SIZE=256G EXTRA=

CMD ["/opt/macos/launch.sh"]
