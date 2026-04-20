#!/bin/bash
# capture-boot-log.sh — kick off a fresh VM boot and capture everything
# the serial console / container emits, stopping at a configurable set
# of triggers (SSH up, panic pattern matched, or timeout).
#
# Why this exists:
#   Today the only way to know a VM boot "worked" is to SSH in after it
#   is up. During the boot itself we have no record of what happened —
#   no OpenCore trace, no kernel printk stream, no kext-load log, no
#   panic backtrace if the VM died mid-init. This script captures all
#   of that into a per-run artefact directory, stops at the first
#   deterministic trigger, and hands the directory off to
#   tests/analyze-boot-log.sh.
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip \
#       ./tests/capture-boot-log.sh [--timeout 300] [--out-dir <dir>]
#
# Required env:
#   DOCKER_HOST   ssh target for the docker host
#
# Optional env / flags:
#   VM            ssh target for the macOS guest (used by SSH-up trigger).
#                 If unset, the SSH-up trigger is disabled and capture
#                 runs until panic or timeout.
#   --timeout N   seconds before the "timeout" trigger fires (default 300).
#                 Also overridable via TIMEOUT env.
#   --out-dir D   capture directory root (default: tests/capture-boot-logs).
#                 Also overridable via OUT_DIR env.
#   CONTAINER     docker container name (default: macos-macos-1)
#   REPO_DIR      path on docker host where docker-compose.yml lives
#                 (default: ~/mos/docker-macos)
#   NO_RESTART    1 = skip `docker compose restart` / up; attach to a
#                 container that is already running. Use for "analyze
#                 THIS boot" rather than "kick a fresh boot".
#   SERIAL_PATH   path inside the container where launch.sh is (or will
#                 be) writing a serial-console log. If set and the file
#                 exists, we tail it alongside docker logs. If unset,
#                 capture-boot-log falls back to docker logs only —
#                 which captures QEMU stdout (OpenCore + kernel printk
#                 land there today).
#
# Integration with run-all.sh:
#   run-all.sh can invoke this script as a first step before any
#   verify-*.sh to snapshot the boot. If this script detects a panic
#   or timeout, the corresponding capture directory is the
#   first-artefact for a bug report (paired with vm-health-report.sh
#   after a good boot, or alone on a bad one).
#
# Exit codes:
#   0   — boot reached SSH (or --no-ssh-wait and no panic before timeout)
#   10  — panic pattern matched (see tests/patterns/panic.patterns)
#   20  — timeout reached before SSH came up and no panic seen
#   30  — capture setup failed (no DOCKER_HOST / cannot reach host / etc.)
#
# Artefacts written to <out-dir>/<timestamp>/:
#   serial.log       — QEMU stdout / serial capture
#   docker.log       — `docker logs` full dump (container lifecycle)
#   trigger.txt      — one-word reason capture stopped (ssh / panic / timeout)
#   duration-sec.txt — wall-clock seconds capture ran
#   status.txt       — good / panic / timeout (matches trigger semantics)
#   panic-line.txt   — (on panic) the matching line + regex that tripped

set -u

# ---- Arg + env parsing ------------------------------------------------------
TIMEOUT_DEFAULT=300
TIMEOUT="${TIMEOUT:-$TIMEOUT_DEFAULT}"
OUT_DIR="${OUT_DIR:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)
            TIMEOUT="${2:-$TIMEOUT_DEFAULT}"; shift 2 ;;
        --out-dir)
            OUT_DIR="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "unknown arg: $1" >&2; exit 30 ;;
    esac
done

DOCKER_HOST="${DOCKER_HOST:-}"
VM="${VM:-}"
CONTAINER="${CONTAINER:-macos-macos-1}"
REPO_DIR="${REPO_DIR:-~/mos/docker-macos}"
NO_RESTART="${NO_RESTART:-0}"
SERIAL_PATH="${SERIAL_PATH:-}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$TESTS_DIR/capture-boot-logs"
fi

# Color helpers (same palette as verify-*.sh)
RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

# ---- Pre-flight -------------------------------------------------------------
step "0/4 — pre-flight"
if [ -z "$DOCKER_HOST" ]; then
    fail "DOCKER_HOST env var required (e.g. DOCKER_HOST=user@host)"
    exit 30
fi
if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
    fail "cannot reach docker host $DOCKER_HOST via SSH"
    exit 30
fi
pass "docker host $DOCKER_HOST reachable"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CAP_DIR="$OUT_DIR/$STAMP"
if ! mkdir -p "$CAP_DIR"; then
    fail "cannot create capture directory $CAP_DIR"
    exit 30
