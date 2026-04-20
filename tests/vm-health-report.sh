#!/bin/bash
# vm-health-report.sh — post-boot introspection bundler. Gathers
# everything an operator needs to attach to a bug report or a
# triage thread AFTER the VM is SSH-reachable.
#
# What it captures (all into <output-dir>/):
#   From the VM (via SSH):
#     dmesg-last1000.log      — tail of kernel message buffer
#     ioreg-all.log           — full IOKit registry (`ioreg -l`)
#     ioreg-appleparavirtgpu.log — `ioreg -l -c AppleParavirtGPU`
#     ps-auxc.log             — `ps auxc`
#     log-show-kernel-5m.log  — `log show --predicate subsystem==kernel`
#     system-profiler.log     — `system_profiler SPDisplaysDataType`
#     metal-probe.log         — output of tests/metal-probe if deployed
#   From the host (via SSH to DOCKER_HOST):
#     docker-ps.log           — `docker ps` (all containers)
#     docker-logs-tail500.log — last 500 lines of the container stdout
#   Local (the machine this script runs on):
#     repo-shas.txt           — git HEADs of all 5 known mos-* repos
#     capture-meta.txt        — VM, DOCKER_HOST, timestamps
#
# The whole directory is then tar.gz'd as
#   <output-dir>/vm-health-report-<stamp>.tar.gz
# which is the single artefact operators attach to bug reports.
#
# Usage:
#   VM=user@vm_host ./tests/vm-health-report.sh <output-dir>
#
# Required env:
#   VM            ssh target for the macOS guest
#
# Optional env:
#   DOCKER_HOST   ssh target for the docker host. If unset, host-side
#                 artefacts are skipped with a warning.
#   CONTAINER     docker container name (default: macos-macos-1)
#   REPOS         colon-separated list of local repo paths for SHA
#                 capture. Default: the five known mos repo roots.
#   METAL_PROBE   path on the VM to a built metal-probe binary
#                 (default: /tmp/metal-probe — will be skipped if absent)
#
# Exit codes:
#   0   — bundle produced (even if some sub-captures were skipped)
#   1   — VM unreachable
#   2   — output dir invalid / cannot write tarball
#   3   — tar invocation failed
#
# Dependencies:
#   - bash, ssh, tar, gzip, date, stat.
#   - jq optional (not used here, but same reminder as analyze-boot-log).
#   - Install on host: `brew install jq gzip`; Alpine: `apk add tar gzip jq`.

set -u

VM="${VM:-}"
OUTPUT_DIR="${1:-}"
DOCKER_HOST="${DOCKER_HOST:-}"
CONTAINER="${CONTAINER:-macos-macos-1}"
METAL_PROBE="${METAL_PROBE:-/tmp/metal-probe}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"

# Default repo list. Edit REPOS env to override.
DEFAULT_REPOS="/Users/mjackson/libapplegfx-vulkan:/Users/mjackson/qemu-mos15:/Users/mjackson/docker-macos:/Users/mjackson/mos:/Users/mjackson/mos-opencore"
REPOS="${REPOS:-$DEFAULT_REPOS}"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

if [ -z "$VM" ] || [ -z "$OUTPUT_DIR" ]; then
    usage
    echo "missing VM or output-dir" >&2
    exit 2
fi

# ---- Pre-flight -------------------------------------------------------------
step "0/4 — pre-flight"
if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "VM $VM unreachable via SSH"
    exit 1
fi
pass "VM $VM reachable"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BUNDLE_DIR="$OUTPUT_DIR/vm-health-report-$STAMP"
if ! mkdir -p "$BUNDLE_DIR"; then
    fail "cannot create $BUNDLE_DIR"
    exit 2
fi
pass "bundle dir: $BUNDLE_DIR"

# Capture metadata first so we have something even if everything else fails.
{
    echo "stamp=$STAMP"
    echo "vm=$VM"
    echo "docker_host=$DOCKER_HOST"
    echo "container=$CONTAINER"
    echo "script=$0"
    echo "host_uname=$(uname -a)"
    echo "host_date=$(date -u)"
} > "$BUNDLE_DIR/capture-meta.txt"

# ---- Guest-side captures ---------------------------------------------------
step "1/4 — guest-side captures"

# dmesg: last 1000 lines. macOS's dmesg is gated behind sudo.
ssh $SSH_OPTS "$VM" "sudo -n dmesg 2>/dev/null | tail -1000" \
    > "$BUNDLE_DIR/dmesg-last1000.log" 2>&1 || \
    warn "dmesg capture failed (sudo -n may not be configured on VM)"

# ioreg -l: full registry. Large (~hundreds of KB).
ssh $SSH_OPTS "$VM" "ioreg -l 2>/dev/null" \
    > "$BUNDLE_DIR/ioreg-all.log" 2>&1 \
    && pass "ioreg -l captured ($(wc -l < "$BUNDLE_DIR/ioreg-all.log") lines)" \
    || warn "ioreg -l failed"

# ioreg -c AppleParavirtGPU: narrow to our device.
ssh $SSH_OPTS "$VM" "ioreg -l -c AppleParavirtGPU 2>/dev/null" \
    > "$BUNDLE_DIR/ioreg-appleparavirtgpu.log" 2>&1
if [ -s "$BUNDLE_DIR/ioreg-appleparavirtgpu.log" ]; then
    pass "ioreg -c AppleParavirtGPU captured"
