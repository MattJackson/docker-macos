# syntax=docker/dockerfile:1.7
# mos suite — docker-macos
# https://github.com/MattJackson/mos-docker
#
# Layered build:
#   1. Alpine 3.21 builder stage compiles QEMU 10.2.2 with our qemu-mos15 patches
#   2. Final Alpine runtime stage bundles QEMU + OVMF + recovery image + EFI image + launch.sh
#
# Cache strategy (requires BuildKit — default on Docker 23+):
#   - `ADD <tarball-url>` layers re-check the upstream ETag/Last-Modified on
#     every build. When libapplegfx-vulkan or mos-qemu gets a push, ONLY those
#     layers invalidate; the apk/QEMU-upstream-tarball layers stay cached.
#     This replaces the prior `RUN curl | tar` pattern which cached on the
#     literal command string and silently ignored upstream pushes.
#   - `--mount=type=cache,target=...` persists QEMU's out-of-tree build dir
#     and ccache across builds. Even when the layer cache is invalidated, .o
#     files are reused — full QEMU rebuild drops from ~3 min to ~20-40 s.
#   - ccache intercepts gcc/g++ and hashes preprocessed input; it complements
#     the build-dir cache (wins when configure flags change but sources don't).
#
# OpenCore: vanilla acidanthera/OpenCorePkg 1.0.7 (see OPENCORE_VERSION below).
# The OpenCore EFI binaries (OpenCore.efi, BOOTx64.efi, Drivers/, Resources/) and
# the assembled bootable OpenCore.img are produced by ./build-mos15-img.sh on a
# macOS host — they are extracted from the upstream release, NOT built from a
# fork. The retired mos-opencore fork is now upstream-PR staging only; nothing
# in this image depends on it.
#
# Per-deployment artifacts are NOT baked into the image. Runtime bind-mounts
# deliver them from the host's ./volumes/ directory (see docker-compose.yml
# and volumes/README.md):
#   - ./volumes/disk.img       -> /image                       (macOS install/runtime disk)
#   - ./volumes/recovery.img   -> /opt/macos/recovery.img      (Apple recovery image)
#   - ./volumes/opencore.img   -> /opt/macos/OpenCore.img      (bootable EFI image)
#
# Rationale: these are large (~3 GB recovery, 512 MB opencore, 256 GB disk)
# and change on a per-deployment cadence. Rebuilding the container image when
# swapping an opencore build is wasted work. ./setup.sh stages them from the
# host side.

# Pinned upstream versions. Bump + rebuild to upgrade.
ARG QEMU_VERSION=10.2.2
ARG OPENCORE_VERSION=1.0.7

FROM alpine:3.21 AS builder
ARG QEMU_VERSION
ARG OPENCORE_VERSION

# Build QEMU from source with our qemu-mos15 patches.
# Alpine package list is exact — `dtc-dev` is correct (NOT libfdt-dev), and
# do NOT add libmount-dev (doesn't exist in Alpine 3.21 and isn't needed).
# ccache is included so the --mount=type=cache,target=/root/.ccache below
# actually has a consumer.
RUN apk add --no-cache \
    build-base python3 ninja meson pkgconf \
    glib-dev pixman-dev libcap-ng-dev libseccomp-dev \
    libslirp-dev libaio-dev curl bash git dtc-dev \
    mesa-vulkan-swrast vulkan-loader vulkan-headers vulkan-tools \
    ccache

# Route gcc/g++ through ccache. `apk add ccache` installs symlinks at
# /usr/lib/ccache/bin/{gcc,cc,g++,...}; prepending that dir to PATH means
# any child invocation (meson, ninja, QEMU's configure) picks it up without
# per-command CC= overrides.
#
# CCACHE_BASEDIR normalizes absolute paths in __FILE__ and include lookups
# to the rootfs, so identical source cached across different container
# invocations hashes identically. Without it, ccache's hit rate on QEMU
# lands around 1% even when the source is bit-identical (measured 2026-04-20).
#
# CCACHE_SLOPPINESS=time_macros tells ccache to ignore __DATE__/__TIME__
# expansions — QEMU's version banner uses them and would otherwise force a
# miss on every TU that transitively includes them.
#
# CCACHE_COMPILERCHECK=content keys the cache off the compiler binary
# contents rather than its mtime, so an apk upgrade of gcc that ships the
# same binary (or a rebuild of the builder stage) doesn't nuke the cache.
ENV PATH="/usr/lib/ccache/bin:${PATH}" \
    CCACHE_DIR=/root/.ccache \
    CCACHE_MAXSIZE=2G \
    CCACHE_BASEDIR=/tmp \
    CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,pch_defines \
    CCACHE_COMPILERCHECK=content \
    CCACHE_NOHASHDIR=1