fi
pass "capture dir: $CAP_DIR"

SERIAL_LOG="$CAP_DIR/serial.log"
DOCKER_LOG="$CAP_DIR/docker.log"
TRIGGER_FILE="$CAP_DIR/trigger.txt"
DURATION_FILE="$CAP_DIR/duration-sec.txt"
STATUS_FILE="$CAP_DIR/status.txt"
PANIC_LINE_FILE="$CAP_DIR/panic-line.txt"
META_FILE="$CAP_DIR/capture-meta.txt"

{
    echo "capture_stamp=$STAMP"
    echo "docker_host=$DOCKER_HOST"
    echo "vm=$VM"
    echo "container=$CONTAINER"
    echo "repo_dir=$REPO_DIR"
    echo "timeout=$TIMEOUT"
    echo "no_restart=$NO_RESTART"
    echo "serial_path=$SERIAL_PATH"
    echo "tests_dir=$TESTS_DIR"
} > "$META_FILE"

# ---- Load panic patterns ----------------------------------------------------
PATTERNS_FILE="$TESTS_DIR/patterns/panic.patterns"
if [ ! -f "$PATTERNS_FILE" ]; then
    warn "panic.patterns missing at $PATTERNS_FILE — panic trigger disabled"
    PANIC_REGEX=""
else
    # Build a single alt-group regex from fatal rows only. Columns are
    # <category>|<severity>|<regex>|<description>. We want column 3 when
    # column 2 == "fatal".
    PANIC_REGEX=$(awk -F'|' '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $2 == "fatal" {
            if (out == "") { out = $3 } else { out = out "|" $3 }
        }
        END { print out }
    ' "$PATTERNS_FILE")
    if [ -z "$PANIC_REGEX" ]; then
        warn "panic.patterns had no fatal rows — panic trigger disabled"
    else
        PATTERN_COUNT=$(echo "$PANIC_REGEX" | awk -F'|' '{print NF}')
        pass "loaded $PATTERN_COUNT fatal panic patterns"
    fi
fi

# ---- (Optional) kick a fresh boot -------------------------------------------
step "1/4 — container state"
if [ "$NO_RESTART" = "1" ]; then
    warn "NO_RESTART=1 — attaching to an already-running container"
else
    ssh $SSH_OPTS "$DOCKER_HOST" "cd $REPO_DIR && sudo docker compose up -d 2>&1 | tail -20" \
        | sed 's/^/    /' || true
    # Force a fresh boot only if the container is running: `up -d` alone
    # is a no-op when the container exists, so issue a restart so our
    # capture starts from kernel-load time-0.
    STATE=$(ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker inspect -f '{{.State.Status}}' $CONTAINER 2>/dev/null" || echo "missing")
    case "$STATE" in
        running)
            ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker restart $CONTAINER" >/dev/null 2>&1 \
                || warn "docker restart failed — capture will include prior run"
            ;;
        missing)
            fail "container $CONTAINER does not exist on $DOCKER_HOST"
            echo "timeout" > "$TRIGGER_FILE"
            echo "30" > "$STATUS_FILE"
            exit 30
            ;;
        *)
            warn "container state '$STATE' — not running; attempting start"
            ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker start $CONTAINER" >/dev/null 2>&1 || true
            ;;
    esac
    pass "container state: $STATE (fresh boot requested)"
fi

# ---- Kick off captures ------------------------------------------------------
step "2/4 — capture start (timeout=${TIMEOUT}s)"
START_TS=$(date +%s)
> "$SERIAL_LOG"
> "$DOCKER_LOG"

# docker logs -f runs as the primary capture. It grabs QEMU stdout,
# which is where OpenCore and the kernel printk stream land.
ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs -f --tail 0 $CONTAINER 2>&1" \
    > "$DOCKER_LOG" &
DOCKER_LOGS_PID=$!

# Optional secondary tail: if launch.sh is writing a dedicated serial
# log inside the container, pick it up. Gracefully no-op if absent.
SERIAL_TAIL_PID=""
if [ -n "$SERIAL_PATH" ]; then
    # Probe once; if it's not there yet, don't block — the file may
    # appear later as launch.sh comes up.
    ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER sh -c 'test -e $SERIAL_PATH'" \
        >/dev/null 2>&1 && HAS_SERIAL=1 || HAS_SERIAL=0
    if [ "$HAS_SERIAL" = "1" ]; then
        ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER sh -c 'tail -F $SERIAL_PATH'" \
            > "$SERIAL_LOG" 2>/dev/null &
        SERIAL_TAIL_PID=$!
        pass "tailing serial file $SERIAL_PATH inside container"
    else
        warn "SERIAL_PATH $SERIAL_PATH not present — serial.log will mirror docker.log"
    fi
