# qemu-mos15 build + iterate guide

Our container image's `/usr/bin/qemu-system-x86_64` is built from QEMU 10.2.2 with our patches from `/Users/mjackson/qemu-mos15/hw/`. This doc covers **two build flows**:

1. **Fast iteration** — rebuild a single `.c`, swap binary on the host, restart container (~2 min)
2. **Full image rebuild** — rebuild the Docker image via Dockerfile (~15-20 min)

Use (1) when hacking on `applesmc.c`, `vmware_vga.c`, or `dev-hid.c`. Use (2) before committing / shipping.

---

## Gotcha: glibc vs musl

**The #1 mistake.** Our container is Alpine Linux (musl libc). The host is Ubuntu (glibc). Do NOT just run `make` on the host and copy the binary in — the container will fail to launch QEMU with:

```
/opt/macos/launch.sh: line 42: /usr/bin/qemu-system-x86_64: cannot execute: required file not found
```

That error is misleading — the file IS there. "Required file not found" refers to the dynamic-linker `ld-linux-x86-64.so.2` (glibc) which doesn't exist on Alpine. The binary is **dynamically linked against the wrong libc family.**

**Correct approach: build inside an Alpine container matching the target image's Alpine version (3.21 currently).**

Verify a build is musl-linked:

```bash
file /tmp/qemu-mos15-alpine
# Expected: ELF 64-bit LSB pie executable, x86-64, ..., interpreter /lib/ld-musl-x86_64.so.1
```

If `interpreter` says `ld-linux-x86-64.so.2`, it's a glibc build — will not run in the container.

---

## Fast-iterate build (host + swap)

Prerequisites:
- QEMU 10.2.2 source tree on the docker host at `/tmp/qemu-10.2.2` (already there from the last image build)
- SSH access to the docker host
- `alpine:3.21` image pulled

Flow:

```bash
# 1. Edit patch source locally
vim /Users/mjackson/qemu-mos15/hw/misc/applesmc.c

# 2. Push the patched file to the host's QEMU tree
scp /Users/mjackson/qemu-mos15/hw/misc/applesmc.c \
    docker:/tmp/qemu-10.2.2/hw/misc/applesmc.c

# 3. Build inside Alpine (only recompiles changed .c + relinks)
ssh docker "sudo docker run --rm -v /tmp/qemu-10.2.2:/src -v /tmp:/out alpine:3.21 sh -c '
    set -e
    apk add --no-cache build-base python3 ninja meson pkgconf \
        glib-dev pixman-dev libcap-ng-dev libseccomp-dev \
        libslirp-dev libaio-dev dtc-dev curl bash > /dev/null
    cd /src
    [ -d build-alpine ] || {
        mkdir build-alpine && cd build-alpine
        ../configure --target-list=x86_64-softmmu --enable-kvm --enable-slirp \
            --enable-linux-aio --enable-cap-ng --enable-seccomp --enable-vnc \
            --disable-docs --disable-debug-info --disable-werror > /dev/null
    } && cd build-alpine
    ninja qemu-system-x86_64
    cp qemu-system-x86_64 /out/qemu-mos15-alpine
'"

# 4. Swap in (container picks up via /data/macos/qemu-mos15 bind-mount)
ssh docker "sudo docker stop macos-macos-1; \
             sudo cp /tmp/qemu-mos15-alpine /data/macos/qemu-mos15; \
             sudo docker start macos-macos-1"
```

After `apk add` finishes once in the Alpine image, subsequent invocations reuse the cached package install. First build from cold cache: ~15 min. Incremental rebuild of one file: ~30 sec.

**Save a known-good backup before swapping:**

```bash
ssh docker "sudo cp /data/macos/qemu-mos15 /data/macos/qemu-mos15.prev_$(date +%Y%m%d)"
```

The container restarts every 30s if QEMU fails to execute — check `sudo docker logs macos-macos-1`.

### Correct Alpine package names (exact)

These are the ones required by QEMU 10.2.2's `configure` for our feature set:

```
build-base python3 ninja meson pkgconf
glib-dev pixman-dev libcap-ng-dev libseccomp-dev
libslirp-dev libaio-dev dtc-dev curl bash
```

**Common mistakes:**

| Wrong name | Right name | Why |
|---|---|---|
| `libfdt-dev` | `dtc-dev` | The devicetree-compiler library's dev package is `dtc-dev` in Alpine |
| `libmount-dev` | (none — don't install) | Alpine's QEMU build doesn't need it; install attempt fails |
| `zlib-dev` | `zlib-dev` | OK but often already pulled in |
| `ncurses-dev` | `ncurses-dev` | OK but QEMU doesn't strictly need it for headless builds |

---

## Full image rebuild

When you want to produce a new `registry.docker.pq.io/macos:sequoia` image (commits/releases):

```bash
# From the docker-macos repo root
docker build -t registry.docker.pq.io/macos:sequoia .
docker push registry.docker.pq.io/macos:sequoia

# Re-pull on the host and recreate the stack via Portainer
```

The Dockerfile builds QEMU itself — it pulls the qemu-mos15 patches from GitHub at build time. Any changes to `/Users/mjackson/qemu-mos15/` must be pushed to GitHub first:

```bash
git -C /Users/mjackson/qemu-mos15 push
```

Then the Dockerfile's `curl | tar xz` step picks up the latest patches.

---

## Verifying a deployed build

After swap + container restart:

```bash
# 1. Container + QEMU running?
ssh docker "sudo docker ps --filter name=macos-macos-1 --format '{{.Status}}'"
ssh docker "sudo docker exec macos-macos-1 ps auxww | grep qemu | head -1"

# 2. Expected QEMU args include our patches? (e.g. vgamem_mb from launch.sh)
ssh docker "sudo docker exec macos-macos-1 ps auxww | grep -oE 'vgamem_mb=[0-9]+'"

# 3. macOS saw our changes? (e.g. for applesmc changes)
ssh matthew@10.1.7.20 "sudo log show --last 5s --predicate 'eventMessage CONTAINS \"SMC\"' | wc -l"
```

If behavior is wrong but container is running, the binary is loaded but the patch isn't doing what you expected — back to editing. If behavior is unchanged and old, check that `/data/macos/qemu-mos15` timestamp is recent:

```bash
ssh docker "ls -la /data/macos/qemu-mos15"
```

---

## Source layout reference

- `/Users/mjackson/qemu-mos15/` — patch sources, tracked in GitHub MattJackson/qemu-mos15
  - `hw/misc/applesmc.c` — AppleSMC device with realistic iMac20,1 sensor values + key-index enumeration
  - `hw/display/vmware_vga.c` — extended VMware SVGA (4K + capability bits)
  - `hw/usb/dev-hid.c` — Apple USB HID identity (no Keyboard Setup Assistant prompt)
- `/tmp/qemu-10.2.2/` (on docker host) — full QEMU source tree, reusable build cache
- `/tmp/qemu-10.2.2/build-alpine/` (on docker host) — musl build output
- `/data/macos/qemu-mos15` (on docker host) — the binary the container bind-mounts

See `/Users/mjackson/qemu-mos15/README.md` for the Dockerfile-based build.
