#!/bin/bash
# check-prereqs.sh — report which capture / diff dependencies are installed
# on the operator's machine AND in the docker container.
#
# Use this before running capture-reference.sh or diff-reference.sh for the
# first time. It's purely advisory — it doesn't install anything, just tells
# the operator what's missing and the exact command to fix it.
#
# Usage:
#   ./tests/screenshots/check-prereqs.sh              # check local only
#   DOCKER_HOST=user@host ./tests/screenshots/check-prereqs.sh  # also check container
#
# Exit codes:
#   0 — all required local tools present (container side only prints warnings)
#   1 — at least one required local tool missing

set -u

DOCKER_HOST="${DOCKER_HOST:-}"
CONTAINER="${CONTAINER:-macos-macos-1}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
ok()   { echo "${GRN}ok  ${RST} $1"; }
miss() { echo "${RED}MISS${RST} $1"; }
note() { echo "${YEL}note${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

OS_HINT=""
case "$(uname -s)" in
    Darwin)  OS_HINT="macOS" ;;
    Linux)   OS_HINT="Linux" ;;
    *)       OS_HINT="$(uname -s)" ;;
esac

install_hint() {
    local tool="$1"
    case "$OS_HINT" in
        macOS)  echo "brew install $tool" ;;
        Linux)
            if command -v apk >/dev/null 2>&1; then
                echo "apk add $tool"
            elif command -v apt-get >/dev/null 2>&1; then
                echo "sudo apt-get install $tool"
            elif command -v dnf >/dev/null 2>&1; then
                echo "sudo dnf install $tool"
            else
                echo "(install $tool via your package manager)"
            fi
            ;;
        *) echo "(install $tool via your package manager)" ;;
    esac
}

LOCAL_MISSING=0

step "local tools (for diff-reference.sh)"
if command -v compare >/dev/null 2>&1; then
    ok "ImageMagick compare: $(compare -version 2>&1 | head -1)"
else
    miss "ImageMagick 'compare' not found — required by diff-reference.sh"
    echo "     install: $(install_hint imagemagick)"
    LOCAL_MISSING=1
fi
if command -v convert >/dev/null 2>&1; then
    ok "ImageMagick convert: present (needed for local PPM→PNG path in qemu-monitor capture)"
else
    note "ImageMagick 'convert' not found — only needed if the container lacks it too"
    echo "     install: $(install_hint imagemagick)"
fi
if command -v file >/dev/null 2>&1; then
    ok "file(1): present"
else
    note "file(1) not found — capture-reference.sh skips its PNG-magic check"
fi

step "capture tools (for capture-reference.sh, container-side)"
if [ -z "$DOCKER_HOST" ]; then
    note "DOCKER_HOST not set — skipping container-side checks"
    note "set DOCKER_HOST=user@host and re-run to verify the container"
else
    if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
        miss "cannot SSH to DOCKER_HOST=$DOCKER_HOST"
    elif ! ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker ps --format '{{.Names}}' | grep -q '^${CONTAINER}$'" 2>/dev/null; then
        miss "container '$CONTAINER' not running on $DOCKER_HOST"
    else
        check_in_container() {
            local tool="$1"
            if ssh $SSH_OPTS "$DOCKER_HOST" \
                "sudo docker exec $CONTAINER which $tool >/dev/null 2>&1"; then
                ok "container has $tool"
            else
                miss "container missing $tool"
                echo "     add to Dockerfile: RUN apk add --no-cache $tool"
            fi
        }
        check_in_container vncsnapshot
        check_in_container socat
        check_in_container nc
        check_in_container convert
    fi
fi

step "summary"
if [ "$LOCAL_MISSING" -eq 1 ]; then
    echo "${RED}Some local tools are missing — install them before running diff-reference.sh.${RST}"
    exit 1
fi
echo "${GRN}Local tools OK.${RST} Container checks are advisory; missing container tools"
echo "will cause capture-reference.sh to fall back through its strategy list or fail."
exit 0
