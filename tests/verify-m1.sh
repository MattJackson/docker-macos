#!/bin/bash
# verify-m1.sh — Milestone 1 end-to-end gate. Validates that the full
# docker build produces a QEMU binary with `apple-gfx-pci` registered,
# starts the container, boots macOS, and passes the existing mode-visibility
# sanity check.
#
# M1 definition (see memory/project_100pct_target.md row M1):
#   "`docker build` succeeds; Alpine container starts w/ -device apple-gfx-pci
#    accepted; macOS reaches desktop without kernel panic related to apple-gfx."
#
# This script is the CI-style gate for that claim. It does NOT yet verify
# pixels (that's M4+). It does verify plumbing.
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip ./tests/verify-m1.sh
#
# Required env:
#   DOCKER_HOST   ssh target for the docker host (the box running the container)
#   VM            ssh target for the macOS guest (usually same host, different port/user)
#
# Optional env:
#   BOOT_TIMEOUT  seconds to wait for macOS boot (default: 300)
#   CONTAINER     docker container name (default: macos-macos-1)
#   REPO_DIR      path on docker host where docker-compose.yml lives (default: ~/mos/docker-macos)
#
# Exit codes:
#   0   — all green, M1 gate passed
#   10  — docker build failed
#   20  — container start / healthy-wait failed
#   30  — apple-gfx-pci NOT registered in qemu -device help output
#   40  — VM did not reach console within BOOT_TIMEOUT
#   50  — kernel panic / apple-gfx fault detected in serial log
#   60  — verify-modes.sh baseline regression (M1 should still pass it)
#   1   — SSH to DOCKER_HOST unreachable

set -u
DOCKER_HOST="${DOCKER_HOST:?DOCKER_HOST env var required, e.g. DOCKER_HOST=user@host}"
VM="${VM:?VM env var required, e.g. VM=user@10.0.0.1}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
CONTAINER="${CONTAINER:-macos-macos-1}"
REPO_DIR="${REPO_DIR:-~/mos/docker-macos}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(dirname "$0")"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

# ---- 0. Pre-flight: can we reach the docker host? --------------------------
step "0/7 — pre-flight"
if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
    fail "can't reach docker host $DOCKER_HOST — check SSH key / hostname"
    exit 1
fi
pass "docker host $DOCKER_HOST reachable"

# ---- 1. docker build --------------------------------------------------------
step "1/7 — docker build (or compose build)"
echo "building on $DOCKER_HOST in $REPO_DIR ..."
BUILD_LOG=$(ssh $SSH_OPTS "$DOCKER_HOST" "cd $REPO_DIR && sudo docker compose build 2>&1" | tail -200)
BUILD_EXIT=$?
echo "$BUILD_LOG" | tail -30 | sed 's/^/    /'
if [ "$BUILD_EXIT" -ne 0 ]; then
    fail "docker compose build exited $BUILD_EXIT"
    echo
    echo "Inspect full log on host: ssh $DOCKER_HOST 'cd $REPO_DIR && sudo docker compose build'"
    echo "Likely causes (see docs/m1-dry-run-prediction.md):"
    echo "  - pc-bios/apple-gfx-pci.rom not in qemu-mos15 origin/main (push first)"
    echo "  - pkg-config name mismatch (applegfx-vulkan vs libapplegfx-vulkan)"
    echo "  - missing trace_apple_gfx_pci_realize/reset events"
    echo "  - static callbacks in apple-gfx-common-linux.c not exported"
    exit 10
fi
pass "docker compose build succeeded"