# ---------------------------------------------------------------------------
# libapplegfx-vulkan — built from the main branch of our fork.
#
# `ADD <url>` re-checks upstream on every build; the downloaded tarball
# layer is only reused when GitHub serves identical content. Extract +
# build happen in a separate RUN whose cache is keyed off the ADD layer,
# so a push to libapplegfx-vulkan invalidates this (and only this, plus
# anything downstream that consumes its output).
# ---------------------------------------------------------------------------
ADD https://github.com/MattJackson/libapplegfx-vulkan/archive/refs/heads/main.tar.gz /tmp/libapplegfx-vulkan.tar.gz
RUN --mount=type=cache,target=/root/.ccache \
    --mount=type=cache,target=/tmp/libapplegfx-vulkan-build \
    mkdir -p /tmp/libapplegfx-vulkan \
    && tar xz -C /tmp/libapplegfx-vulkan --strip-components=1 -f /tmp/libapplegfx-vulkan.tar.gz \
    && cd /tmp/libapplegfx-vulkan \
    && meson setup --prefix=/usr --libdir=lib /tmp/libapplegfx-vulkan-build \
    && ninja -C /tmp/libapplegfx-vulkan-build install

# ---------------------------------------------------------------------------
# QEMU 10.2.2 upstream — pinned, so this ADD effectively never invalidates
# unless QEMU_VERSION changes. Still uses ADD (not curl) for consistency
# with the pattern above and so buildx can pre-fetch in parallel.
# ---------------------------------------------------------------------------
ADD https://download.qemu.org/qemu-10.2.2.tar.xz /tmp/qemu-upstream.tar.xz

# ---------------------------------------------------------------------------
# mos-qemu patches — this is the one that matters. A push to mos-qemu's
# main branch changes the tarball hash, invalidates this ADD layer, and
# triggers the patch+build RUN below. Prior to the ADD conversion, buildx
# would cache on the literal curl command string and silently ignore
# pushes — we burnt ~20 min on that today.
# ---------------------------------------------------------------------------
ADD https://github.com/MattJackson/mos-qemu/archive/refs/heads/main.tar.gz /tmp/mos-qemu.tar.gz

