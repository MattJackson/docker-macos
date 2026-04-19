#!/bin/bash
# verify-modes.sh — post-boot assertion that the display hook is taking
# effect at every layer: kernel vtable → hook invocation → CoreGraphics
# enumeration. Run AFTER the VM reaches desktop (auto-login required).
#
# Usage:
#   VM=user@host ./tests/verify-modes.sh    # required: VM ssh target
#
# Exit codes:
#   0 — every check passed
#   1 — SSH unreachable / VM not booted
#   2 — hook coverage incomplete (MPMethodsMissing > 0)
#   3 — EDID identity mismatch
#   4 — mode we advertise missing from CoreGraphics enumeration
#   5 — a patched hook was never invoked by macOS

set -u
VM="${VM:?VM env var required, e.g. VM=user@10.0.0.1}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
BIN_SRC="$(dirname "$0")/list-modes"

# ---- Expected state (update when QDP's modes[] / EDID change) --------------
# Modes we advertise AND expect macOS to surface in CoreGraphics.
EXPECTED_MODES_VISIBLE=(
    "1920x1080"
    "2560x1440"
    "3840x2160"
    "3008x1692"
    "2048x1152"
    "1680x945"
    "1280x720"
)
# Modes we advertise that macOS currently filters out due to LAYERS BELOW US.
# Each entry is "mode:reason". If one of these starts appearing, it's not a
# regression — it's a sign that the upstream block lifted (e.g. QEMU patched).
EXPECTED_MODES_UPSTREAM_BLOCKED=(
    "5120x2880:QEMU vmware-svga device caps resolution ~3840x2160; 5K requires patching hw/display/vmware_vga.c"
)
EXPECTED_DISPLAY_VENDOR=1552      # 0x0610 — Apple PnP "APP"
EXPECTED_DISPLAY_PRODUCT=44593    # 0xAE31 — iMac20,1 built-in Retina 5K
EXPECTED_METHODS_TOTAL=24
# ----------------------------------------------------------------------------

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}✓${RST} $1"; }
fail() { echo "${RED}✗${RST} $1"; }
warn() { echo "${YEL}!${RST} $1"; }

# ---- 1. VM reachable --------------------------------------------------------
if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "can't reach $VM — VM not booted or SSH key missing"
    exit 1
fi
pass "VM reachable over SSH"

# ---- 2. User is actually logged in (auto-login or manual) ------------------
if ! ssh $SSH_OPTS "$VM" "who" | grep -q console; then
    fail "no user logged into the console — auto-login not configured, CG APIs won't work"
    exit 1
fi
pass "console user logged in — CG bootstrap available"

# ---- 3. Hook coverage (mos15-patcher published via ioreg) ------------------
IOREG=$(ssh $SSH_OPTS "$VM" "ioreg -c IONDRVFramebuffer -l 2>/dev/null")
HOOKED=$(echo "$IOREG" | awk -F'= ' '/"MPMethodsHooked"/{print $2}' | tr -d '"')
MISSING=$(echo "$IOREG" | awk -F'= ' '/"MPMethodsMissing"/{print $2}' | tr -d '"')
TOTAL=$(echo "$IOREG" | awk -F'= ' '/"MPMethodsTotal"/{print $2}' | tr -d '"')
if [ "${HOOKED:-0}" = "$EXPECTED_METHODS_TOTAL" ] && [ "${MISSING:-99}" = "0" ]; then
    pass "hook coverage: ${HOOKED}/${TOTAL} methods, 0 gaps"
else
    fail "hook coverage: hooked=$HOOKED total=$TOTAL missing=$MISSING"
    echo "$IOREG" | grep -E '"MPMethodGaps"|"MPStatus"'
    exit 2
fi

# ---- 4. EDID identity matches injected bytes -------------------------------
IOREG_ALL=$(ssh $SSH_OPTS "$VM" "ioreg -l 2>/dev/null")
VENDOR=$(echo "$IOREG_ALL" | awk -F'= ' '/"DisplayVendorID"/{print $2; exit}' | tr -d '"')
PRODUCT=$(echo "$IOREG_ALL" | awk -F'= ' '/"DisplayProductID"/{print $2; exit}' | tr -d '"')
if [ "${VENDOR:-0}" = "$EXPECTED_DISPLAY_VENDOR" ] && [ "${PRODUCT:-0}" = "$EXPECTED_DISPLAY_PRODUCT" ]; then
    pass "EDID identity: vendor=$VENDOR product=$PRODUCT (iMac20,1 APP/0xAE31)"