else
    warn "ioreg -c AppleParavirtGPU returned empty — kext may not have attached"
fi

# ps auxc: running processes.
ssh $SSH_OPTS "$VM" "ps auxc 2>/dev/null" \
    > "$BUNDLE_DIR/ps-auxc.log" 2>&1 \
    && pass "ps auxc captured" \
    || warn "ps auxc failed"

# log show last 5m on kernel subsystem. Expensive; guard with sudo -n.
ssh $SSH_OPTS "$VM" \
    "sudo -n log show --last 5m --predicate 'subsystem == \"com.apple.kernel\"' 2>/dev/null" \
    > "$BUNDLE_DIR/log-show-kernel-5m.log" 2>&1
if [ -s "$BUNDLE_DIR/log-show-kernel-5m.log" ]; then
    pass "log show (kernel, 5m) captured"
else
    warn "log show empty — sudo -n may not be wired on VM"
fi

# system_profiler SPDisplaysDataType: display config.
ssh $SSH_OPTS "$VM" "system_profiler SPDisplaysDataType 2>/dev/null" \
    > "$BUNDLE_DIR/system-profiler-displays.log" 2>&1 \
    && pass "SPDisplaysDataType captured" \
    || warn "system_profiler failed"

# kextstat: loaded kexts — useful cross-ref for AppleParavirtGPU.
ssh $SSH_OPTS "$VM" "kextstat 2>/dev/null" \
    > "$BUNDLE_DIR/kextstat.log" 2>&1 || true

# who: is there a console-login user? (auto-login invariant)
ssh $SSH_OPTS "$VM" "who 2>/dev/null" \
    > "$BUNDLE_DIR/who.log" 2>&1 || true

# Optional: run metal-probe if it's been deployed to the VM.
if ssh $SSH_OPTS "$VM" "test -x $METAL_PROBE" 2>/dev/null; then
    ssh $SSH_OPTS "$VM" "sudo -n launchctl asuser 501 $METAL_PROBE 2>&1" \
        > "$BUNDLE_DIR/metal-probe.log" 2>&1 \
        && pass "metal-probe ran" \
        || warn "metal-probe present but invocation failed"
else
    warn "metal-probe not at $METAL_PROBE on VM — skipping"
fi

# ---- Host-side captures ----------------------------------------------------
step "2/4 — host-side captures"
if [ -z "$DOCKER_HOST" ]; then
    warn "DOCKER_HOST unset — skipping host-side captures"
else
    if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
        warn "DOCKER_HOST $DOCKER_HOST unreachable — skipping host-side captures"
    else
        ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker ps --all --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Command}}' 2>&1" \
            > "$BUNDLE_DIR/docker-ps.log" 2>&1 \
            && pass "docker ps captured" \
            || warn "docker ps failed"
        ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs --tail 500 $CONTAINER 2>&1" \
            > "$BUNDLE_DIR/docker-logs-tail500.log" 2>&1 \
            && pass "docker logs tail 500 captured ($(wc -l < "$BUNDLE_DIR/docker-logs-tail500.log") lines)" \
            || warn "docker logs tail failed"
        # QEMU cmdline from /proc/1 — for verifying -device apple-gfx-pci is live.
        ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER sh -c 'cat /proc/1/cmdline | tr \"\\0\" \" \"' 2>&1" \
            > "$BUNDLE_DIR/qemu-cmdline.txt" 2>&1 || true
        # Host identity.
        {
            echo "# host uname"
            ssh $SSH_OPTS "$DOCKER_HOST" "uname -a" 2>&1 || true
            echo
            echo "# vulkaninfo --summary"
            ssh $SSH_OPTS "$DOCKER_HOST" "vulkaninfo --summary 2>&1 | head -40" 2>&1 || true
        } > "$BUNDLE_DIR/host-identity.log"
        pass "host identity captured"
    fi
fi

# ---- Local repo SHAs -------------------------------------------------------
step "3/4 — repo SHAs"
SHAS_FILE="$BUNDLE_DIR/repo-shas.txt"
> "$SHAS_FILE"
OLDIFS=$IFS
IFS=':'
for repo in $REPOS; do
    IFS=$OLDIFS
    if [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; then
        SHA=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "unknown")
        BRANCH=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        DIRTY=""
        if ! git -C "$repo" diff --quiet 2>/dev/null; then
            DIRTY=" (dirty)"
        fi
        echo "$repo  $BRANCH  $SHA$DIRTY" >> "$SHAS_FILE"
    else
        echo "$repo  (not a git repo)" >> "$SHAS_FILE"
    fi
    IFS=':'
done
IFS=$OLDIFS
pass "repo SHAs captured ($(wc -l < "$SHAS_FILE") entries)"

# ---- Bundle ----------------------------------------------------------------
step "4/4 — bundling"
TARBALL="$OUTPUT_DIR/vm-health-report-$STAMP.tar.gz"
if ! tar -czf "$TARBALL" -C "$OUTPUT_DIR" "$(basename "$BUNDLE_DIR")" 2>/dev/null; then
    fail "tar invocation failed"
    exit 3
fi
BUNDLE_SIZE=$(stat -f '%z' "$TARBALL" 2>/dev/null || stat -c '%s' "$TARBALL" 2>/dev/null || echo "?")
pass "bundle: $TARBALL (${BUNDLE_SIZE} bytes)"

echo
echo "attach this file to the bug report: $TARBALL"
echo "raw bundle dir (preserved): $BUNDLE_DIR"
exit 0
