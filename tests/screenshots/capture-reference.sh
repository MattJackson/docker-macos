#!/bin/bash
# capture-reference.sh — promote a live VM framebuffer to a committed
# reference image for verify-m4 / verify-login-screen / verify-desktop-idle.
#
# This is an OPERATOR-FACING script. It is not invoked by CI. The operator
# runs it once per milestone, once the corresponding verify-*.sh scaffold
# shows a visually-correct capture. It lives alongside the verify-*.sh
# scripts' take_screenshot() helper but writes into
# tests/screenshots/reference/<milestone>.png so the per-run scripts can
# diff against it.
#
# ==== WHY THIS EXISTS ========================================================
# verify-m4.sh / verify-login-screen.sh / verify-desktop-idle.sh each rely
# on a known-good reference image. Those references are produced by human
# judgement on the first pass:
#   1. Operator boots VM to the target state (first-pixel, login, idle desk).
#   2. Operator visually confirms the screen looks right.
#   3. Operator runs this script to snapshot and promote the image.
#   4. Operator commits the reference. Future verify-*.sh runs diff against it.
#
# This script handles steps 3 only — capture + atomic write + metadata.
# The visual confirmation in (2) is the operator's job and cannot be
# automated (that's the whole point of having a reference).
# =============================================================================
#
# Usage:
#   ./tests/screenshots/capture-reference.sh <milestone> "<description>" [options]
#
# Positional args:
#   <milestone>      one of: clear-color-red | login | desktop-idle
#   <description>    free-form text stored in capture-metadata.txt
#
# Options:
#   --force          overwrite an existing reference image
#   --method=NAME    capture method: vncsnapshot | xvfb | qemu-monitor
#                    (default: auto — try vncsnapshot, then qemu-monitor,
#                    then xvfb)
#   --out=PATH       override output path (default:
#                    tests/screenshots/reference/<milestone>.png)
#
# Required env (same conventions as verify-*.sh):
#   DOCKER_HOST      ssh target for the docker host
#   VM               ssh target for the macOS guest (only for xvfb fallback)
#
# Optional env:
#   CONTAINER        docker container name (default: macos-macos-1)
#   VNC_PORT         QEMU VNC port inside container (default: 5901)
#   MONITOR_SOCKET   path to QEMU monitor unix socket inside container
#                    (default: /tmp/qemu-monitor.sock)
#   NOVNC_PORT       port noVNC listens on (default: 6080)
#
# Exit codes:
#   0   — reference captured + metadata written
#   1   — argument error (missing milestone / bad milestone name)
#   2   — required env var missing
#   3   — reference exists and --force not given
#   10  — SSH to DOCKER_HOST failed
#   20  — all capture methods failed
#   30  — capture produced zero-byte or truncated PNG
#   40  — metadata write failed
#
# Examples:
#   # First-pass M4 reference after Phase 2.B lands red pixels:
#   DOCKER_HOST=user@host ./tests/screenshots/capture-reference.sh \
#       clear-color-red "first red frame through apple-gfx-pci + lavapipe"
#
#   # Re-capture M6 after a macOS point update changed the wallpaper:
#   DOCKER_HOST=user@host VM=admin@10.0.0.5 \
#     ./tests/screenshots/capture-reference.sh login "macOS 15.5 login UI" --force
#
#   # Force the qemu-monitor path (skips VNC client entirely):
#   DOCKER_HOST=user@host ./tests/screenshots/capture-reference.sh \
#       desktop-idle "clean desktop" --method=qemu-monitor

set -u

# ---- arg parsing -----------------------------------------------------------
MILESTONE=""
DESCRIPTION=""
FORCE=0
METHOD="auto"
OUT_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --force)        FORCE=1; shift ;;
        --method=*)     METHOD="${1#--method=}"; shift ;;
        --out=*)        OUT_OVERRIDE="${1#--out=}"; shift ;;
        -h|--help)
            sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*)
            echo "unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$MILESTONE" ]; then
                MILESTONE="$1"
            elif [ -z "$DESCRIPTION" ]; then
                DESCRIPTION="$1"
            else
                echo "unexpected positional argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

