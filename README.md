# mos-docker

macOS Sequoia (15.7.5) running in Docker on Linux+KVM, with patched QEMU + a kernel-side display patcher for an OEM-like experience.

> **Status: v0.5 — usable but barebones.** Boots reliably, reaches desktop with auto-login, advertises as iMac20,1 with HiDPI 4K display. Suitable for headless/SSH workflows and Screen Sharing. Production hardening (multi-user, GPU acceleration, dynamic wallpaper) is incomplete. See [Status](#status) below.

## What works today

- macOS Sequoia 15.7.5 boots in Docker on Linux+KVM, reaches desktop in ~2 minutes
- Display recognized as **iMac** with **3840×2160 4K resolution** + HiDPI ("looks like 1920×1080")
- 7 of 8 advertised resolutions visible in the System Settings dropdown (1080p–4K)
- 512 MB VRAM (capped by current QEMU vmware-svga device — open enhancement to lift)
- Auto-login to the matthew user account
- noVNC web access via `geek1011/easy-novnc` companion container
- Screen Sharing works at full resolution
- SSH access for headless work (full perf, no compositor cost)
- 24/24 IOFramebuffer methods hooked cleanly via mos15-patcher; verified each boot via ioreg properties
- Authentic iMac20,1 EDID injection (Apple PnP `APP`, product ID `0xAE31`)

## The mos suite

| Repo | What |
|---|---|
| **mos-docker** (this) | Dockerfile, build pipeline, kext source, OpenCore config, the orchestration |
| [mos-qemu](https://github.com/MattJackson/mos-qemu) | QEMU patches — `applesmc`, `vmware_vga`, `dev-hid` |
| [mos-patcher](https://github.com/MattJackson/mos-patcher) | Kernel-side hook framework (Lilu replacement, ~700 LOC) |
| [mos-opencore](https://github.com/MattJackson/mos-opencore) | Upstream-PR staging for a System KC loading feature; **not used in this product**. |

### OpenCore

The bootloader is vanilla [acidanthera/OpenCorePkg 1.0.7](https://github.com/acidanthera/OpenCorePkg/releases/tag/1.0.7) — no custom patches. Every `.efi` under `efi/EFI/OC/` (OpenCore.efi, BOOTx64.efi, Drivers/, Resources/) comes from the upstream release tarball; only our own `config.plist` and ACPI tables are project-owned. Credit to [acidanthera](https://github.com/acidanthera) for OpenCore.

The `mos-opencore` fork is kept alive as a staging branch for an upstream PR (System KC loading for cross-KC kext deps). It was used during the Branch A research phase (rev 6) and is orphaned on our current product path. Do not expect product changes to land there.

## Architecture

```
QEMU mos15  (95+ SMC keys, 4K VMware SVGA, Apple USB HID)
  └── KVM acceleration  (-cpu host)
        └── OpenCore 1.0.7 (vanilla)     (boots SMBIOS iMac20,1, injects Boot KC kexts)
              ├── mos15-patcher.kext     (kernel hook framework — Lilu replacement)
              └── QEMUDisplayPatcher.kext  (24 IOFramebuffer-method hooks)
                    └── macOS Sequoia 15.7.5
```

## Build & deploy pipeline

Single source of truth: every byte in the running VM is generated from inputs in this repo (or from named build artifacts of the other mos repos). Reproducible end-to-end.

```bash
# (if mos15-patcher changed) rebuild + drop into kexts/deps
cd ~/mos/mos15-patcher
KERN_SDK=$HOME/mos/docker-macos/kexts/deps/MacKernelSDK ./build.sh
cp -R build/mos15-patcher.kext $HOME/mos/docker-macos/kexts/deps/

# Always
cd ~/mos/docker-macos/kexts/QEMUDisplayPatcher && rm -rf build && ./build.sh
cd ~/mos/docker-macos
./build-mos15-img.sh   # produces builds/mos15_YYYYMMDDHHMMSS.img + symlink
./deploy.sh            # stops container, scp, retargets symlink, restarts

# Verify the deployed state end-to-end
./tests/verify-modes.sh

# Watch boot
ssh docker 'sudo docker logs -f macos-macos-1'
```

For one-line patches to QEMU itself (e.g. `applesmc.c`), see the iterate-build-deploy guide in [`docs/qemu-mos15-build.md`](docs/qemu-mos15-build.md).

For the deploy walk-through with expected pass/fail signals, see [`docs/test-runbook.md`](docs/test-runbook.md).

### Inputs to `build-mos15-img.sh`

| Input | Tracked? | Source |
|---|---|---|
| `efi/EFI/OC/config.plist` | Yes | OpenCore configuration |
| `efi/EFI/OC/ACPI/*.aml` | Yes | ACPI tables |
| `efi/EFI/OC/Drivers/*.efi` | Yes | UEFI drivers from vanilla acidanthera/OpenCorePkg 1.0.7 release |
| `efi/EFI/OC/Resources/` | Yes | OC GUI assets from vanilla acidanthera/OpenCorePkg 1.0.7 release |
| `efi/EFI/OC/OpenCore.efi`, `efi/EFI/BOOT/BOOTx64.efi` | Yes | Extracted from vanilla acidanthera/OpenCorePkg 1.0.7 release tarball |
| `kexts/deps/mos15-patcher.kext` | No (build artifact) | Build of `mos15-patcher` repo |
| `kexts/QEMUDisplayPatcher/build/QEMUDisplayPatcher.kext` | No (build artifact) | Build of `kexts/QEMUDisplayPatcher/` |
| `~/mos-staging/SystemKernelExtensions.kc` | No (349 MB) | Extracted from a running VM, kept in private docs repo |
| Output: `builds/mos15_YYYYMMDDHHMMSS.img` | No (gitignored) | Reproducible from above |

## Requirements

- **Linux host** with Intel VT-x / KVM, `/dev/kvm` accessible, Docker installed
- **macOS host** (Apple Silicon or Intel) with Xcode CLI tools — needed for kext cross-compilation and the host-side Metal/CG probes in `tests/`
- A built macOS install image (initial install is a separate process — recovery image + manual installer run; pipeline starts after install)

## First-time setup

On the Linux host, from a fresh clone:

```bash
./setup.sh                  # stages ./volumes/ with disk.img (empty), plus
                            # prompts for recovery.img + opencore.img

# Follow any WARN: output from setup.sh (produce recovery.img via
# macrecovery.py + dmg2img; build opencore.img via ./build-mos15-img.sh
# on a macOS host, then copy it over). Rerun setup.sh -- it's idempotent
# and exits 0 only when ./volumes/ is fully staged.

docker compose build        # Alpine + QEMU 10.2.2 + libapplegfx-vulkan + OVMF
docker compose up -d
docker logs -f mos-docker-macos-1
```

`volumes/README.md` documents every file under `volumes/` (what it is, where
to get it, expected size). `setup.sh --help`... actually there's no help
flag, read the top of `setup.sh` for environment-variable overrides.

## Configuration

Runtime knobs are set via environment variables in `docker-compose.yml`. The
pattern is `NAME=${NAME:-default}` so host-level exports override the compose
default without editing the file.

| Env var | Default | Meaning |
|---|---|---|
| `RAM` | `16` | VM RAM in GB. Install needs >=24; steady-state 16 is comfortable. Backed by `memory-backend-memfd,share=on` (see note below). |
| `SMP` | `16` | vCPU sockets x threads. |
| `CORES` | `16` | vCPU cores per socket. |
| `DISK_SIZE` | `256G` | Disk size on first launch. |
| `VGAMEM_MB` | `512` | VMware SVGA framebuffer VRAM (capped at 512 MB device-side). |
| `HOST_IFACE` | auto-detect | Host NIC for the macvtap bridge. Leave unset to let `launch.sh` pick the first UP non-virtual interface (skips `lo`, `docker0`, `br-*`, `veth*`, `macvtap*`, `virbr*`, `tailscale*`). Set explicitly on multi-NIC hosts. |
| `GPU_CORES` | `0` | Lavapipe worker-thread budget for the apple-gfx-pci display (see below). |
| `LOG_DIR` | `/data/logs` | In-container path for per-boot serial logs. Host path via compose volume: `./logs/`. |
| `RUN_DIR` | `/data/run` | In-container path for the QEMU HMP + QMP unix sockets. Host path via compose volume: `./run/`. |

### Guest RAM backing — `memory-backend-memfd,share=on` (Phase 2 requirement)

`launch.sh` wires guest RAM via

```
-object memory-backend-memfd,id=mem,size=<RAM>000M,share=on
-machine q35,accel=kvm,memory-backend=mem
```

rather than a bare `-m <N>`. This is a **hard requirement for the apple-gfx-pci
paravirt GPU**, not a performance knob. The host-side library
(`libapplegfx-vulkan`) aliases guest RAM into its per-task VA via
`mremap(old_size=0, MREMAP_FIXED|MREMAP_MAYMOVE, ...)`, which only works when
the source VMA is `MAP_SHARED` — exactly what memfd with `share=on` provides.
With the default anonymous `-m N` path the source VMA is `MAP_PRIVATE` and
`mremap` returns `EINVAL`; the library then falls back to a copy-on-map path
that silently breaks guest-writable DMA coherence (e.g. the
`CmdExecIndirect2` indirect command buffer re-reads that Phase 2 first-pixel
depends on).

- Full audit + rationale:
  [`libapplegfx-vulkan/docs/memory-coherence-audit.md`](../libapplegfx-vulkan/docs/memory-coherence-audit.md)
- Phase-2 entry dependency: [`phase-2-first-pixel-plan.md`](../mos/paravirt-re/phase-2-first-pixel-plan.md) §8 item 4.

**How to confirm it's active:** `launch.sh` logs at startup:

```
Memory backend: memfd (share=on), size=16000M
  -> required by apple-gfx-pci mremap-alias path for Phase 2 coherence
```

Tail with `docker logs macos-macos-1 | grep -E 'Memory backend'`.

### `GPU_CORES` — apple-gfx-pci lavapipe worker budget

`GPU_CORES` caps the number of worker threads Mesa's lavapipe (the CPU Vulkan
backend behind `apple-gfx-pci`) will spin up. The value is forwarded to QEMU as
`-device apple-gfx-pci,gpu_cores=N`, which in turn sets `LP_NUM_THREADS=N`
inside the QEMU process before the Vulkan instance is created.

| Value | Behavior |
|---|---|
| `0` (default) | Emit `-device apple-gfx-pci` with no `gpu_cores=` suffix. Lavapipe falls back to its own default, which is the host CPU core count. |
| `1..64` | Emit `-device apple-gfx-pci,gpu_cores=N`. Caps lavapipe's worker pool at N. |
| non-numeric / negative / `host` | Rejected by `launch.sh` with a warning; falls back to unset behavior. `host` is reserved for a future auto-detect feature. |

**How to set:**

```bash
# Option A: inline with docker compose up
GPU_CORES=8 docker compose up -d

# Option B: export in the shell first
export GPU_CORES=8
docker compose up -d

# Option C: edit docker-compose.yml and replace the default
```

**How to observe the effective value:** `launch.sh` logs one of:

```
apple-gfx-pci: GPU_CORES=0 (unset) -> lavapipe uses host core count
apple-gfx-pci: GPU_CORES=8 -> LP_NUM_THREADS=8
```

at container startup. Tail with `docker logs macos-macos-1 | grep apple-gfx-pci`.

**Picking a value:** the measured scaling curve (2026-04-20, 1080p vkmark
desktop, Mesa lavapipe 25.2.8) is linear-ish to 8 cores, then
memory-bandwidth-limited:

| Cores | 1080p fps |
|---|---|
| 1  | 17 |
| 4  | 65 |
| 8  | 125 |
| 16 | 216 |

Rule of thumb: `SMP + GPU_CORES <= host_cores - 2` (reserve two host cores for
the QEMU main loop, IO threads, and docker-engine work). See
[`memory/project_tunable_gpu_cores.md`](../mos/memory/project_tunable_gpu_cores.md)
in the mos repo for the full analysis and
[`docs/qemu-mos15-build.md`](docs/qemu-mos15-build.md#tuning-gpu_cores-on-the-apple-gfx-pci-device)
for device-level details.

## Logging and live introspection

`launch.sh` wires three diagnostic surfaces through host-mounted volumes so tests
and operators can observe the VM without `docker exec`:

| Surface | In-container path | Host path | Purpose |
|---|---|---|---|
| Serial log | `/data/logs/serial-<ts>.log` | `./logs/serial-<ts>.log` | QEMU guest serial (OVMF, kernel early prints if `console=ttyS0`). |
| HMP monitor | `/data/run/qemu-monitor.sock` | `./run/qemu-monitor.sock` | Human-readable QEMU monitor. |
| QMP socket | `/data/run/qemu-qmp.sock` | `./run/qemu-qmp.sock` | JSON protocol for scripted introspection. |

### Serial log

Each boot writes a fresh timestamped file under `./logs/` on the host. The QEMU
flags are:

```
-chardev file,id=serial_file,path=/data/logs/serial-YYYYMMDD-HHMMSS.log,append=off
-serial chardev:serial_file
```

`docker logs macos-macos-1` still shows the launch-script output (memory-backend
banner, GPU_CORES line, boot announcements) because only the guest's first
serial port is redirected; QEMU's own stderr is untouched.

No in-container rotation. Prune on the host when it gets large:

```bash
# keep the last 14 days
find ./logs -name 'serial-*.log' -mtime +14 -delete
```

A running VM emits roughly 10-100 KB/hour of serial traffic during normal
operation; a kernel panic can spike to ~100 MB/hour.

### Monitor (HMP) from outside the container

```bash
# Interactive human-readable monitor (Ctrl-D to exit)
socat - unix:$(pwd)/run/qemu-monitor.sock

# One-shot command
echo 'info qtree' | socat - unix:$(pwd)/run/qemu-monitor.sock
```

Useful commands:

| Command | What |
|---|---|
| `info qtree` | Dump the live device tree (every bus, every device, every property). |
| `info pci` | List all attached PCI devices with vendor/device/function. |
| `info registers` | Dump vCPU register state (per `-cpu` block). |
| `info status` | VM running / paused / internal-error. |
| `screendump /data/logs/frame.ppm` | Capture the VGA framebuffer to a PPM file (readable at `./logs/frame.ppm` on the host). |
| `system_reset` | Reset the guest (no container restart). |
| `quit` | Tear down the VM. Container restart policy brings it back. |

### QMP from outside the container

```bash
# Capabilities handshake then query-status
( echo '{"execute":"qmp_capabilities"}'; echo '{"execute":"query-status"}' ) \
    | socat - unix:$(pwd)/run/qemu-qmp.sock
```

For automated capture the capture/analyze pipeline in `tests/capture-boot-log.sh`
consumes the serial log directly from `./logs/` and may drive QMP for
synchronization — see that script for the current contract.

## Status — what's known broken or limited

| Issue | State |
|---|---|
| Dynamic wallpaper renders white | Diagnosed: VT decoder boot-race + downstream Metal compositing absence. Static wallpaper works. |
| `MTLCopyAllDevices` returns 0 — no Metal devices | Architectural: requires real GPU on host (we have none). See `.claude/memory/project_mos15_findings_2026_04_19_pm.md` for the full Metal-architecture analysis. |
| `setGPURole: nil IOGPU device ref` — fires twice/min | Cosmetic: scheduling-hint failure that doesn't affect functionality after the SMC fix. |
| 5K display mode (5120×2880) blocked | qemu-mos15 vmware-svga device caps at 512MB / ~4K. Open enhancement. |
| Display preferences don't persist across reboots | macOS regenerates `IODisplayPrefsKey` hash each boot; tracked. |
| `cloudd` retry-loops on missing iCloud | Non-GPU. Disable via launchctl if it becomes a drag. |
| `accessoryupdater` 17% CPU at idle | Phantom USB scan; investigate later. |
| Admin.plist trustList shape bug | macOS first-boot bug (writes `{}`/dict instead of `[]`/array). Hot-patched per VM with `plutil -replace trustList -array`. Need permanent fix in image build. |

For the full session-by-session findings (what we tried, what worked, what didn't, why), see `.claude/memory/` and `DISCOVERY.md`.

## Test infrastructure

- [`tests/verify-modes.sh`](tests/verify-modes.sh) — end-to-end deploy verification (hook coverage, EDID identity, mode list, VRAM, SPDisplays panel)
- [`tests/list-modes.m`](tests/list-modes.m) + compiled `tests/list-modes` — CoreGraphics mode enumerator (run via `launchctl asuser 501 /tmp/list-modes` inside the VM)
- [`tests/metal-probe.m`](tests/metal-probe.m) + compiled `tests/metal-probe` — Metal device enumerator
- [`docs/test-runbook.md`](docs/test-runbook.md) — step-by-step walkthrough with expected pass/fail signals
- [`docs/qemu-mos15-build.md`](docs/qemu-mos15-build.md) — fast iteration on QEMU patches without rebuilding the whole image

## Host hardware (reference for the maintained instance)

- **Server:** Dell PowerEdge R730
- **CPU:** 2× Intel Xeon E5-2699 v3 (Haswell-EP), 72 threads total
- **RAM:** 220 GB
- **GPU:** none (this is the architectural ceiling for guest-side Metal — see Status table)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Project ethos: foundation-first, surgical changes, document every finding, single source of truth.

## License

[GNU AGPL-3.0](LICENSE). Network use counts as distribution — anyone running this stack as part of a service must offer the source to its users.
