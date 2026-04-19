# Contributing to docker-macos

## The mos suite

This project is one of four repos working together to run macOS Sequoia in Docker on Linux+KVM:

- **docker-macos** (this repo) — orchestration: Docker image, build pipeline, kext source, OpenCore config, tests, runbook
- **[mos-patcher](https://github.com/MattJackson/mos-patcher)** — kernel-side hook framework (Lilu replacement, ~700 LOC we own)
- **[mos-qemu](https://github.com/MattJackson/mos-qemu)** — patches to QEMU 10.2.2 (`applesmc`, `vmware_vga`, `dev-hid`)
- **[mos-opencore](https://github.com/MattJackson/mos-opencore)** — OpenCore patches (System KC injection — research, not active path)

A change to anything user-visible usually touches at least two of these. Cross-link in commit messages.

## Building

### Requirements

- **macOS host** with Xcode CLI tools — for cross-compiling kexts and host-side test binaries (`list-modes`, `metal-probe`)
- **Linux host with KVM** + Docker — for running the VM and rebuilding QEMU
- A built macOS install image — the initial install is a separate process; this pipeline begins after install

### mos15-patcher (the kernel hook framework)

```bash
cd /path/to/mos15-patcher
KERN_SDK=/path/to/MacKernelSDK ./build.sh
# Output: build/mos15-patcher.kext
cp -R build/mos15-patcher.kext /path/to/docker-macos/kexts/deps/
```

### QEMUDisplayPatcher kext (this repo)

```bash
cd kexts/QEMUDisplayPatcher
rm -rf build
./build.sh
# Output: build/QEMUDisplayPatcher.kext
```

### Image assembly + deploy

```bash
./build-mos15-img.sh   # produces builds/mos15_YYYYMMDDHHMMSS.img + symlink
./deploy.sh            # stops container, scp, retargets symlink, restarts
```

### Patching QEMU itself (qemu-mos15 changes)

See `docs/qemu-mos15-build.md`. Critical gotcha: **build inside Alpine 3.21**, not on a glibc host. The container is musl-based; a glibc binary fails to launch with a misleading "required file not found" error.

## Verifying a deploy

```bash
./tests/verify-modes.sh
```

That walks through the runbook (`docs/test-runbook.md`): hook coverage, EDID identity, mode enumeration, VRAM, SPDisplays panel. Exits non-zero with a precise failure on the first missing signal.

## Code conventions

- C/C++ for kext source (no third-party deps beyond Apple's IOKit SDK)
- C for QEMU patches (matches upstream conventions)
- Shell scripts: `set -euo pipefail`, descriptive errors, no silent failures
- One change at a time, build, test, commit. Foundation-first — no F1-engine-in-a-shitty-car
- Document every non-obvious finding in `.claude/memory/` (durable knowledge across sessions) or `DISCOVERY.md` (long-form historical record)

## Commit style

- Short title line (≤72 chars), imperative mood ("QDP: hook connectFlags + 5 more")
- Body explains WHY, not WHAT (the diff shows the what)
- Reference task numbers if they're being closed
- Co-Authored-By trailer if AI-assisted (we use Claude)

## Reporting issues

Until issue templates land, include:

- macOS version (`sw_vers` from inside the VM)
- QEMU version (`/data/macos/qemu-mos15 --version` on the docker host)
- Reproduction steps from a clean container restart
- Output of `./tests/verify-modes.sh`
- Relevant `sudo log show --last 5m --predicate '...' 2>/dev/null` excerpt

## License

[GNU AGPL-3.0](LICENSE). All contributions inherit this license. Network use counts as distribution — anyone running a fork as part of a service must offer the source to its users.
