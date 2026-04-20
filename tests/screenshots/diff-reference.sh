#!/bin/bash
# diff-reference.sh — pixel-diff an arbitrary capture against a committed
# reference and emit a pass/fail signal suitable for CI.
#
# This is the DIFF half of the reference workflow. Its counterpart is
# capture-reference.sh (which produces the references in the first place).
# verify-m4.sh / verify-login-screen.sh / verify-desktop-idle.sh embed
# their own inline compare_screenshot() today; this script exists as a
# standalone, reusable implementation they (or any future verify script)
# can delegate to. Output format is stable so callers can parse it.
#
# ==== WHY A SEPARATE SCRIPT ==================================================
# 1. Single source of truth: tolerance defaults, diff-image placement, and
#    exit-code conventions live in one file.
# 2. Usable from the operator's shell for ad-hoc one-off diffs (e.g.
#    comparing two captures not tied to any verify-*.sh run).
# 3. Lets us evolve the comparison (swap MAE → AE, add perceptual-hash
#    fallback, etc.) without touching three verify scripts.
# =============================================================================
#
# Usage:
#   ./tests/screenshots/diff-reference.sh <captured.png> <reference.png> [options]
#
# Options:
#   --tolerance N    max allowed absolute pixel error (AE metric).
#                    Default 100 — i.e. up to 100 differing pixels before
#                    flagging a diff. Increase for noisy/rasterized UI,
#                    decrease for solid-color references (M4).
#   --exact          require EXACT match (AE=0). Shorthand for --tolerance=0.
#                    Use for synthetic frames (clear-color).
#   --metric NAME    ImageMagick metric: AE (default) | MAE | RMSE | PAE.
#                    AE = absolute pixel count differing.
#                    MAE = mean absolute error across channels 0..1.
#   --quiet          suppress human-readable output; only emit machine-
#                    readable single line on stdout: PASS|FAIL|SKIP metric value.
#
# Exit codes:
#   0   — match within tolerance
#   1   — diff exceeds tolerance (gate failure)
#   2   — one or both input files missing / unreadable
#   3   — ImageMagick `compare` not installed
#   4   — argument error
#
# On failure, writes a diff image to:
#   tests/screenshots/diffs/<reference-basename>-<YYYYMMDDHHMMSS>.png
# where pixels that differ are highlighted in red.
#
# Examples:
#   # Default: fail if more than 100 pixels differ.
#   ./tests/screenshots/diff-reference.sh capture.png reference/login.png
#
#   # Strict exact-match (clear-color test):
#   ./tests/screenshots/diff-reference.sh capture.png \
#       reference/clear-color-red.png --exact
#
#   # Mean-absolute-error mode for fuzzier UI comparisons:
#   ./tests/screenshots/diff-reference.sh capture.png \
#       reference/desktop-idle.png --metric=MAE --tolerance=20

set -u

# ---- defaults --------------------------------------------------------------
TOLERANCE=100
METRIC="AE"
QUIET=0
ACTUAL=""
REF=""

# ---- arg parsing -----------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --tolerance=*)  TOLERANCE="${1#--tolerance=}"; shift ;;
        --tolerance)    TOLERANCE="$2"; shift 2 ;;
        --exact)        TOLERANCE=0; shift ;;
        --metric=*)     METRIC="${1#--metric=}"; shift ;;
        --metric)       METRIC="$2"; shift 2 ;;
        --quiet)        QUIET=1; shift ;;
        -h|--help)
            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*)
            echo "unknown option: $1" >&2
            exit 4
            ;;
        *)
            if [ -z "$ACTUAL" ]; then
                ACTUAL="$1"
            elif [ -z "$REF" ]; then
                REF="$1"
            else
                echo "unexpected positional argument: $1" >&2
                exit 4
            fi
            shift
            ;;
    esac
done

if [ -z "$ACTUAL" ] || [ -z "$REF" ]; then
    echo "usage: $0 <captured.png> <reference.png> [--tolerance N] [--exact] [--metric AE|MAE|RMSE|PAE] [--quiet]" >&2
    exit 4
