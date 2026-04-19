# Spinning up docker-macos from a clean clone

End-to-end guide from `git clone` to running macOS desktop. Read top to bottom — order matters.

## Prerequisites

### Linux host (the one that runs the VM)

- Intel CPU with VT-x; `/dev/kvm` accessible by your user (`ls -l /dev/kvm` should show `crw-rw----` and your user in group `kvm`)
- Docker + Docker Compose (`docker compose version` ≥ 2.x)
- ≥ 32 GB RAM (24 GB for the VM at install + headroom)
- ≥ 300 GB free disk (256 GB macOS disk image + builds + recovery image)
- Network interface name (find with `ip addr show` — common: `eth0`, `enp1s0`, `en0`)

### macOS host (the one you develop on)

- Xcode CLI tools installed (`xcode-select --install`)
- ssh access to the Linux host

This split exists because:
- The kexts (`mos15-patcher`, `QEMUDisplayPatcher`) cross-compile from a macOS host
- The host-side test binaries (`list-modes`, `metal-probe`) need to be built on macOS too
- The VM itself runs on Linux + KVM for performance

If you only have one machine, it can be the Linux side (build kexts there too with the right SDK).

## Step 1 — Clone the suite

```bash
mkdir ~/mos && cd ~/mos
git clone https://github.com/MattJackson/docker-macos
git clone https://github.com/MattJackson/mos15-patcher
git clone https://github.com/MattJackson/qemu-mos15
git clone https://github.com/MattJackson/opencore-mos15   # optional; not on active path
```

## Step 2 — Get the macOS recovery image

You need an Apple recovery image (`sequoia_recovery.img`, ~3.2 GB) to install macOS into the VM the first time. Apple doesn't distribute these directly — common path:

