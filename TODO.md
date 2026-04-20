# mos15 TODO

Zero-kext macOS 15 in Docker. Fix the hardware, not the driver.

## Priority 1: QEMU Video Card (`vmware_vga.c`)

**Goal:** macOS sees a proper GPU with a loaded driver. VRAM 256MB. No "No Kext Loaded."

- [ ] Fix VRAM reporting — macOS shows 7MB, should be 256MB. Find where macOS reads VRAM (PCI BAR? SVGA register? DeviceProperties?) and make it right
- [ ] Add EDID — DDC/I2C response for iMac 27" display. macOS needs this for display name, resolution list, color profile
- [ ] Raise max resolution — 3840×2160 (was 2368×1770). **Add alone first, test, then add caps**
- [ ] Add capabilities ONE AT A TIME — extended FIFO, pitchlock, alpha blend, multimon. Last attempt adding all at once caused a hang
- [ ] Test if macOS loads a better built-in driver with improved hardware
- [ ] If still "No Kext Loaded" — revisit kext injection via config.plist on vanilla OpenCore 1.0.7

## Priority 2: QEMU SMC (`applesmc.c`)

**Goal:** Zero unknown SMC key reads. Full protocol. No timeouts.

- [ ] Add 67 unknown keys from boot log (list below)
- [ ] Verify GET_KEY_TYPE protocol fix resolved all `smcGetKeyInfoPMIO` timeouts
- [ ] Add proper `#KEY`/`$Num` key count (update when keys are added)
- [ ] Test boot with all keys — should be zero `mos15-smc` log messages

### SMC Keys to Add

**Temperature (27 keys):**
TC0F, TC0P, TCXc, TG0F, TG1F, TH0P, TH1A, TH1C, TH1F, TL0V, TL1V, TM0P, TM0V, Tp00, Tp2F, Ts0S, TS0V, Ts1S, Ts2S, TB0T, TB1T, TB2T, TA0V, TVMD, TVmS, TVSL, TVSR

**Power/Platform (12 keys):**
PC0R, PCPC, PCPG, PCPT, PfCP, PfCT, PfGT, PfHT, PfM0, PfST, PSTR, PHDC

**Memory/DIMM (6 keys):**
DM0P, DM0S, DM1P, DM1S, MD1R, MD1W

**SMC Internal (11 keys):**
CLKH, DICT, RPlt, SBFL, VRTC, WKTP, zEPD, cePn, cmDU, maNN, mxT1

**Sensors/Misc (13 keys):**
MSAc, MSAf, MSAg, MSAi, MSGA, MSHP, MSPA, MTLV, QCLV, QENA, WIr0, WIw0, WIz0

**Write targets (add as known keys too):**
HE0N, MSDW, NTOK

## Priority 3: CPU Power States (ACPI)

**Goal:** Eliminate 48 P-State/C-State errors per boot.

- [ ] Add `_PSS` ACPI method for QEMU CPU objects — provides P-State frequency list
- [ ] Add `_CST` ACPI method — provides C-State idle states
- [ ] Or: add SSDT-PLUG table via OpenCore for Haswell Xeon CPU layout
- [ ] QEMU uses `CPUS` ACPI scope not `\_PR.CPU0` — custom table needed

## Priority 4: Remaining Errors

- [ ] `ACPI Error: [S38_]` — add ACPI hotplug table or verify launch.sh arg
- [ ] `Sleep failure code 0xffffffff` — verify sleep fully disabled
- [ ] `IOPolledFilePollersSetup error` — hibernation corefile, should be disabled with S3/S4 off

## Won't Fix (VM Limitations)

- AppleKeyStore errors — no SEP hardware
- `_process_matches_constraint` — AMFI checks, SEP related
- `shared_region` vnode_lookup — dyld cache timing during boot
- `Bad CPU type in executable` — ARM binaries on x86
- IOMFB/appleh13camerad missing — Apple Silicon daemons
- PerfPowerService burning CPU — needs GPU for proper power management

## Architecture

```
github.com/MattJackson/mos-qemu       ← QEMU patches (3 files)
github.com/MattJackson/mos-docker     ← Docker image (ships vanilla acidanthera OpenCorePkg 1.0.7)
```

## Current State

- [x] Zero kexts — boots to desktop
- [x] QEMU SMC — 27 keys, all 4 commands, unknown keys return zeros + log
- [x] VirtualSMC disabled itself — QEMU SMC is sole provider
- [x] No HE2N crash — AGPM doesn't crash on wallpaper change
- [x] No SMCWDT errors
- [x] Apple USB HID — Magic Keyboard/Mouse/Trackpad identity
- [ ] VRAM — still shows 7MB
- [ ] Display driver — "No Kext Loaded"
- [ ] Dynamic wallpaper — white (WallpaperAgent memory limit, needs GPU)
- [ ] 67 unknown SMC keys — logged, need adding
- [ ] 48 CPU P/C-State errors — need ACPI tables
