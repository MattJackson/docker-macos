#!/bin/bash
# verify-login-screen.sh — M6 scaffold.
#
# M6 definition (memory/project_100pct_target.md row M6):
#   "loginwindow's CALayer compositing through our stack; Apple login visible
#    at 1080p."
#
# ==== SCAFFOLD STATUS ========================================================
# This script is a SCAFFOLD. Its infrastructure (screenshot capture, reference-
# image diffing, loginwindow-process detection) is real. The visual assertion
# it performs is NOT end-to-end yet because:
#   - Phase 3 (Metal->Vulkan translation) hasn't produced pixels yet. Until it
#     does, the framebuffer we screenshot is the VMware-SVGA fallback path, not
#     our apple-gfx-pci + libapplegfx-vulkan stack.
#   - tests/screenshots/reference/login.png does NOT exist yet. It will be
#     captured manually the first time Phase 3 paints a login screen. See
#     tests/screenshots/README.md for the reference-capture workflow.
#
# What this script DOES verify today (the real parts):
#   1. VM reachable + console user logged in (prerequisite)
#   2. loginwindow process is running in the VM (proves macOS reached the
#      loginwindow stage, even if we can't yet assert WHAT it drew)
#   3. Framebuffer screenshot is capturable (proves the capture pipeline works
#      end-to-end, so when Phase 3 pixels land, the diff step is a one-liner)
#
# What this script WILL verify once Phase 3 lands:
#   4. compare_screenshot against tests/screenshots/reference/login.png within
#      an allowed per-pixel delta. When (4) starts working, flip GATE_ON_DIFF
#      below from 0 to 1.
# =============================================================================
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip ./tests/verify-login-screen.sh
#
# Env:
#   DOCKER_HOST   ssh target for the docker host (required)
#   VM            ssh target for the macOS guest (required)
#   CONTAINER     docker container name (default: macos-macos-1)
#   GATE_ON_DIFF  1 = fail when screenshot diff exceeds tolerance (default: 0
#                 while scaffolded; flip to 1 when reference image exists)
#   TOLERANCE     allowed mean per-channel delta (default: 20)  — PHASE 3
#
# Exit codes:
#   0   — all asserted checks passed
#   1   — SSH unreachable
#   10  — loginwindow not running in VM
#   20  — framebuffer capture failed (noVNC/virsh/docker path broken)
#   30  — screenshot diff above tolerance (Phase 3 only; gated behind
#          GATE_ON_DIFF=1 until reference image is captured)
#   40  — reference image missing AND GATE_ON_DIFF=1 (operator error)

set -u
DOCKER_HOST="${DOCKER_HOST:?DOCKER_HOST env var required}"
VM="${VM:?VM env var required}"
CONTAINER="${CONTAINER:-macos-macos-1}"
GATE_ON_DIFF="${GATE_ON_DIFF:-0}"
TOLERANCE="${TOLERANCE:-20}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(dirname "$0")"
SHOT_DIR="$TESTS_DIR/screenshots"
REF_DIR="$SHOT_DIR/reference"
STAMP=$(date +%Y-%m-%d_%H%M%S)
SHOT_OUT="$SHOT_DIR/${STAMP}-login.png"

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

# ---- helpers ----------------------------------------------------------------

# take_screenshot <output-path>
# Captures the current macOS framebuffer as PNG. Strategy: VM is driven via
# QEMU's VNC server on the docker host (127.0.0.1:5901 by default). We use
# `docker exec` into the container to snap via a VNC client. If that's not
# available, fall back to ssh-into-VM + screencapture, which requires console
# login and does NOT prove the display path — it proves macOS can draw to its
# own framebuffer. When Phase 3 lands, prefer the VNC-side path because that's
# what the user actually sees through noVNC.
#
# Strategy matrix (preferred → fallback):
#   A. ssh DOCKER_HOST → docker exec CONTAINER → vncsnapshot 127.0.0.1::5901 out.png
#      (requires vncsnapshot installed in the container image; NOT yet installed)
#   B. ssh DOCKER_HOST → sudo apk add --no-cache vncsnapshot in container → A
#      (mutates image; acceptable in CI, avoid in prod)
#   C. ssh VM → screencapture /tmp/out.png → scp back
#      (proves macOS-side rendering only, not the display path through noVNC)
take_screenshot() {
    local out="$1"
    # Try (A) first.
    if ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER which vncsnapshot >/dev/null 2>&1"; then
        ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER vncsnapshot -quiet 127.0.0.1::5901 /tmp/shot.png" 2>/dev/null \
            && ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker cp $CONTAINER:/tmp/shot.png - " \
                | tar -xO > "$out" 2>/dev/null \
            && [ -s "$out" ] && return 0
    fi
    # Fallback (C) — needs screen unlocked; doesn't test the display path.
    warn "vncsnapshot unavailable in container — falling back to macOS-side screencapture"
    warn "this bypasses the display path and only verifies macOS self-render. Install vncsnapshot in the docker image for a real M6 screenshot."
    ssh $SSH_OPTS "$VM" "screencapture -x /tmp/shot.png" 2>/dev/null \
        && scp -q $SSH_OPTS "$VM:/tmp/shot.png" "$out" 2>/dev/null \
        && [ -s "$out" ] && return 0
    return 1
}