else
    fail "EDID identity: vendor=$VENDOR product=$PRODUCT (expected $EXPECTED_DISPLAY_VENDOR/$EXPECTED_DISPLAY_PRODUCT)"
    exit 3
fi

# ---- 5. Every critical hook fired at least once (per serial log) ----------
LOGS=$(ssh $SSH_OPTS docker "sudo docker logs --tail 5000 macos-macos-1 2>&1" | grep -E "^QDP: " || true)
MISSING_HOOKS=()
for hook in enableController hasDDCConnect getDDCBlock getDisplayModeCount getDisplayModes getInformationForDisplayMode; do
    if echo "$LOGS" | grep -q "QDP: $hook"; then
        pass "hook fired: $hook"
    else
        fail "hook NEVER fired: $hook"
        MISSING_HOOKS+=("$hook")
    fi
done
if [ ${#MISSING_HOOKS[@]} -gt 0 ]; then
    exit 5
fi

# ---- 6. CoreGraphics enumeration — every mode we push must be visible ------
# Uses the list-modes binary (compiled from tests/list-modes.m on the host).
# Requires the VM to have a console user logged in (checked above).
if [ ! -x "$BIN_SRC" ]; then
    warn "$BIN_SRC not compiled — run: (cd tests && clang -arch x86_64 -framework Foundation -framework CoreGraphics -framework CoreVideo list-modes.m -o list-modes)"
else
    scp -q $SSH_OPTS "$BIN_SRC" "$VM:/tmp/" 2>/dev/null
    MODES=$(ssh $SSH_OPTS "$VM" "sudo -n launchctl asuser 501 /tmp/list-modes 2>/dev/null" | awk '/[0-9]+x[0-9]+ @/{print $1}')
    if [ -z "$MODES" ]; then
        fail "list-modes returned nothing — CG session attach failed"
        exit 5
    fi
    echo "CG-enumerated modes:"
    echo "$MODES" | sed 's/^/    /'

    # Expected-visible modes MUST appear
    MISSING_FROM_CG=()
    for m in "${EXPECTED_MODES_VISIBLE[@]}"; do
        if echo "$MODES" | grep -qx "$m"; then
            pass "mode visible in CoreGraphics: $m"
        else
            fail "mode MISSING from CoreGraphics: $m"
            MISSING_FROM_CG+=("$m")
        fi
    done
    if [ ${#MISSING_FROM_CG[@]} -gt 0 ]; then
        warn "regression — previously-visible modes are gone: ${MISSING_FROM_CG[*]}"
        exit 4
    fi

    # Upstream-blocked modes should STAY blocked. If one appears, it's not a
    # failure — it's a signal the upstream (QEMU, macOS version) changed.
    UNBLOCKED=()
    for entry in "${EXPECTED_MODES_UPSTREAM_BLOCKED[@]}"; do
        m="${entry%%:*}"
        reason="${entry#*:}"
        if echo "$MODES" | grep -qx "$m"; then
            warn "mode newly visible (upstream block lifted): $m — re-check $reason"
            UNBLOCKED+=("$m")
        else
            pass "mode stays upstream-blocked (as expected): $m"
        fi
    done
    if [ ${#UNBLOCKED[@]} -gt 0 ]; then
        warn "consider moving these from EXPECTED_MODES_UPSTREAM_BLOCKED to EXPECTED_MODES_VISIBLE"
    fi
fi

# ---- 7. VRAM -------------------------------------------------------------
SP_OUT=$(ssh $SSH_OPTS "$VM" "system_profiler SPDisplaysDataType 2>/dev/null")
VRAM=$(echo "$SP_OUT" | awk '/VRAM/{print $3, $4}')
pass "VRAM: $VRAM"

# ---- 8. system_profiler shows a full iMac panel (not just "GPU") ----------
# Before the full hook set, SPDisplaysDataType showed only the GPU line — no
# display subtree. Now macOS reports the panel, HiDPI, depth, and serial.
# Any one of these checks failing means the display-panel recognition path
# has regressed.
for needle in \
    "iMac:" \
    "Display Type: LCD" \
    "UI Looks like:" \
    "Main Display: Yes" \
    "Online: Yes" \
    "984D8CB20332A" ; do
    if echo "$SP_OUT" | grep -qF "$needle"; then
        pass "SPDisplays reports: $needle"
    else
        fail "SPDisplays MISSING: $needle"
        echo "$SP_OUT"
        exit 4
    fi
done

echo
echo "${GRN}=== all display checks passed ===${RST}"
