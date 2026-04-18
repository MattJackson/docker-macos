# mos15 Display Driver — Handoff Document

## What We Built

macOS 15 (Sequoia) running in Docker on a Dell R730 (Intel Xeon Haswell, 72 cores, 220GB RAM). Three repos:

- `github.com/MattJackson/docker-macos` — Docker image, kext source, OpenCore config
- `github.com/MattJackson/qemu-mos15` — QEMU patches (SMC, VMware SVGA, USB HID)
- `github.com/MattJackson/opencore-mos15` — OpenCore patches (System KC loading)

## What Works

### QEMU mos15 (hw/misc/applesmc.c, hw/display/vmware_vga.c, hw/usb/dev-hid.c)
- 94 SMC keys — replaces VirtualSMC kext entirely
- Unknown SMC keys return zeros + log (never NOEXIST)
- Full SMC protocol: READ, WRITE, GET_KEY_TYPE, GET_KEY_BY_INDEX
- VMware SVGA: 4K resolution (3840x2160), extended capabilities
- Apple USB HID: Magic Keyboard/Mouse/Trackpad identity
- Zero kexts boot to desktop with stock VMware driver

### QEMUDisplay kext (kexts/QEMUDisplay/)
- **PROVEN WORKING via manual install to /Library/Extensions**
- IOFramebuffer subclass for VMware SVGA II
- Reads VRAM from SVGA hardware registers: 256MB (not hardcoded 7MB)
- Port-mapped I/O via pciDevice->ioRead32/ioWrite32 (BAR0 = 0x6120)
- VGA mode (not SVGA) — QEMU VNC auto-refreshes from VRAM
- EDID via getDDCBlock — display named "iMac"
- Power management: setPowerState, enableController, PMinit
- SMC writes HE0N/HE2N=1 to enable GPU power via AGPM
- Interrupt registration: VBL, Connect, DisplayPort
- setGammaTable, setAttributeForConnection, getApertureRange (sub-range)
- IOFB0Hz, IOFBGammaCount/Width properties
- Login screen, desktop, Screen Sharing all work at 1920x1080 and 3840x2160
- Static wallpapers work
- Dynamic wallpapers white (need jetsam limit raising — requires private kernel symbols)

### OpenCore mos15 (kexts/deps/OpenCorePkg/)
- System KC loading from EFI partition (365MB) works
- IOGraphicsFamily found in System KC fileset entries
- Chained fixups applied (inner kext + outer KC)
- Symbol table built: 1590 symbols, 56 vtables for IOGraphicsFamily
- IOPCIFamily: 1027 symbols, 24 vtables
- Dependency resolution complete

## The Injection Problem

QEMUDisplay is an IOFramebuffer subclass. IOFramebuffer is in IOGraphicsFamily which is in the **System KC** (not Boot KC). OpenCore injects kexts into the **Boot KC**.

### What we tried and what happened:

1. **System KC symbol resolution** — WORKS. Loaded SystemKernelExtensions.kc (365MB) from EFI partition, parsed fileset entries, found IOGraphicsFamily, resolved all symbols and vtables.

2. **Chained fixup application** — WORKS. Applied DYLD_CHAINED_PTR_X86_64_KERNEL_CACHE fixups to resolve pointer values in System KC kexts.

3. **Address translation for relocations** — CRASHES. System KC symbols have raw addresses (0x149xxxxx). Kext is at kernel addresses (0xFFFFFF80...). The 32-bit RIP-relative branch displacement overflows (>2GB). Translating with `KERNEL_ADDRESS_BASE + KERNEL_FIXUP_OFFSET + Target` makes the displacement fit (~280MB) but the kernel panics because System KC is loaded at a different KASLR-slid address at runtime.

4. **Skip overflow relocations** — NOT TESTED. Write 0 displacement and hope kernel fixes it. Likely won't work.

5. **Remove IOGraphicsFamily from OSBundleLibraries** — DOESN'T HELP. The kernel still reports "library kext com.apple.iokit.IOGraphicsFamily not found" and refuses to load the kext. Even though symbols are prelinked, the kernel does a metadata dependency check.

6. **Force-load IOGraphicsFamily via OpenCore Kernel>Force** — FAILS. The System volume is sealed APFS, not accessible from EFI. OpenCore can't read the kext from the System volume.

7. **Aux KC injection** — NOT POSSIBLE via OpenCore. OpenCore hooks EFI file reads. Aux KC is loaded by the kernel after boot. OpenCore's hooks don't reach kernel-phase file reads.

### The fundamental issue:
OpenCore puts kexts in the **Boot KC**. Boot KC loads BEFORE System KC. A kext in Boot KC cannot depend on System KC kexts (IOGraphicsFamily) because:
- At prelink time: don't know System KC KASLR slide → can't write correct call addresses
- At runtime: kernel checks OSBundleLibraries and rejects if dependency not in Boot KC
- The Aux KC loads AFTER System KC and handles cross-KC dependencies — but OpenCore can't inject there

### What DOES work:
Manual install to `/Library/Extensions` → goes into Aux KC → loads after System KC → IOGraphicsFamily dependency resolves at runtime → kext works perfectly.

## Key Files

