#!/bin/bash
# verify-desktop-idle.sh — M7 scaffold.
#
# M7 definition (memory/project_100pct_target.md row M7):
#   "Dock + menu bar + windows render without corruption at 1080p."
#
# ==== SCAFFOLD STATUS ========================================================
# Same structure as verify-login-screen.sh (M6). The infrastructure for
# capturing + diffing a framebuffer snapshot is real. The visual assertion is
# scaffolded because:
#   - Phase 3 Metal->Vulkan translation isn't emitting pixels yet; the diff
#     path can only be exercised once it does.
#   - tests/screenshots/reference/desktop-idle.png doesn't exist. It will be
#     captured the first time we see a clean Dock + menu-bar at 1080p under
#     our stack (not VMware-SVGA fallback). See tests/screenshots/README.md.
#
# What this script DOES verify today:
#   1. VM reachable + auto-logged-in console user (prerequisite for the Dock)
#   2. Dock + WindowServer processes are running — macOS did initialize the UI
#   3. Framebuffer screenshot is capturable
#
# What this script WILL verify once Phase 3 lands:
#   4. compare_screenshot against tests/screenshots/reference/desktop-idle.png
#      within tolerance. Flip GATE_ON_DIFF=1 once reference exists.
# =============================================================================
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip ./tests/verify-desktop-idle.sh
#
# Env:
#   DOCKER_HOST   ssh target for the docker host (required)
#   VM            ssh target for the macOS guest (required)
#   CONTAINER     docker container name (default: macos-macos-1)
#   IDLE_WAIT     seconds to wait for UI to settle before snap (default: 10)
#   GATE_ON_DIFF  1 = fail when diff > tolerance (default: 0)
#   TOLERANCE     mean per-channel delta allowed (default: 20)
#
# Exit codes:
#   0   — asserted checks passed
#   1   — SSH unreachable
#   10  — WindowServer or Dock not running
#   20  — framebuffer capture failed
#   30  — screenshot diff exceeded tolerance (gated behind GATE_ON_DIFF=1)
#   40  — reference image missing AND GATE_ON_DIFF=1

set -u
DOCKER_HOST="${DOCKER_HOST:?DOCKER_HOST env var required}"
VM="${VM:?VM env var required}"
CONTAINER="${CONTAINER:-macos-macos-1}"
IDLE_WAIT="${IDLE_WAIT:-10}"
GATE_ON_DIFF="${GATE_ON_DIFF:-0}"
TOLERANCE="${TOLERANCE:-20}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(dirname "$0")"
SHOT_DIR="$TESTS_DIR/screenshots"
REF_DIR="$SHOT_DIR/reference"
STAMP=$(date +%Y-%m-%d_%H%M%S)
SHOT_OUT="$SHOT_DIR/${STAMP}-desktop-idle.png"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

mkdir -p "$SHOT_DIR" "$REF_DIR"

# Helpers identical in shape to verify-login-screen.sh. Duplicated rather than
# sourced so each script stands alone and an operator running one doesn't need
# to know about the other.

take_screenshot() {
    local out="$1"
    if ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER which vncsnapshot >/dev/null 2>&1"; then
        ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER vncsnapshot -quiet 127.0.0.1::5901 /tmp/shot.png" 2>/dev/null \
            && ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker cp $CONTAINER:/tmp/shot.png - " \
                | tar -xO > "$out" 2>/dev/null \
            && [ -s "$out" ] && return 0
    fi
    warn "vncsnapshot unavailable in container — falling back to macOS-side screencapture"
    ssh $SSH_OPTS "$VM" "screencapture -x /tmp/shot.png" 2>/dev/null \
        && scp -q $SSH_OPTS "$VM:/tmp/shot.png" "$out" 2>/dev/null \
        && [ -s "$out" ] && return 0
    return 1
}

