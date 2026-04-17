FROM alpine:3.21 AS builder

# Build QEMU 10.2.2 from source
RUN apk add --no-cache \
    build-base \
    python3 \
    ninja \
    meson \
    pkgconf \
    glib-dev \
    pixman-dev \
    libcap-ng-dev \
    libseccomp-dev \
    libslirp-dev \
    libaio-dev \
    curl \
    bash \
    git \
    dtc-dev

ARG QEMU_VERSION=10.2.2
RUN curl -sL https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz | tar xJ -C /tmp \
    && cd /tmp/qemu-${QEMU_VERSION} \
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

# Final image
FROM alpine:3.21

# Runtime dependencies only
RUN apk add --no-cache \
    glib \
    pixman \
    libcap-ng \
    libseccomp \
    libslirp \
    libaio \
    libbz2 \
    dtc \
    bash \
    iproute2 \
    ovmf

# QEMU 10.2.2 from builder
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-system-x86_64 /usr/bin/
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-img /usr/bin/
COPY --from=builder /tmp/qemu-install/usr/share/qemu/ /usr/share/qemu/

# macOS files
COPY sequoia_recovery.img /opt/macos/recovery.img
COPY OpenCore.img /opt/macos/OpenCore.img
COPY launch.sh /opt/macos/launch.sh
RUN chmod +x /opt/macos/launch.sh

WORKDIR /opt/macos

ENV RAM=4 SMP=4 CORES=4 NETWORKING=vmxnet3 IMAGE_PATH=/opt/macos/mac_hdd_ng.img DISK_SIZE=256G EXTRA=

CMD ["/opt/macos/launch.sh"]
