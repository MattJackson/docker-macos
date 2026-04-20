#!/bin/bash
# metal-kext-loaded.sh — gating test introduced by Phase -1.A.3.
# Asserts that mos15-metal.kext was actually loaded (not dropped by
# OpenCore / prelinked injection), and that its start() IOLog
# breadcrumb hit the kernel log.
#
# Usage:
#   VM=user@host ./tests/metal-kext-loaded.sh
#
# Exit codes:
#   0 — kext loaded + start breadcrumb seen
#   1 — VM unreachable
#   2 — kext not present in kextstat
#   3 — kext present but start() IOLog not seen (load-but-not-started)

set -u
VM="${VM:?VM env var required, e.g. VM=matthew@10.1.7.20}"
DOCKER_HOST_SSH="${DOCKER_HOST_SSH:-docker}"
CONTAINER="${CONTAINER:-macos-macos-1}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
IDENT="com.docker-macos.kext.mos15Metal"
BREADCRUMB="mos15-metal: start"

RED=$(printf '\033[0;31m'); GRN=$(printf '\033[0;32m'); RST=$(printf '\033[0m')
pass() { echo "${GRN}✓${RST} $1"; }
fail() { echo "${RED}✗${RST} $1"; }

if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "can't reach $VM"
    exit 1
fi
pass "VM reachable"

KEXTSTAT=$(ssh $SSH_OPTS "$VM" "kextstat 2>&1 | grep -F '$IDENT'" || true)
if [ -z "$KEXTSTAT" ]; then
    fail "$IDENT not in kextstat — OpenCore dropped it or prelinked-inject failed"
    exit 2
fi
pass "kextstat: $(echo "$KEXTSTAT" | awk '{print $6, $7}')"

# Serial log from the container — kernel IOLog lands on stdout via QEMU -serial
BREAD=$(ssh $SSH_OPTS "$DOCKER_HOST_SSH" "sudo docker logs --tail 5000 $CONTAINER 2>&1 | grep -F '$BREADCRUMB'" || true)
if [ -z "$BREAD" ]; then
    fail "kext loaded but '$BREADCRUMB' breadcrumb missing — start() never fired"
    exit 3
fi
pass "start breadcrumb: $(echo "$BREAD" | head -1)"

echo
echo "${GRN}=== mos15-metal kext loaded and started ===${RST}"