fi

cleanup() {
    [ -n "${DOCKER_LOGS_PID:-}" ] && kill "$DOCKER_LOGS_PID" 2>/dev/null || true
    [ -n "${SERIAL_TAIL_PID:-}" ] && kill "$SERIAL_TAIL_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pass "capture running (docker logs pid=$DOCKER_LOGS_PID)"

# ---- Poll for a stop trigger ------------------------------------------------
step "3/4 — watching for stop triggers"
TRIGGER=""
PANIC_LINE=""
SSH_POLL_EVERY=5   # seconds between SSH-reachability probes
LAST_SSH_POLL=0

while : ; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        TRIGGER="timeout"
        break
    fi

    # If the serial tail produced no file, fall back to the docker log
    # as our serial source for panic detection.
    if [ ! -s "$SERIAL_LOG" ] && [ -s "$DOCKER_LOG" ]; then
        # Mirror docker log to serial log so the pattern scan and
        # downstream analyze-boot-log.sh find something under serial.log.
        cp "$DOCKER_LOG" "$SERIAL_LOG" 2>/dev/null || true
    fi

    # Panic trigger: scan BOTH logs on each tick.
    if [ -n "$PANIC_REGEX" ]; then
        # Use grep -m1 so we stop at the first hit; scan serial first
        # because kernel printk gets there directly.
        for f in "$SERIAL_LOG" "$DOCKER_LOG"; do
            [ -s "$f" ] || continue
            HIT=$(grep -E -m1 "$PANIC_REGEX" "$f" 2>/dev/null || true)
            if [ -n "$HIT" ]; then
                PANIC_LINE="$HIT"
                TRIGGER="panic"
                break 2
            fi
        done
    fi

    # SSH-up trigger: only if VM is set. Poll every SSH_POLL_EVERY sec
    # (not every tick — SSH ConnectTimeout is 5s, which costs real time).
    if [ -n "$VM" ] && [ $((NOW - LAST_SSH_POLL)) -ge "$SSH_POLL_EVERY" ]; then
        LAST_SSH_POLL=$NOW
        if ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
            TRIGGER="ssh"
            break
        fi
    fi

    sleep 1
done

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
echo "$DURATION" > "$DURATION_FILE"

# ---- Finalize ---------------------------------------------------------------
step "4/4 — trigger: $TRIGGER (elapsed ${DURATION}s)"
cleanup
# Give background tails one last flush:
sleep 1

echo "$TRIGGER" > "$TRIGGER_FILE"
case "$TRIGGER" in
    ssh)
        echo "good" > "$STATUS_FILE"
        pass "SSH reachable after ${DURATION}s — capture stopped with status=good"
        EXIT_CODE=0
        ;;
    panic)
        echo "panic" > "$STATUS_FILE"
        if [ -n "$PANIC_LINE" ]; then
            {
                echo "regex: $PANIC_REGEX"
                echo "line: $PANIC_LINE"
            } > "$PANIC_LINE_FILE"
        fi
        fail "panic pattern matched at ${DURATION}s"
        [ -n "$PANIC_LINE" ] && echo "    $PANIC_LINE"
        EXIT_CODE=10
        ;;
    timeout)
        echo "timeout" > "$STATUS_FILE"
        warn "timeout (${TIMEOUT}s) reached without SSH or panic"
        EXIT_CODE=20
        ;;
    *)
        echo "unknown" > "$STATUS_FILE"
        fail "capture loop exited with unknown trigger: $TRIGGER"
        EXIT_CODE=30
        ;;
esac

# If serial.log is still empty but docker.log has content, copy as a
# final fallback so downstream analysis finds the capture where it
# expects it.
if [ ! -s "$SERIAL_LOG" ] && [ -s "$DOCKER_LOG" ]; then
    cp "$DOCKER_LOG" "$SERIAL_LOG" 2>/dev/null || true
fi

echo
echo "capture dir: $CAP_DIR"
echo "  serial.log:  $(wc -l < "$SERIAL_LOG" 2>/dev/null || echo 0) lines"
echo "  docker.log:  $(wc -l < "$DOCKER_LOG" 2>/dev/null || echo 0) lines"
echo "  trigger:     $TRIGGER"
echo "  status:      $(cat "$STATUS_FILE")"
echo "  duration:    ${DURATION}s"
echo
echo "next: ./tests/analyze-boot-log.sh $CAP_DIR"

exit "$EXIT_CODE"