# compare_screenshot <actual.png> <reference.png> <tolerance>
# Returns mean per-channel absolute delta (0=identical, 255=inverted). Uses
# ImageMagick's `compare -metric MAE` because it's ubiquitous and gives a
# scalar suitable for threshold gating. Caller compares the returned int
# against its tolerance.
#
# Dependency: ImageMagick `compare`. If absent on the host running this
# script, function returns "skip" and the caller degrades gracefully.
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
    # MAE returns a "normalized (0..1)" value and a raw value in parens.
    # Parse the raw integer 0..65535 → scale to 0..255 for readability.
    local raw
    raw=$(compare -metric MAE "$actual" "$ref" null: 2>&1 | awk -F'[()]' '{print $2}')
    # raw is 0..1 normalized; multiply by 255 for channel-mean.
    local mean
    mean=$(awk -v r="$raw" 'BEGIN { printf "%d\n", r * 255 }')
    echo "$mean"
}

# ---- 0. Pre-flight ----------------------------------------------------------
step "0/4 — pre-flight"
if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "VM $VM unreachable"
    exit 1
fi
pass "VM $VM reachable"
if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
    fail "docker host $DOCKER_HOST unreachable"
    exit 1
fi
pass "docker host $DOCKER_HOST reachable"

# ---- 1. loginwindow process is running --------------------------------------
step "1/4 — loginwindow process in VM"
if ssh $SSH_OPTS "$VM" "pgrep -x loginwindow >/dev/null 2>&1"; then
    pass "loginwindow process running"
else
    fail "loginwindow NOT running — macOS hasn't reached the login-screen stage"
    ssh $SSH_OPTS "$VM" "ps aux | head -20" | sed 's/^/    /'
    exit 10
fi

# ---- 2. Screenshot capture (infrastructure test) ----------------------------
step "2/4 — framebuffer screenshot capture"
if take_screenshot "$SHOT_OUT"; then
    SZ=$(stat -f%z "$SHOT_OUT" 2>/dev/null || stat -c%s "$SHOT_OUT" 2>/dev/null)
    pass "screenshot captured: $SHOT_OUT ($SZ bytes)"
else
    fail "screenshot capture failed — all strategies exhausted"
    echo "    A (vncsnapshot in container): failed/absent"
    echo "    C (macOS screencapture):      failed/absent"
    echo
    echo "    To enable strategy A, add 'vncsnapshot' to the Dockerfile's runtime apk install."
    exit 20
fi

# ---- 3. Diff against reference (SCAFFOLD — gated until Phase 3) -------------
step "3/4 — diff against reference (SCAFFOLD)"
REF_IMG="$REF_DIR/login.png"
DIFF_RESULT=$(compare_screenshot "$SHOT_OUT" "$REF_IMG" "$TOLERANCE")

case "$DIFF_RESULT" in
    skip:reference-missing)
        warn "reference image MISSING: $REF_IMG"
        warn "capture it after Phase 3 lands a known-good login screen:"
        warn "  cp '$SHOT_OUT' '$REF_IMG' && git add '$REF_IMG' && git commit -m 'tests: M6 reference login screenshot'"
        if [ "$GATE_ON_DIFF" -eq 1 ]; then
            fail "GATE_ON_DIFF=1 but reference image missing — cannot gate"
            exit 40
        fi
        ;;
    skip:imagemagick-compare-missing)
        warn "ImageMagick 'compare' missing on this host — diff unavailable"
        warn "install: brew install imagemagick  (or apk add imagemagick)"
        ;;
    *)
        if [ "$DIFF_RESULT" -le "$TOLERANCE" ]; then
            pass "screenshot matches reference (delta=$DIFF_RESULT, tolerance=$TOLERANCE)"
        else
            if [ "$GATE_ON_DIFF" -eq 1 ]; then
                fail "screenshot diverges from reference (delta=$DIFF_RESULT > tolerance=$TOLERANCE)"
                echo "    inspect: $SHOT_OUT  vs  $REF_IMG"
                exit 30
            else
                warn "screenshot delta=$DIFF_RESULT > tolerance=$TOLERANCE (not gated — GATE_ON_DIFF=0)"
            fi
        fi
        ;;
esac

# ---- 4. Scaffold report -----------------------------------------------------
step "4/4 — scaffold report"
echo "  M6 scaffold infrastructure: OK"
echo "  Real visual-diff assertion: BLOCKED on Phase 3 pixel path + reference capture"
echo
echo "  Until then, this script asserts: macOS reached the loginwindow process"
echo "  AND the screenshot pipeline works. That's enough to prove we won't be"
echo "  debugging capture infrastructure on the day Phase 3 lands."
echo
echo "${GRN}=== verify-login-screen scaffold: PASSED ===${RST}"