case "$MILESTONE" in
    clear-color-red|login|desktop-idle) ;;
    "")
        echo "usage: $0 <milestone> \"<description>\" [--force] [--method=auto|vncsnapshot|xvfb|qemu-monitor]" >&2
        echo "  milestone: clear-color-red | login | desktop-idle" >&2
        exit 1
        ;;
    *)
        echo "invalid milestone: $MILESTONE (expected one of: clear-color-red, login, desktop-idle)" >&2
        exit 1
        ;;
esac

if [ -z "$DESCRIPTION" ]; then
    echo "description is required — pass a short free-form string, e.g. \"first red frame after Phase 2.B\"" >&2
    exit 1
fi

case "$METHOD" in
    auto|vncsnapshot|xvfb|qemu-monitor) ;;
    *) echo "invalid --method: $METHOD" >&2; exit 1 ;;
esac

# ---- env + paths -----------------------------------------------------------
DOCKER_HOST="${DOCKER_HOST:-}"
VM="${VM:-}"
CONTAINER="${CONTAINER:-macos-macos-1}"
VNC_PORT="${VNC_PORT:-5901}"
MONITOR_SOCKET="${MONITOR_SOCKET:-/tmp/qemu-monitor.sock}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"

if [ -z "$DOCKER_HOST" ]; then
    echo "DOCKER_HOST env var required" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REF_DIR="$SCRIPT_DIR/reference"
mkdir -p "$REF_DIR"

if [ -n "$OUT_OVERRIDE" ]; then
    OUT="$OUT_OVERRIDE"
else
    OUT="$REF_DIR/${MILESTONE}.png"
fi
META="${OUT%.png}.capture-metadata.txt"

if [ -f "$OUT" ] && [ "$FORCE" -ne 1 ]; then
    echo "reference already exists: $OUT" >&2
    echo "rerun with --force to overwrite (git diff will show the swap)" >&2
    exit 3
fi

# ---- color output (matches verify-*.sh) ------------------------------------
RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

# ---- precondition: SSH reachable -------------------------------------------
step "pre-flight: SSH reachability"
if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
    fail "cannot ssh to DOCKER_HOST=$DOCKER_HOST"
    exit 10
fi
pass "DOCKER_HOST reachable: $DOCKER_HOST"

# ---- capture strategies ----------------------------------------------------
# Each strategy echoes status on stderr and writes PNG to "$OUT" on success.
# Return 0 on success, non-zero on failure. Stay silent about which it chose
# unless the caller asked via --method.

try_vncsnapshot() {
    # Runs inside the docker container against QEMU's VNC server. The container
    # image must have vncsnapshot on PATH. verify-*.sh scripts already rely on
    # this being installed for their take_screenshot helper; if it's missing
    # here, it's missing there too and should be added to the Dockerfile.
    if ! ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker exec $CONTAINER which vncsnapshot >/dev/null 2>&1"; then
        echo "vncsnapshot not present in container $CONTAINER" >&2
        return 1
    fi
    if ! ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker exec $CONTAINER vncsnapshot -quiet 127.0.0.1::${VNC_PORT} /tmp/ref-shot.png" 2>/dev/null; then
        echo "vncsnapshot command failed (QEMU VNC down on :$VNC_PORT?)" >&2
        return 1
    fi
    ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker cp $CONTAINER:/tmp/ref-shot.png - " \
        | tar -xO > "$OUT" 2>/dev/null
    [ -s "$OUT" ]
}