1. From a real Mac running Sequoia, run [`Macrecovery.py`](https://github.com/acidanthera/OpenCorePkg/blob/master/Utilities/macrecovery/macrecovery.py) (in OpenCore's Utilities/) to download the recovery DMG
2. Convert: `dmg2img recovery.dmg sequoia_recovery.img`
3. Drop it at `docker-macos/sequoia_recovery.img`

This image is referenced by the Dockerfile (`COPY sequoia_recovery.img`) and by `launch.sh` (used in install mode when `mac_hdd_ng.img` is empty).

## Step 3 — Build the OpenCore EFI image

The kexts that hook macOS need to be built and packaged into a bootable EFI image (`mos15.img`). The image build script handles all of this.

### 3a. Build mos15-patcher (one-time per change)

From the macOS host:

```bash
cd ~/mos/mos15-patcher
KERN_SDK=$HOME/mos/docker-macos/kexts/deps/MacKernelSDK ./build.sh
cp -R build/mos15-patcher.kext $HOME/mos/docker-macos/kexts/deps/
```

(`MacKernelSDK` is checked into `docker-macos/kexts/deps/` for offline builds.)

### 3b. Build QEMUDisplayPatcher

```bash
cd ~/mos/docker-macos/kexts/QEMUDisplayPatcher
rm -rf build
./build.sh
```

### 3c. Assemble the bootable EFI image

```bash
cd ~/mos/docker-macos
./build-mos15-img.sh
# Output: builds/mos15_<timestamp>.img + mos15.img symlink
```

Copy this somewhere the Dockerfile can find it as `OpenCore.img`:

```bash
cp mos15.img OpenCore.img
```

(This duplication is on the cleanup list — see [docker-macos issues](https://github.com/MattJackson/docker-macos/issues).)

## Step 4 — Build the container image

```bash
cd ~/mos/docker-macos
docker compose build
```

This:
- Builds QEMU 10.2.2 inside Alpine 3.21 (musl) with our `qemu-mos15` patches
- Bundles `OpenCore.img` and `sequoia_recovery.img` into the runtime image
- Takes ~10–20 minutes the first time, ~2 minutes for subsequent builds (cached layers)

## Step 5 — Configure your network interface

Edit `docker-compose.yml`:

```yaml
environment:
  - HOST_IFACE=enp1s0     # ← change to your actual interface name
```

The default in `launch.sh` is `enp131s0f0` (specific to our hardware). On most machines this is `eth0`, `enp1s0`, or similar — find with `ip addr show` and pick the one that has your IP.

## Step 6 — First boot (install mode)

```bash
touch mac_hdd_ng.img        # empty file; launch.sh detects this and triggers install mode
docker compose up
```

The VM boots into the macOS recovery installer. Use the noVNC web client at `http://localhost:6080` (or whichever port the noVNC service binds) to:

1. Open Disk Utility → Erase the virtio disk as APFS
2. Quit Disk Utility → Reinstall macOS Sequoia → Continue with the on-screen installer
3. Wait ~30–60 minutes for the install (depends on host CPU)
4. After install completes and the VM reboots into the new system, finish Setup Assistant
5. Stop the container: `docker compose down`

**Apply the trustd Admin.plist patch** (one-time, until permanent fix):

```bash
ssh <vm-user>@<vm-ip> 'sudo plutil -replace trustList -array /var/protected/trustd/private/Admin.plist; sudo killall trustd'
```

Without this, trustd will burn ~62% CPU forever on a macOS first-boot bug. See `.claude/memory/project_mos15_findings_2026_04_19_pm.md`.

**Enable auto-login** (one-time):

```bash
ssh <vm-user>@<vm-ip>
sudo sysadminctl -autologin set -userName <user> -password <pw>
```

## Step 7 — Steady-state running

```bash
docker compose up -d
```

Access:
- noVNC: `http://localhost:6080`
- SSH (if enabled in macOS): `ssh <vm-user>@<vm-ip>`

## Step 8 — Verify the deploy

From the macOS dev host:

```bash
# Build the test helpers (one-time)
cd tests
clang -arch x86_64 -mmacosx-version-min=10.15 \
    -framework Foundation -framework CoreGraphics -framework CoreVideo \
    list-modes.m -o list-modes
clang -arch x86_64 -mmacosx-version-min=10.15 \
    -framework Foundation -framework Metal -framework CoreGraphics \
    metal-probe.m -o metal-probe
cd ..

# Run end-to-end verification
./tests/verify-modes.sh
```

Should report green across all checks. If anything fails, see `docs/test-runbook.md` for diagnostic steps per check.

## Iterating after first install

For most subsequent changes:

```bash
# Edit code in mos15-patcher or kexts/QEMUDisplayPatcher

# Rebuild the changed component
cd ~/mos/mos15-patcher && KERN_SDK=... ./build.sh
cp -R build/mos15-patcher.kext ~/mos/docker-macos/kexts/deps/

# Or if QDP changed
cd ~/mos/docker-macos/kexts/QEMUDisplayPatcher && rm -rf build && ./build.sh

# Re-assemble + redeploy
cd ~/mos/docker-macos
./build-mos15-img.sh
./deploy.sh

# Verify
./tests/verify-modes.sh
```

`deploy.sh` stops the container, ships the new img to the host's `/data/macos/builds/`, retargets the symlink, restarts. ~30 seconds.

For QEMU patches (`qemu-mos15` changes), see `docs/qemu-mos15-build.md` — fast iteration without a full image rebuild.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker compose build` fails copying `sequoia_recovery.img` | File missing | Get the image (see Step 2) |
| `docker compose build` fails copying `OpenCore.img` | Not built yet | Run `./build-mos15-img.sh && cp mos15.img OpenCore.img` |
| Container restarts every 30s | QEMU launch failing | `docker compose logs macos` — common: wrong network interface, missing `/dev/kvm` access, bad bind mount |
| VM hangs at Apple logo for >5 min | Likely SMC retry storm or ACPI issue | Check `docker compose logs macos | grep -i panic` |
| Bash error about `glibc` / `ld-linux-x86-64.so.2 not found` | QEMU was built on glibc but container is musl Alpine | Rebuild — see `docs/qemu-mos15-build.md` |
| trustd at 60%+ CPU after install | macOS first-boot bug | Apply Admin.plist patch in Step 6 |

## Future cleanup

This bootstrap is more involved than `docker compose up`. Open items to make it shorter:

1. Pre-built container images on a public registry → skip Step 4
2. Auto-build OpenCore.img if missing → skip Step 3c
3. Auto-detect HOST_IFACE → skip Step 5
4. Bake the Admin.plist fix into the OpenCore image build → skip the patch in Step 6

Tracked in repo issues / TODO.