```
docker-macos/
├── Dockerfile                          # Builds from qemu-mos15 fork
├── launch.sh                           # QEMU launch with vgamem_mb=256
├── opencore15.img                      # 512MB FAT32, OpenCore + SystemKC
├── DISCOVERY.md                        # All findings (53 entries)
├── TODO.md                             # Remaining tasks
├── kexts/
│   ├── QEMUDisplay/
│   │   ├── src/QEMUDisplay.cpp         # The display driver
│   │   ├── src/QEMUDisplay.hpp         # Class declaration
│   │   ├── src/kmod_info.c             # Module info
│   │   ├── Info.plist                  # Bundle config
│   │   └── build/QEMUDisplay.kext/     # Built kext
│   └── deps/
│       ├── OpenCorePkg/                # Forked OpenCore with System KC support
│       ├── MacKernelSDK/               # Kernel SDK for cross-compilation
│       └── SystemKernelExtensions.kc   # Extracted from VM
```

## Build Commands

### QEMUDisplay kext (on ARM Mac):
```bash
KERN_SDK="kexts/deps/MacKernelSDK"
xcrun -sdk macosx clang -target x86_64-apple-macos10.15 -arch x86_64 \
  -fno-builtin -fno-common -fno-stack-protector -mkernel -nostdlib -nostdinc \
  -DKERNEL -DKERNEL_PRIVATE -I"$KERN_SDK/Headers" -w \
  -c src/kmod_info.c -o build/kmod_info.o
xcrun -sdk macosx clang++ -target x86_64-apple-macos10.15 -arch x86_64 -std=c++17 \
  -fno-rtti -fno-exceptions -fno-builtin -fno-common -fno-stack-protector \
  -mkernel -nostdlib -nostdinc -nostdinc++ \
  -DKERNEL -DKERNEL_PRIVATE -I"$KERN_SDK/Headers" -w \
  -c src/QEMUDisplay.cpp -o build/QEMUDisplay.o
xcrun -sdk macosx clang++ -target x86_64-apple-macos10.15 -arch x86_64 -nostdlib \
  -Xlinker -kext -Xlinker -no_data_const -Xlinker -no_source_version \
  -L"$KERN_SDK/Library/x86_64" build/QEMUDisplay.o build/kmod_info.o -lkmod \
  -o build/QEMUDisplay.kext/Contents/MacOS/QEMUDisplay
```

### QEMU mos15 (in Alpine container on server):
```bash
docker run --rm -v /tmp:/output alpine:3.21 sh -c "
  apk add build-base python3 ninja meson pkgconf glib-dev pixman-dev ...
  curl QEMU 10.2.2 tarball + qemu-mos15 patches
  cp patched files over originals
  configure + ninja -j$(nproc)
  cp build/qemu-system-x86_64 /output/qemu-mos15
"
```

### OpenCore mos15 (on ARM Mac):
```bash
cd kexts/deps/OpenCorePkg
ARCHS=(X64) ./build_oc.tool
# Output: UDK/Build/OpenCorePkg/DEBUG_XCODE5/X64/OpenCore.efi
```

## Manual Kext Install Cycle (Sequoia)

MUST follow this exact cycle — Sequoia's AuxKC caching breaks if you skip steps:

1. `sudo rm -rf /Library/Extensions/QEMUDisplay.kext && sudo rm -f /Library/KernelCollections/AuxiliaryKernelExtensions.kc`
2. Reboot to stock desktop (may need double reboot for OpenCore)
3. `scp` kext to VM, `chown root:wheel`, `cp` to `/Library/Extensions/`, `kextcache -i /`
4. Approve in System Settings → Privacy & Security
5. Reboot

## Infrastructure

- **Server:** classe (Dell R730, Ubuntu 24.04, 72 cores, 220GB RAM)
- **VM:** Portainer stack "macos" (ID 64), 24 cores, 24GB RAM
- **VM SSH:** matthew@10.1.7.20 (key auth, passwordless sudo)
- **QEMU binary:** /data/macos/qemu-mos15 (bind-mounted into container)
- **OpenCore image:** /data/macos/opencore15.img (512MB FAT32, bind-mounted)
- **Portainer API:** ptr_f8I/jLRmscKjCcA7vbq1DebmTr++3GKxzOYrT07QECo=

## Options for Solving Injection

1. **Automate manual install via Docker** — startup script copies kext to /Library/Extensions, pre-populates kext policy DB, reboots. Two-boot process but fully automated.

2. **Rewrite kext as IOService (not IOFramebuffer subclass)** — use Lilu-style runtime patching. No System KC dependency. Unproven, significant rewrite.

3. **Implement Aux KC injection in OpenCore** — would require OpenCore to write kext files to the Data volume during EFI boot, or intercept kernel-phase file reads. Significant OpenCore changes.

4. **Build custom AuxKC in Docker** — pre-build the AuxKC with our kext baked in, include in the macOS disk image. Version-locked to specific macOS build.

5. **Implement cross-KC stub trampolines in OpenCore** — generate 64-bit jump stubs for relocations that overflow 32-bit displacement. Would need to account for KASLR slide difference between Boot KC and System KC.

6. **DriverKit extension** — rewrite as a DriverKit driver instead of a kext. No injection needed, installed via app. But DriverKit has limited IOKit access and may not support IOFramebuffer.