try_qemu_monitor() {
    # QEMU's HMP screendump writes a PPM snapshot straight from the emulated
    # framebuffer. Most reliable because it bypasses the VNC server entirely —
    # works even if VNC isn't attached. Requires QEMU to have been launched
    # with `-monitor unix:/tmp/qemu-monitor.sock,server,nowait` (or equiv).
    if ! ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker exec $CONTAINER test -S $MONITOR_SOCKET" 2>/dev/null; then
        echo "QEMU monitor socket missing: $MONITOR_SOCKET" >&2
        return 1
    fi
    # Issue screendump via socat / nc piped to the socket. The guest writes
    # a PPM file inside the container; we then tar it out and pipe through
    # ImageMagick to re-encode as PNG. If ImageMagick isn't available in the
    # container, we save the .ppm and rely on the operator to convert client-
    # side.
    if ! ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER \
        sh -c 'printf \"screendump /tmp/ref-shot.ppm\\nquit\\n\" | socat - UNIX-CONNECT:$MONITOR_SOCKET'" \
        >/dev/null 2>&1; then
        # Fallback: nc -U; some images don't ship socat.
        if ! ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER \
            sh -c 'printf \"screendump /tmp/ref-shot.ppm\\n\" | nc -U -q1 $MONITOR_SOCKET'" \
            >/dev/null 2>&1; then
            echo "could not drive qemu monitor (neither socat nor nc worked)" >&2
            return 1
        fi
    fi
    # Try container-side convert first; else pull PPM and convert locally.
    if ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker exec $CONTAINER which convert >/dev/null 2>&1"; then
        ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER convert /tmp/ref-shot.ppm /tmp/ref-shot.png" \
            >/dev/null 2>&1 || return 1
        ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker cp $CONTAINER:/tmp/ref-shot.png - " \
            | tar -xO > "$OUT" 2>/dev/null
    else
        # Pull the PPM locally; caller must have `convert` here.
        local tmp_ppm
        tmp_ppm="$(mktemp -t ref-shot.XXXXXX.ppm)"
        ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker cp $CONTAINER:/tmp/ref-shot.ppm - " \
            | tar -xO > "$tmp_ppm" 2>/dev/null
        if ! command -v convert >/dev/null 2>&1; then
            echo "container lacks ImageMagick AND local machine does too; cannot convert ppm->png" >&2
            echo "saved raw PPM at: $tmp_ppm" >&2
            return 1
        fi
        convert "$tmp_ppm" "$OUT" || { echo "local convert failed" >&2; return 1; }
        rm -f "$tmp_ppm"
    fi
    [ -s "$OUT" ]
}

try_xvfb() {
    # Last resort: the guest is running headless Xvfb (macOS guest isn't, but
    # this path exists for test-bench variants). Uses xwd + convert from a
    # container that has access to the Xvfb display.
    if [ -z "$VM" ]; then
        echo "xvfb fallback requires VM env var" >&2
        return 1
    fi
    if ! ssh $SSH_OPTS "$VM" "which xwd >/dev/null 2>&1 && which convert >/dev/null 2>&1" 2>/dev/null; then
        echo "xvfb fallback needs xwd + convert on VM" >&2
        return 1
    fi
    ssh $SSH_OPTS "$VM" "xwd -root -silent | convert xwd:- png:- " \
        > "$OUT" 2>/dev/null
    [ -s "$OUT" ]
}

# ---- run capture -----------------------------------------------------------
step "capture: method=$METHOD → $OUT"
CAPTURE_METHOD_USED=""
case "$METHOD" in
    vncsnapshot)
        if try_vncsnapshot; then CAPTURE_METHOD_USED="vncsnapshot"; fi
        ;;
    qemu-monitor)
        if try_qemu_monitor; then CAPTURE_METHOD_USED="qemu-monitor"; fi
        ;;
    xvfb)
        if try_xvfb; then CAPTURE_METHOD_USED="xvfb"; fi
        ;;
    auto)
        if try_vncsnapshot; then
            CAPTURE_METHOD_USED="vncsnapshot"
        elif try_qemu_monitor; then
            CAPTURE_METHOD_USED="qemu-monitor"
        elif try_xvfb; then
            CAPTURE_METHOD_USED="xvfb"
        fi
        ;;