# ---------------------------------------------------------------------------
# Extract QEMU, overlay mos-qemu patches, configure, build, install.
#
# Out-of-tree build into /tmp/qemu-build (cache-mounted) so .o files persist
# across builds. When mos-qemu pushes change only one or two files, make /
# ninja's dependency tracking recompiles only the affected TUs — full 3-min
# rebuild collapses to ~60-70 s (measured 2026-04-20).
#
# Re-extract upstream every build: tar preserves tarball-stored mtimes, so
# source files have stable mtimes run-to-run, which does NOT defeat
# incremental compilation. Patched mos-qemu files get a fresh "now" mtime
# from cp, which is exactly the signal make/ninja need to rebuild only
# affected TUs. This is a correctness-over-cleverness choice: a cache-mounted
# source tree would keep stale patches when mos-qemu removes a file that it
# used to patch. Re-extraction guarantees pristine upstream.
#
# ccache provides a second layer of reuse: if the cache mount is cold (fresh
# builder, pruned cache) but ccache still has entries, we still win on
# identical preprocessed inputs. CCACHE_BASEDIR + sloppiness flags above
# are load-bearing — without them ccache hits <2% on QEMU.
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.ccache \
    --mount=type=cache,target=/tmp/qemu-build \
    rm -rf /tmp/qemu-${QEMU_VERSION} /tmp/mos-qemu \
    && tar xJ -C /tmp -f /tmp/qemu-upstream.tar.xz \
    && mkdir -p /tmp/mos-qemu \
    && tar xz -C /tmp/mos-qemu --strip-components=1 -f /tmp/mos-qemu.tar.gz \
    && cd /tmp/qemu-${QEMU_VERSION} \
    && cp /tmp/mos-qemu/hw/misc/applesmc.c hw/misc/applesmc.c \
    && cp /tmp/mos-qemu/hw/display/vmware_vga.c hw/display/vmware_vga.c \
    && cp /tmp/mos-qemu/hw/usb/dev-hid.c hw/usb/dev-hid.c \
    && cp /tmp/mos-qemu/hw/display/apple-gfx-pci-linux.c hw/display/ \
    && cp /tmp/mos-qemu/hw/display/apple-gfx-common-linux.c hw/display/ \
    && cp /tmp/mos-qemu/hw/display/apple-gfx-linux.h hw/display/ \
    && cp /tmp/mos-qemu/hw/display/meson.build hw/display/meson.build \
    && cp /tmp/mos-qemu/hw/display/trace-events hw/display/trace-events \
    && cp /tmp/mos-qemu/hw/display/Kconfig hw/display/Kconfig \
    && cp /tmp/mos-qemu/pc-bios/meson.build pc-bios/meson.build \
    && cp /tmp/mos-qemu/pc-bios/apple-gfx-pci.rom pc-bios/apple-gfx-pci.rom \
    && cd /tmp/qemu-build \
    && /tmp/qemu-${QEMU_VERSION}/configure \
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
    && make DESTDIR=/tmp/qemu-install install \
    && ccache -s || true

# Final image — layer order: alpine → recovery → qemu → ovmf → opencore → launch
FROM alpine:3.21

# 1. Alpine + runtime deps (changes rarely)
# socat: used to talk to QEMU's HMP/QMP unix sockets from outside the container
# (see README.md "Logging" section and launch.sh boot-diagnostics block).
RUN apk add --no-cache \
    glib pixman libcap-ng libseccomp libslirp \
    libaio libbz2 dtc bash iproute2 ovmf \
    vulkan-loader mesa-vulkan-swrast \
    socat

# 1b. Boot-diagnostics directories + stub mount points for the runtime
# bind-mounts. launch.sh re-creates /data/{logs,run} (safe for bind mounts),
# and the /opt/macos/{OpenCore.img,recovery.img} stubs exist only so docker's
# "auto-create-parent-dir" behaviour doesn't surprise us if the operator
# forgets a volume mount — launch.sh will then detect the zero-byte file and
# print a clear error.
RUN mkdir -p /data/logs /data/run /opt/macos

# 2. QEMU binaries (changes only when QEMU version or patches change)
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-system-x86_64 /usr/bin/
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-img /usr/bin/
# libapplegfx-vulkan shared library -- QEMU binary is linked against it at
# /usr/lib/libapplegfx-vulkan.so.0. Copy the SONAME + the versioned file so
# the runtime loader resolves the link.
COPY --from=builder /usr/lib/libapplegfx-vulkan.so* /usr/lib/
COPY --from=builder /tmp/qemu-install/usr/share/qemu/ /usr/share/qemu/

# 3. Clean OVMF_VARS template for NVRAM reset (changes only when ovmf package updates)
RUN cp /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.clean.fd

# 4. Launch script (changes most often). Baked in; overridable at runtime via
# a bind-mount only if the operator really wants to, but the compose file
# does not bind-mount it by default -- see docker-compose.yml rationale.
COPY launch.sh /opt/macos/launch.sh
RUN chmod +x /opt/macos/launch.sh

WORKDIR /opt/macos

ENV RAM=4 SMP=4 CORES=4 IMAGE_PATH=/opt/macos/mac_hdd_ng.img DISK_SIZE=256G EXTRA= \
    GPU_CORES=0

CMD ["/opt/macos/launch.sh"]
