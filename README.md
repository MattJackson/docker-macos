# docker-macos

macOS in Docker. Custom QEMU hardware + Lilu plugin for an OEM-like experience.
The orchestrator for the **mos15** stack.

## What This Is

macOS Sequoia (15.7.5) running in Docker on Intel KVM, with:
- **256MB VRAM** (not 7MB) — patched at runtime in `IONDRVFramebuffer`
- **Apple "iMac" display name + EDID** — injected via Lilu plugin
- **Complete SMC emulation** (94 keys) — no VirtualSMC kext needed
- **Apple USB identity** — Magic Keyboard, Magic Mouse, Magic Trackpad
- **iMac20,1 SMBIOS** — macOS thinks it's a real iMac

## The mos15 Stack

| Repo | What |
|------|------|
| **docker-macos** (this) | Dockerfile, build pipeline, kext source, OpenCore config |
| **[qemu-mos15](https://github.com/MattJackson/qemu-mos15)** | QEMU patches — SMC, VMware SVGA, USB HID |
| **[opencore-mos15](https://github.com/MattJackson/opencore-mos15)** | OpenCore patches — System KC loading + cross-KC dependency resolution |
| **[lilu-mos15](https://github.com/MattJackson/lilu-mos15)** | Lilu patch — queue already-loaded kexts when activated late |

## Architecture

```
QEMU mos15 (94 SMC keys, 4K VMware SVGA, Apple USB HID)
  └── KVM acceleration (-cpu host)
        └── OpenCore mos15 (SMBIOS iMac20,1, kext injection from Boot KC)
              ├── Lilu mos15 (consistent onKextLoad)
              └── QEMUDisplayPatcher (Lilu plugin: patches IONDRVFramebuffer in place)
                    └── macOS Sequoia 15.7.5 — desktop, Screen Sharing, 1080p/4K
```

## Build & Deploy Pipeline

Single source of truth: every byte that goes into the running VM is generated
from inputs in this repo (or from named build artifacts of the other mos15
repos). No "what's actually deployed" mystery.

```bash
# 1. Build patched Lilu (one-time, after pulling lilu-mos15 changes)
#    See lilu-mos15/README — overlay on Lilu 1.7.2 source, build with Xcode,
#    output → kexts/deps/Lilu-mos15-DEBUG.kext

# 2. Build the QEMUDisplayPatcher kext
cd kexts/QEMUDisplayPatcher && ./build.sh && cd ../..

# 3. Assemble the bootable EFI image (mos15_<timestamp>.img + symlink)
./build-mos15-img.sh

# 4. Deploy to docker host (stops container, scp, retargets symlink, restarts)
./deploy.sh

# 5. Watch boot or run consistency test
ssh docker 'sudo docker logs -f macos-macos-1'
./kexts/QEMUDisplayPatcher/test-20.sh
```

### Inputs to `build-mos15-img.sh`

| Input | Tracked? | Source |
|-------|----------|--------|
| `efi/EFI/OC/config.plist` | Yes | OpenCore configuration |
| `efi/EFI/OC/ACPI/*.aml` | Yes | ACPI tables |
| `efi/EFI/OC/Drivers/*.efi` | Yes | UEFI drivers from upstream OC release |
| `efi/EFI/OC/Resources/` | Yes | OC GUI assets from upstream OC release |
| `efi/EFI/OC/OpenCore.efi`, `efi/EFI/BOOT/BOOTx64.efi` | Yes | Build of opencore-mos15 (currently extracted from prod, TODO: rebuild from source) |
| `kexts/deps/Lilu-mos15-DEBUG.kext` | No (build artifact) | Build of lilu-mos15 |
| `kexts/QEMUDisplayPatcher/build/QEMUDisplayPatcher.kext` | No (build artifact) | Build of `kexts/QEMUDisplayPatcher/` |
| `~/mos-staging/SystemKernelExtensions.kc` | No (349MB) | Extracted from a running VM, kept in private `mos` repo |
| Output: `builds/mos15_YYYYMMDDHHMMSS.img` | No (gitignored) | Reproducible from above |

## Requirements

- Linux host with Intel VT-x / KVM
- `/dev/kvm` accessible
- Docker
- macOS host (ARM or Intel) with Xcode for kext + Lilu compilation

## Current Status

### Working
- Desktop at 1920x1080 and 3840x2160 (4K)
- Display named "iMac" with iMac EDID
- Screen Sharing works at full resolution
- Static wallpapers
- Zero in-OS third-party kexts (SMC handled entirely by QEMU)
- Two boot kexts: Lilu (mos15 build) + QEMUDisplayPatcher

### In Progress / TODO
- 20-boot consistency for `IONDRVSupport` `onKextLoad` (Lilu patch under test)
- 256MB VRAM reported in About This Mac (added in `patchedEnableController`)
- Replicate or skip OEM NDRV init cleanly (currently skipped — trampoline page-faults)
- Dynamic wallpaper (needs jetsam limit raising)
- `opencore-mos15` source build wired into pipeline (currently uses extracted prod EFIs)

## Host Hardware

- **Build host CPU:** 2× Intel Xeon E5-2699 v3 (Haswell-EP), 72 threads
- **RAM:** 220GB
- **KVM:** enabled
- **Server class:** Dell PowerEdge R730

## License

GPL-3.0