compare_screenshot() {
    local actual="$1"
    local ref="$2"
    if ! command -v compare >/dev/null 2>&1; then
        echo "skip:imagemagick-compare-missing"
        return 0
    fi
    if [ ! -f "$ref" ]; then
        echo "skip:reference-missing"
        return 0
    fi
    local raw
    raw=$(compare -metric MAE "$actual" "$ref" null: 2>&1 | awk -F'[()]' '{print $2}')
    local mean
    mean=$(awk -v r="$raw" 'BEGIN { printf "%d\n", r * 255 }')
    echo "$mean"
}

# ---- 0. Pre-flight ----------------------------------------------------------
step "0/5 — pre-flight"
if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "VM $VM unreachable"
    exit 1
fi
pass "VM $VM reachable"
if ! ssh $SSH_OPTS "$VM" "who" | grep -q console; then
    fail "no console user — auto-login required for M7 (Dock/UI won't render headless)"
    exit 1
fi
pass "console user logged in"

# ---- 1. WindowServer + Dock running (UI initialized) -----------------------
step "1/5 — WindowServer + Dock running"
for proc in WindowServer Dock; do
    if ssh $SSH_OPTS "$VM" "pgrep -x $proc >/dev/null 2>&1"; then
        pass "$proc running"
    else
        fail "$proc NOT running — desktop UI not initialized"
        exit 10
    fi
done

# ---- 2. Let UI settle before snapping --------------------------------------
step "2/5 — idle wait (${IDLE_WAIT}s)"
sleep "$IDLE_WAIT"
pass "idle wait elapsed"

# ---- 3. Screenshot capture --------------------------------------------------
step "3/5 — framebuffer screenshot"
if take_screenshot "$SHOT_OUT"; then
    SZ=$(stat -f%z "$SHOT_OUT" 2>/dev/null || stat -c%s "$SHOT_OUT" 2>/dev/null)
    pass "screenshot: $SHOT_OUT ($SZ bytes)"
else
    fail "screenshot capture failed — see verify-login-screen.sh for strategy details"
    exit 20
fi

# ---- 4. Diff against reference (SCAFFOLD) ----------------------------------
step "4/5 — diff against reference (SCAFFOLD — gated on Phase 3)"
REF_IMG="$REF_DIR/desktop-idle.png"
DIFF_RESULT=$(compare_screenshot "$SHOT_OUT" "$REF_IMG" "$TOLERANCE")

case "$DIFF_RESULT" in
    skip:reference-missing)
        warn "reference image MISSING: $REF_IMG"
        warn "capture it after Phase 3 lands a clean desktop at 1080p:"
        warn "  cp '$SHOT_OUT' '$REF_IMG' && git add '$REF_IMG'"
        if [ "$GATE_ON_DIFF" -eq 1 ]; then
            fail "GATE_ON_DIFF=1 but reference missing"
            exit 40
        fi
        ;;
    skip:imagemagick-compare-missing)
        warn "ImageMagick 'compare' missing — install with: brew install imagemagick"
        ;;
    *)
        if [ "$DIFF_RESULT" -le "$TOLERANCE" ]; then
            pass "desktop matches reference (delta=$DIFF_RESULT, tolerance=$TOLERANCE)"
        else
            if [ "$GATE_ON_DIFF" -eq 1 ]; then
                fail "desktop diverges from reference (delta=$DIFF_RESULT > $TOLERANCE)"
                echo "    inspect: $SHOT_OUT  vs  $REF_IMG"
                exit 30
            else
                warn "desktop delta=$DIFF_RESULT > tolerance=$TOLERANCE (ungated — GATE_ON_DIFF=0)"
            fi
        fi
        ;;
esac

# ---- 5. Scaffold report -----------------------------------------------------
step "5/5 — scaffold report"
echo "  M7 scaffold infrastructure: OK"
echo "  Real visual-diff assertion: BLOCKED on Phase 3 + reference capture"
echo
echo "  Today's assertion: WindowServer + Dock are running, framebuffer capture"
echo "  pipeline is functional. The visual diff becomes meaningful the day"
echo "  Phase 3 emits a first non-corrupt desktop through our stack."
echo
echo "${GRN}=== verify-desktop-idle scaffold: PASSED ===${RST}"
