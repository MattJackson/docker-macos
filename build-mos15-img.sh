#!/bin/bash
# Build a mos15 image — bootable EFI volume that loads macOS 15 (Sequoia)
# in our forked QEMU. mos15 = qemu-mos15 + opencore-mos15 + lilu-mos15 + Sequoia.
#
# Inputs (everything that defines what's running):
#   efi/                                                       tracked — config.plist, ACPI, Drivers, Resources, OC/BOOT EFIs
#   kexts/deps/Lilu-mos15-DEBUG.kext                           built from MattJackson/lilu-mos15
#   kexts/QEMUDisplayPatcher/build/QEMUDisplayPatcher.kext     built from kexts/QEMUDisplayPatcher/
#   $SYSTEM_KC                                                 System KC (349MB, version-locked to macOS 15.7.5).
#                                                              Default: ~/mos-staging/SystemKernelExtensions.kc
#                                                              Long-term: pulled from private mos repo at build time.
#
# Output:
#   builds/mos15_YYYYMMDDHHMMSS.img    timestamped, gitignored, reproducible from inputs
#   mos15.img -> builds/<latest>       symlink to most recent build (gitignored)
#
# TODO: BOOTx64.efi, OpenCore.efi, Drivers/, Resources/ should eventually come from
# an opencore-mos15 source build, not from a one-time production extract. Tracked in
# efi/ for now so the pipeline reproduces today's running state.

set -euo pipefail

cd "$(dirname "$0")"

MP_KEXT="kexts/deps/mos15-patcher.kext"
QDP_KEXT="kexts/QEMUDisplayPatcher/build/QEMUDisplayPatcher.kext"
METAL_KEXT="kexts/mos15-metal/build/mos15-metal.kext"
SYSTEM_KC="${SYSTEM_KC:-$HOME/mos-staging/SystemKernelExtensions.kc}"
SIZE_MB=512
BASELINE="${BASELINE:-0}"  # BASELINE=1 → no Lilu, no QDP, OEM IONDRV unhooked

STAMP=$(date +%Y%m%d%H%M%S)
SUFFIX=""
[ "$BASELINE" = "1" ] && SUFFIX="_baseline"
mkdir -p builds
OUT="builds/mos15_${STAMP}${SUFFIX}.img"
LATEST="mos15.img"

REQUIRED=(efi "$SYSTEM_KC")
[ "$BASELINE" = "1" ] || REQUIRED+=("$MP_KEXT" "$QDP_KEXT" "$METAL_KEXT")
for f in "${REQUIRED[@]}"; do
    [ -e "$f" ] || { echo "missing input: $f"; exit 1; }
done

echo "==> Creating blank ${SIZE_MB}MB FAT32 image"
dd if=/dev/zero of="$OUT" bs=1m count=$SIZE_MB status=none

echo "==> Attaching"
DEV=$(hdiutil attach -nomount "$OUT" | head -1 | awk '{print $1}')
trap "hdiutil detach $DEV >/dev/null 2>&1 || true" EXIT
echo "    device: $DEV"

echo "==> Formatting FAT32 (volume name MOS15)"
newfs_msdos -F 32 -v MOS15 "$DEV" >/dev/null

echo "==> Mounting"
MNT=$(mktemp -d)
mount -t msdos "$DEV" "$MNT"
trap "diskutil unmount '$MNT' >/dev/null 2>&1 || true; hdiutil detach $DEV >/dev/null 2>&1 || true; rmdir '$MNT' 2>/dev/null || true" EXIT

echo "==> Copying tracked EFI inputs"
cp -R efi/EFI "$MNT/"
mkdir -p "$MNT/EFI/OC/Kexts" "$MNT/EFI/OC/Tools"

if [ "$BASELINE" = "1" ]; then
    echo "==> BASELINE: disabling mos15-patcher + QEMUDisplayPatcher in config.plist"
    python3 - "$MNT/EFI/OC/config.plist" <<'PY'
import sys, re
p = sys.argv[1]
src = open(p).read()
def disable(text, bundle):
    pat = re.compile(
        r'(<dict>(?:(?!</dict>).)*?<string>' + re.escape(bundle) + r'</string>'
        r'(?:(?!</dict>).)*?<key>Enabled</key>\s*)<true/>',
        re.S
    )
    new, n = pat.subn(r'\1<false/>', text)
    if n != 1: raise SystemExit(f"failed to disable {bundle}: matched {n} times")
    return new
for b in ('Lilu.kext', 'mos15-patcher.kext', 'QEMUDisplayPatcher.kext', 'mos15-metal.kext'):
    try: src = disable(src, b)
    except SystemExit as e: print(f"    note: {e}")
open(p, 'w').write(src)
print("    BASELINE config written")
PY
else
    echo "==> Copying built kexts"
    cp -R "$MP_KEXT" "$MNT/EFI/OC/Kexts/"
    cp -R "$QDP_KEXT" "$MNT/EFI/OC/Kexts/"
    cp -R "$METAL_KEXT" "$MNT/EFI/OC/Kexts/"
fi

echo "==> Copying System KC (349MB)"
cp "$SYSTEM_KC" "$MNT/EFI/OC/SystemKernelExtensions.kc"

echo "==> Unmounting"
sync
diskutil unmount "$MNT" >/dev/null
hdiutil detach "$DEV" >/dev/null
rmdir "$MNT"
trap - EXIT

echo "==> Updating $LATEST symlink"
ln -sf "$OUT" "$LATEST"

echo
echo "Built: $OUT"
ls -lh "$OUT"
md5 "$OUT"