fi

case "$METRIC" in
    AE|MAE|RMSE|PAE) ;;
    *) echo "invalid --metric: $METRIC (expected AE|MAE|RMSE|PAE)" >&2; exit 4 ;;
esac

if ! printf '%s' "$TOLERANCE" | grep -qE '^[0-9]+$'; then
    echo "invalid --tolerance: $TOLERANCE (expected non-negative integer)" >&2
    exit 4
fi

# ---- color output (matches verify-*.sh) ------------------------------------
RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
RST=$(printf '\033[0m')
emit_pass() { [ "$QUIET" -eq 1 ] && echo "PASS $METRIC $1" || echo "${GRN}PASS${RST} diff $METRIC=$1 (tolerance=$TOLERANCE)"; }
emit_fail() { [ "$QUIET" -eq 1 ] && echo "FAIL $METRIC $1" || echo "${RED}FAIL${RST} diff $METRIC=$1 > tolerance=$TOLERANCE"; }
emit_skip() { [ "$QUIET" -eq 1 ] && echo "SKIP $METRIC $1" || echo "${YEL}SKIP${RST} $1"; }

# ---- preconditions ---------------------------------------------------------
if [ ! -r "$ACTUAL" ]; then
    emit_skip "captured file missing: $ACTUAL"
    exit 2
fi
if [ ! -r "$REF" ]; then
    emit_skip "reference file missing: $REF"
    exit 2
fi
if ! command -v compare >/dev/null 2>&1; then
    emit_skip "ImageMagick 'compare' not installed — install via: brew install imagemagick (or apk add imagemagick)"
    exit 3
fi

# ---- set up diff output ----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIFF_DIR="$SCRIPT_DIR/diffs"
mkdir -p "$DIFF_DIR"
STAMP=$(date +%Y%m%d%H%M%S)
REF_BASE="$(basename "$REF" .png)"
DIFF_OUT="$DIFF_DIR/${REF_BASE}-${STAMP}.png"

# ---- run compare -----------------------------------------------------------
# Stderr capture: ImageMagick `compare` writes the metric value to stderr
# (this is by design — stdout is reserved for the diff image when output
# goes to a file). We parse stderr to get the scalar.
#
# For AE (absolute error), compare prints a raw integer (pixel count).
# For MAE/RMSE/PAE, it prints "<normalized> (<raw>)". We take the value
# before the paren; callers picking those metrics must interpret the scale.
RAW=$(compare -metric "$METRIC" "$ACTUAL" "$REF" "$DIFF_OUT" 2>&1 >/dev/null || true)

# Clean the output — compare may prepend warnings; take the last numeric token.
VALUE=$(printf '%s' "$RAW" | awk 'END { print $NF }' | awk -F'(' '{print $1}')

# For AE, we want an integer compare. For MAE, a float compare. We normalise
# by doing all comparisons in awk with float math — AE values still compare
# correctly because integers compare as floats.
if ! printf '%s' "$VALUE" | grep -qE '^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'; then
    emit_skip "compare produced unparseable output: $RAW"
    rm -f "$DIFF_OUT"
    exit 3
fi

EXCEEDS=$(awk -v v="$VALUE" -v t="$TOLERANCE" 'BEGIN { print (v > t) ? 1 : 0 }')

if [ "$EXCEEDS" -eq 0 ]; then
    emit_pass "$VALUE"
    # Perfect matches → no need to keep the (fully-clean) diff image.
    if [ "$METRIC" = "AE" ] && [ "$VALUE" = "0" ]; then
        rm -f "$DIFF_OUT"
    fi
    exit 0
else
    emit_fail "$VALUE"
    if [ "$QUIET" -ne 1 ] && [ -f "$DIFF_OUT" ]; then
        echo "    diff image: $DIFF_OUT"
        echo "    actual:     $ACTUAL"
        echo "    reference:  $REF"
    fi
    exit 1
fi
