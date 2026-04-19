# docker-macos

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
| **docker-macos** (this) | Dockerfile, build pipeline, kext source, OpenCore config, the orchestration |
| [qemu-mos15](https://github.com/MattJackson/qemu-mos15) | QEMU patches — `applesmc`, `vmware_vga`, `dev-hid` |
| [mos15-patcher](https://github.com/MattJackson/mos15-patcher) | Kernel-side hook framework (Lilu replacement, ~700 LOC) |
| [opencore-mos15](https://github.com/MattJackson/opencore-mos15) | OpenCore patches — System KC injection (research, not active path) |

## Architecture

```
QEMU mos15  (95+ SMC keys, 4K VMware SVGA, Apple USB HID)
  └── KVM acceleration  (-cpu host)
        └── OpenCore                     (boots SMBIOS iMac20,1, injects Boot KC kexts)
              ├── mos15-patcher.kext     (kernel hook framework — Lilu replacement)
              └── QEMUDisplayPatcher.kext  (24 IOFramebuffer-method hooks)
                    └── macOS Sequoia 15.7.5
```

## Build & deploy pipeline

Single source of truth: every byte in the running VM is generated from inputs in this repo (or from named build artifacts of the other mos repos). Reproducible end-to-end.

```bash
# (if mos15-patcher changed) rebuild + drop into kexts/deps
cd /Users/mjackson/mos15-patcher
KERN_SDK=/Users/mjackson/docker-macos/kexts/deps/MacKernelSDK ./build.sh
cp -R build/mos15-patcher.kext /Users/mjackson/docker-macos/kexts/deps/

# Always
cd /Users/mjackson/docker-macos/kexts/QEMUDisplayPatcher && rm -rf build && ./build.sh
cd /Users/mjackson/docker-macos
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
| `efi/EFI/OC/Drivers/*.efi` | Yes | UEFI drivers from upstream OC release |
| `efi/EFI/OC/Resources/` | Yes | OC GUI assets from upstream OC release |
| `efi/EFI/OC/OpenCore.efi`, `efi/EFI/BOOT/BOOTx64.efi` | Yes | Currently extracted from a previous build (TODO: rebuild from `opencore-mos15` source in pipeline) |
| `kexts/deps/mos15-patcher.kext` | No (build artifact) | Build of `mos15-patcher` repo |
| `kexts/QEMUDisplayPatcher/build/QEMUDisplayPatcher.kext` | No (build artifact) | Build of `kexts/QEMUDisplayPatcher/` |
| `~/mos-staging/SystemKernelExtensions.kc` | No (349 MB) | Extracted from a running VM, kept in private docs repo |
| Output: `builds/mos15_YYYYMMDDHHMMSS.img` | No (gitignored) | Reproducible from above |

## Requirements

- **Linux host** with Intel VT-x / KVM, `/dev/kvm` accessible, Docker installed
- **macOS host** (Apple Silicon or Intel) with Xcode CLI tools — needed for kext cross-compilation and the host-side Metal/CG probes in `tests/`
- A built macOS install image (initial install is a separate process — recovery image + manual installer run; pipeline starts after install)

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