esac

if [ -z "$CAPTURE_METHOD_USED" ] || [ ! -s "$OUT" ]; then
    fail "all capture methods exhausted for milestone=$MILESTONE"
    echo "  try: --method=vncsnapshot (primary)" >&2
    echo "  try: --method=qemu-monitor (most reliable; needs -monitor unix:... in QEMU args)" >&2
    echo "  try: --method=xvfb (dev-only)" >&2
    rm -f "$OUT"
    exit 20
fi
pass "captured via $CAPTURE_METHOD_USED: $OUT"

# sanity: confirm it's a PNG file, not a zero-byte or truncated capture
if command -v file >/dev/null 2>&1; then
    if ! file "$OUT" | grep -q 'PNG image'; then
        fail "capture did not produce a PNG (got: $(file "$OUT"))"
        rm -f "$OUT"
        exit 30
    fi
fi
SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null)
if [ "${SZ:-0}" -lt 1024 ]; then
    fail "capture suspiciously small: $SZ bytes (expected >1KB)"
    rm -f "$OUT"
    exit 30
fi
pass "PNG sanity OK ($SZ bytes)"

# ---- metadata --------------------------------------------------------------
step "metadata: $META"
# Capture git SHAs of the relevant sibling repos. We assume conventional
# layout: ~/docker-macos, ~/mos-qemu, ~/libapplegfx-vulkan. If any is
# missing, we note "(not present)" rather than failing.
git_sha() {
    local d="$1"
    if [ -d "$d/.git" ]; then
        git -C "$d" rev-parse --short HEAD 2>/dev/null || echo "(unknown)"
    else
        echo "(not present: $d)"
    fi
}
DOCKER_MACOS_SHA=$(git_sha "$REPO_DIR")
QEMU_SHA=$(git_sha "$(dirname "$REPO_DIR")/mos-qemu")
LIBGFX_SHA=$(git_sha "$(dirname "$REPO_DIR")/libapplegfx-vulkan")

# Grab macOS version from the VM if reachable; otherwise note not-collected.
VM_OS="(VM env var not set; OS version not collected)"
if [ -n "$VM" ]; then
    if ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
        VM_OS=$(ssh $SSH_OPTS "$VM" "sw_vers 2>/dev/null | tr '\\n' ' '" 2>/dev/null)
        [ -z "$VM_OS" ] && VM_OS="(sw_vers unavailable)"
    else
        VM_OS="(VM unreachable at capture time)"
    fi
fi

{
    echo "milestone:        $MILESTONE"
    echo "description:      $DESCRIPTION"
    echo "captured_at:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "capture_method:   $CAPTURE_METHOD_USED"
    echo "docker_host:      $DOCKER_HOST"
    echo "container:        $CONTAINER"
    echo "vnc_port:         $VNC_PORT"
    echo "file_size_bytes:  $SZ"
    echo "vm_os:            $VM_OS"
    echo "docker-macos_sha: $DOCKER_MACOS_SHA"
    echo "mos-qemu_sha:     $QEMU_SHA"
    echo "libapplegfx_sha:  $LIBGFX_SHA"
    echo "captured_by:      $(whoami)@$(hostname)"
} > "$META" || { fail "metadata write failed: $META"; exit 40; }

pass "metadata written: $META"

# ---- done ------------------------------------------------------------------
step "done"
echo "  reference: $OUT"
echo "  metadata:  $META"
echo
echo "Next steps:"
echo "  1. Visually inspect the reference: open '$OUT'"
echo "  2. If it looks right, commit both files:"
echo "       git add '$OUT' '$META'"
echo "       git commit -m 'tests: $MILESTONE reference — $DESCRIPTION'"
echo "  3. Flip GATE_ON_DIFF=1 on the corresponding verify-*.sh when"
echo "     ready to let CI gate on this reference."
echo
echo "${GRN}=== capture-reference: DONE ===${RST}"