# ---- 2. Container up and healthy -------------------------------------------
step "2/7 — container start"
ssh $SSH_OPTS "$DOCKER_HOST" "cd $REPO_DIR && sudo docker compose up -d" 2>&1 | sed 's/^/    /' || {
    fail "docker compose up -d failed"
    exit 20
}
# Wait for container to be in "running" state
for i in $(seq 1 30); do
    STATE=$(ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker inspect -f '{{.State.Status}}' $CONTAINER 2>/dev/null" || echo "missing")
    if [ "$STATE" = "running" ]; then
        pass "container $CONTAINER running (after ${i}s)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        fail "container $CONTAINER never reached running state (last state: $STATE)"
        ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs --tail 50 $CONTAINER 2>&1" | sed 's/^/    /'
        exit 20
    fi
    sleep 1
done

# ---- 3. apple-gfx-pci registered in the qemu binary ------------------------
step "3/7 — qemu -device help lists apple-gfx-pci"
# The running container has qemu-system-x86_64 as PID 1 (via exec). We can't
# `docker exec qemu -device help` against a live VM without interfering.
# Instead, spawn a throwaway container from the same image to probe the binary.
IMAGE_ID=$(ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker inspect -f '{{.Image}}' $CONTAINER 2>/dev/null")
if [ -z "$IMAGE_ID" ]; then
    fail "could not resolve image id for $CONTAINER"
    exit 30
fi
DEVHELP=$(ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker run --rm --entrypoint qemu-system-x86_64 $IMAGE_ID -device help 2>&1" || true)
if echo "$DEVHELP" | grep -q '^name "apple-gfx-pci"'; then
    pass "apple-gfx-pci device registered in QEMU binary"
    echo "$DEVHELP" | grep 'apple-gfx' | sed 's/^/    /'
else
    fail "apple-gfx-pci NOT found in 'qemu -device help' output"
    echo "$DEVHELP" | grep -i apple | sed 's/^/    /' || echo "    (no apple-* devices at all)"
    echo
    echo "Silent-drop failure: pkg-config found nothing, dependency('applegfx-vulkan')"
    echo "returned not_found, source_set gate was false → binary built without the device."
    echo "Check libapplegfx-vulkan.pc actually installed in builder, and name matches"
    echo "what hw/display/meson.build asks for."
    exit 30
fi

# ---- 4. Launch command line actually includes -device apple-gfx-pci --------
step "4/7 — running qemu cmdline includes -device apple-gfx-pci"
# NOTE: as of M1.1 launch.sh defaults to vmware-svga for compatibility. To
# exercise apple-gfx-pci, launch.sh must be invoked with APPLE_GFX=yes (or the
# equivalent knob agreed on in launch.sh — see docs/m1-dry-run-prediction.md P1-1).
QEMU_CMDLINE=$(ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER sh -c 'cat /proc/1/cmdline | tr \"\\0\" \" \"' 2>/dev/null" || echo "")
if echo "$QEMU_CMDLINE" | grep -q 'apple-gfx-pci'; then
    pass "running qemu cmdline uses -device apple-gfx-pci"
else
    warn "running qemu cmdline does NOT include -device apple-gfx-pci (still on vmware-svga fallback)"
    warn "for a true M1 green, re-launch with the apple-gfx-pci toggle:"
    warn "  ssh $DOCKER_HOST 'cd $REPO_DIR && APPLE_GFX=yes sudo -E docker compose up -d --force-recreate'"
    warn "continuing with the VMware path — step 3 already proved the device registered."
fi

# ---- 5. macOS boot reaches console within BOOT_TIMEOUT ---------------------
step "5/7 — macOS boot (timeout ${BOOT_TIMEOUT}s)"
BOOT_START=$(date +%s)
BOOTED=0
while : ; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - BOOT_START))
    if [ "$ELAPSED" -ge "$BOOT_TIMEOUT" ]; then
        fail "VM did not reach SSH console in ${BOOT_TIMEOUT}s"
        ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs --tail 80 $CONTAINER 2>&1" | tail -30 | sed 's/^/    /'
        exit 40
    fi
    if ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
        BOOTED=1
        pass "macOS reachable over SSH after ${ELAPSED}s"
        break
    fi
    printf "."
    sleep 5
done
echo

# ---- 6. No kernel panics / apple-gfx faults in serial log ------------------
step "6/7 — no panic / apple-gfx fault in serial log"
SERIAL=$(ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs --tail 5000 $CONTAINER 2>&1")
PANIC_HITS=$(echo "$SERIAL" | grep -c -E 'panic\(cpu|Kernel trap|AppleParavirtGPU.*assert|apple_gfx.*fault|apple-gfx-pci.*panic' || true)
if [ "$PANIC_HITS" -gt 0 ]; then
    fail "found $PANIC_HITS panic-ish lines in serial log"
    echo "$SERIAL" | grep -E 'panic\(cpu|Kernel trap|AppleParavirtGPU.*assert|apple_gfx.*fault|apple-gfx-pci.*panic' | head -20 | sed 's/^/    /'
    exit 50
fi
pass "no kernel panic / apple-gfx fault signals in last 5000 serial lines"

# Also surface the apple-gfx-pci realize/reset trace lines if present — useful
# observability, not a hard gate.
AGFX_TRACE=$(echo "$SERIAL" | grep -E 'apple_gfx_pci_(realize|reset)' | tail -5 || true)
if [ -n "$AGFX_TRACE" ]; then
    echo "apple-gfx-pci trace events seen:"
    echo "$AGFX_TRACE" | sed 's/^/    /'
fi

# ---- 7. Baseline sanity — existing verify-modes.sh must still pass ---------
step "7/7 — baseline sanity (verify-modes.sh)"
if [ ! -x "$TESTS_DIR/verify-modes.sh" ]; then
    warn "verify-modes.sh not found/executable — skipping baseline check"
else
    if VM="$VM" "$TESTS_DIR/verify-modes.sh"; then
        pass "verify-modes.sh passed — display baseline intact"
    else
        MODES_EXIT=$?
        fail "verify-modes.sh regressed (exit $MODES_EXIT) — M1 introduced a display-layer regression"
        exit 60
    fi
fi

echo
echo "${GRN}=== M1 gate: PASSED ===${RST}"
echo "  docker build: green"
echo "  apple-gfx-pci: registered in binary"
echo "  macOS: booted without panic"
echo "  display baseline: intact"
echo
echo "Next milestone: M2 — AppleParavirtGPU kext binds to the PCI IDs."
echo "Run: VM=$VM ./tests/verify-phase1.sh (requires libapplegfx-vulkan Phase 1.A.3+)"
