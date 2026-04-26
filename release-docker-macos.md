# v0.5 — first usable cut of the mos stack

The orchestrator for the [mos suite](#the-mos-suite). macOS Sequoia (15.7.5) running in Docker on Linux+KVM, with patched QEMU + a kernel-side display patcher for an OEM-like experience.

## What works

- macOS Sequoia boots in ~2 minutes, auto-logs into desktop
- Display recognized as **iMac** with **3840×2160 4K + HiDPI** ("looks like 1920×1080")
- 7 of 8 advertised resolutions in the System Settings dropdown
- 512 MB VRAM (real, not fake — capped by QEMU vmware-svga device)
- **Authentic iMac20,1 EDID** (Apple PnP `APP`, product `0xAE31`)
- 24/24 IOFramebuffer methods hooked, verified each boot via ioreg
- noVNC web access + Screen Sharing at full resolution
- SSH for headless/dev workflow

## What doesn't work yet

- **Dynamic wallpaper** renders white (no host GPU → no Metal compositing path)
- **Metal devices = 0** (architectural — needs real GPU on host)
- 5K display mode (qemu-mos15 vmware-svga capped at ~4K)
- Display preferences don't persist across reboots
- Several macOS daemons (`cloudd`, `accessoryupdater`) retry-loop on missing services

## Setup

See [SETUP.md](SETUP.md) for the end-to-end walkthrough. Has prerequisites for the Linux+KVM host and the macOS dev host, recovery image acquisition, kext build, container build, first install, steady-state running, and verification.

## The mos suite

| Repo | What |
|---|---|
| **docker-macos** (this) | Orchestration: Docker image, build pipeline, kext source, OpenCore config, tests, runbook |
| [mos15-patcher](https://github.com/MattJackson/mos15-patcher) v0.5 | Kernel-side hook framework (Lilu replacement, ~700 LOC) |
| [qemu-mos15](https://github.com/MattJackson/qemu-mos15) v0.5 | QEMU 10.2.2 patches (`applesmc`, `vmware_vga`, `dev-hid`) |
| [opencore-mos15](https://github.com/MattJackson/opencore-mos15) v0.5 | OpenCore patches (System KC injection — research) |

## License

AGPL-3.0. Network use counts as distribution.
