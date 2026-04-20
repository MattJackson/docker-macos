#!/bin/bash
# run-all.sh — top-level verify runner. Invokes every verify-*.sh in
# milestone order and reports which milestones are green.
#
# Order matters: each step's prerequisite is the previous step's pass.
# If a step fails, subsequent steps are still attempted (they'll usually
# fail too, but the aggregate report is useful for seeing where the cliff is).
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip ./tests/run-all.sh
#
# Env:
#   DOCKER_HOST  ssh target for docker host (required for M1+ scripts)
#   VM           ssh target for macOS guest (required for all scripts)
#   SKIP_M1      1 = skip verify-m1.sh (e.g. when M1 already green, iterate faster)
#
# Exit codes:
#   0   — every invoked script exited 0
#   1   — one or more scripts failed; see per-milestone lines

set -u
TESTS_DIR="$(dirname "$0")"
DOCKER_HOST="${DOCKER_HOST:-}"
VM="${VM:?VM env var required, e.g. VM=user@10.0.0.1}"
SKIP_M1="${SKIP_M1:-0}"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
BLD=$(printf '\033[1m')
RST=$(printf '\033[0m')

declare -a RESULTS=()

run_one() {
    local label="$1"
    local script="$2"
    shift 2
    echo
    echo "${BLD}${BLU}########## $label — $script ##########${RST}"
    if [ ! -x "$TESTS_DIR/$script" ]; then
        echo "${YEL}SKIP${RST} $script not executable"
        RESULTS+=("SKIP  $label  ($script not executable)")
        return 0
    fi
    if "$TESTS_DIR/$script" "$@"; then
        RESULTS+=("${GRN}PASS${RST}  $label")
        return 0
    else
        local ec=$?
        RESULTS+=("${RED}FAIL${RST}  $label  (exit $ec)")
        return $ec
    fi
}

FAILED=0

# ---- Baseline: display path intact (verify-modes) --------------------------
# This isn't a milestone per se — it's the ongoing "we didn't break display"
# regression gate. Every run confirms it.
run_one "Baseline display (verify-modes)" "verify-modes.sh" || FAILED=1

# ---- Phase 1 gate: Metal device enumeration + empty cmdbuf ----------------
# This maps to M3 in the milestone table — metal-no-op round trip.
run_one "Phase 1 / M3 (Metal no-op)" "verify-phase1.sh" || FAILED=1

# ---- M1: docker build green + apple-gfx-pci in binary ---------------------
if [ "$SKIP_M1" = "1" ]; then
    echo "${YEL}SKIP${RST} M1 (SKIP_M1=1)"
    RESULTS+=("SKIP  M1  (SKIP_M1=1)")
elif [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M1 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M1  (DOCKER_HOST not set)")
else
    run_one "M1 (docker build + apple-gfx-pci)" "verify-m1.sh" || FAILED=1
fi

# ---- M6 scaffold: login screen ---------------------------------------------
if [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M6 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M6 scaffold  (DOCKER_HOST not set)")
else
    run_one "M6 scaffold (login screen)" "verify-login-screen.sh" || FAILED=1
fi

# ---- M7 scaffold: desktop idle ---------------------------------------------
if [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M7 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M7 scaffold  (DOCKER_HOST not set)")
else
    run_one "M7 scaffold (desktop idle)" "verify-desktop-idle.sh" || FAILED=1
fi

# ---- Aggregate report ------------------------------------------------------
echo
echo "${BLD}########## run-all summary ##########${RST}"
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo

if [ "$FAILED" -eq 0 ]; then
    echo "${GRN}ALL GREEN${RST}"
    exit 0
else
    echo "${RED}ONE OR MORE FAILED${RST}"
    exit 1
fi
