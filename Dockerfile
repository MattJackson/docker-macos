FROM alpine:3.21 AS builder

# Build QEMU 10.2.2 from source with Apple HID patches
RUN apk add --no-cache \
    build-base python3 ninja meson pkgconf \
    glib-dev pixman-dev libcap-ng-dev libseccomp-dev \
    libslirp-dev libaio-dev curl bash git dtc-dev

ARG QEMU_VERSION=10.2.2
RUN curl -sL https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz | tar xJ -C /tmp \
    && cd /tmp/qemu-${QEMU_VERSION} \
    && sed -i 's/\.idVendor          = 0x0627/.idVendor          = 0x05ac/g' hw/usb/dev-hid.c \
    && sed -i 's/\.idProduct         = 0x0001/.idProduct         = 0x0267/g' hw/usb/dev-hid.c \
    && sed -i 's/\[STR_MANUFACTURER\]     = "QEMU"/[STR_MANUFACTURER]     = "Apple Inc."/g' hw/usb/dev-hid.c \
    && sed -i 's/\[STR_PRODUCT_KEYBOARD\] = "QEMU USB Keyboard"/[STR_PRODUCT_KEYBOARD] = "Magic Keyboard"/g' hw/usb/dev-hid.c \
    && sed -i 's/\[STR_PRODUCT_TABLET\]   = "QEMU USB Tablet"/[STR_PRODUCT_TABLET]   = "Magic Trackpad"/g' hw/usb/dev-hid.c \
    && sed -i 's/\[STR_PRODUCT_MOUSE\]    = "QEMU USB Mouse"/[STR_PRODUCT_MOUSE]    = "Magic Mouse"/g' hw/usb/dev-hid.c \
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
    libaio libbz2 dtc bash iproute2 ovmf

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
