# Testing Matrix

## CPU Model + QEMU Version

| # | QEMU | CPU Model | shared_region errors | Boots to installer | Installs | Notes |
|---|------|-----------|---------------------|-------------------|----------|-------|
| 1 | 9.1.2 (Alpine) | host | Unknown (no serial) | YES | YES | Previous working config. Screen Sharing works on Sequoia. |
| 2 | 10.2.2 (source) | host | 1072 errors | YES (slow) | Hangs at "less than a minute" | shared_region failures on every process. License text unavailable. |
| 3 | 10.2.2 (source) | Haswell-v4 | 0 errors | NO | N/A | Hangs at Apple logo, 420MB RAM, zero IO. |
| 4 | 9.1.2 (Alpine) | Haswell-v4 | ? | ? | ? | Testing — isolates QEMU version. |
| 5 | 10.2.2 (source) | Haswell-v1 | ? | ? | ? | Next test if #4 works — more CPU features (TSX). |
| 6 | 9.1.2 (Alpine) | host | ? | ? | ? | Baseline retest with serial logging. |

## Hardware
- Host CPU: Intel Xeon E5-2699 v3 @ 2.30GHz (Haswell-EP), 18-core x2 = 72 threads
- KVM: enabled

## Key Findings
- `-cpu host` on QEMU 10.2.2 causes shared_region mapping failures (1072 per boot)
- `-cpu Haswell-v4` on QEMU 10.2.2 fixes shared_region but kernel hangs during boot
- `-cpu host` on QEMU 9.1.2 works end-to-end (installed + booted Sequoia successfully)
- Haswell-v4 = "Haswell, no TSX, IBRS" — matches E5-2699 v3 microcode profile
- shared_region error: `vm_shared_region_start_address() returned 0x1` — dyld cache won't map

## I/O Configuration (current)
- All storage: virtio-blk-pci (raw format)
- Network: virtio-net-pci (macvtap bridge)
- Main disk: cache=none, aio=native
- Recovery: cache=unsafe
- OpenCore: cache=unsafe, readonly=on (virtio-blk)

## Display
- vmware-svga: 7MB VRAM (Apple driver hardcoded limit)
- Screen Sharing: works on Sequoia, crashes WindowServer on Tahoe
- VMsvga2 kext: OpenCore injection failed (binary too old for macOS 15); rebuild pending
