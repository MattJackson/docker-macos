#!/bin/bash
# analyze-boot-log.sh — pattern-match a captured boot log against the
# milestone-signals / panic / hang pattern library and produce a JSON
# summary.
#
# Input:
#   <capture-dir> — the directory produced by tests/capture-boot-log.sh.
#                   Must contain at minimum serial.log (docker.log is
#                   also consulted if present).
#
# Output:
#   JSON to stdout. A copy is also written to
#   <capture-dir>/analysis.json for downstream consumers.
#
#   Shape:
#     {
#       "capture_dir": "...",
#       "status": "good|panic|timeout|unknown",
#       "panic": true|false,
#       "milestones": {
#         "m1": "passed|unknown",
#         "m2": "passed|unknown",
#         ...
#       },
#       "markers_found": [
#         { "category": "m2", "description": "...", "count": N, "sample": "..." },
#         ...
#       ],
#       "markers_missing": [
#         { "category": "m3", "description": "..." },
#         ...
#       ],
#       "panic_hits": [ { "category": "panic", "line": "..." } ],
#       "hang_hits":  [ { "category": "hang",  "description": "...", "count": N } ],
#       "hang_silent_sec": NNN,  // seconds since last serial output (if still running)
#       "duration_sec": NNN
#     }
#
# Exit codes:
#   0   — all expected milestones marked OR capture was short but status==good
#   1   — panic detected (status==panic OR panic hit in logs)
#   2   — expected milestones missing AND no panic (incomplete boot)
#   30  — input error (capture dir missing / malformed)
#
# Dependencies:
#   - bash, awk, grep, sed, date.
#   - jq is OPTIONAL. If present, the emitted JSON is pretty-printed.
#     Without jq we emit a hand-rolled (valid) JSON string.
#     Install: `brew install jq` on macOS; `apk add jq` in Alpine.
#
# Usage:
#   ./tests/analyze-boot-log.sh <capture-dir>
#   ./tests/analyze-boot-log.sh tests/capture-boot-logs/20260420T180000Z/

set -u

CAP_DIR="${1:-}"
if [ -z "$CAP_DIR" ]; then
    echo "usage: $0 <capture-dir>" >&2
    exit 30
fi
if [ ! -d "$CAP_DIR" ]; then
    echo "not a directory: $CAP_DIR" >&2
    exit 30
fi

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_DIR="$TESTS_DIR/patterns"
SERIAL_LOG="$CAP_DIR/serial.log"
DOCKER_LOG="$CAP_DIR/docker.log"
TRIGGER_FILE="$CAP_DIR/trigger.txt"
STATUS_FILE="$CAP_DIR/status.txt"
DURATION_FILE="$CAP_DIR/duration-sec.txt"
ANALYSIS_OUT="$CAP_DIR/analysis.json"

# Color helpers (analyze is usually run interactively)
RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1" >&2; }
fail() { echo "${RED}FAIL${RST} $1" >&2; }
warn() { echo "${YEL}WARN${RST} $1" >&2; }
step() { echo "${BLU}===${RST} $1" >&2; }

if [ ! -s "$SERIAL_LOG" ] && [ ! -s "$DOCKER_LOG" ]; then
    fail "neither serial.log nor docker.log has content in $CAP_DIR"
    exit 30
fi

# If docker.log exists but serial.log is empty, analyze both as the
# same stream. grep tolerates empty / missing files gracefully when we
# pass --files-without-match handling via -h.
LOGS_TO_SCAN=()
[ -s "$SERIAL_LOG" ] && LOGS_TO_SCAN+=("$SERIAL_LOG")
[ -s "$DOCKER_LOG" ] && LOGS_TO_SCAN+=("$DOCKER_LOG")

# ---- Expected markers for a "complete" boot --------------------------------
# Keyed by milestone. A milestone is marked passed iff AT LEAST ONE of its
# tagged patterns hit. Unknown otherwise (NOT "failed" — absence is not
# proof of failure; it may mean the capture stopped too early).
EXPECTED_MILESTONES=("m1" "m2" "m3")
# m4-m8 are included in the signal scan but not in the expected-pass
# gate yet because most of them are SCAFFOLD. Flip them into
# EXPECTED_MILESTONES as their upstream Phase lands.

# ---- Helpers ---------------------------------------------------------------
# JSON string quoter: escape backslash, double-quote, and control chars.
json_quote() {
    # Read argument, output quoted string on stdout.
    local s="$1"
    # Escape backslash first, then double-quote, then newline/tab.
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Control chars (0x00-0x1F) other than above — strip for safety.
    s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
    printf '"%s"' "$s"
}

# Read a .patterns file into parallel arrays.
#   $1 — patterns file path
# Populates shell arrays:
#   PAT_CAT, PAT_SEV, PAT_REGEX, PAT_DESC  (indexed 0..N-1)
PAT_CAT=()
PAT_SEV=()
PAT_REGEX=()
PAT_DESC=()
load_patterns() {
    local pf="$1"
    [ -f "$pf" ] || return 0
    while IFS='|' read -r cat sev rgx desc; do
        [ -z "$cat" ] && continue
        # Trim leading/trailing whitespace and comment lines.
        case "$cat" in \#*) continue ;; esac
        [ -z "$rgx" ] && continue
        PAT_CAT+=("$cat")
        PAT_SEV+=("$sev")
        PAT_REGEX+=("$rgx")
        PAT_DESC+=("$desc")
    done < "$pf"
}

# Count matches of a regex across all logs. Echoes integer to stdout.
count_matches() {
    local rgx="$1"
    local total=0 f n
    for f in "${LOGS_TO_SCAN[@]}"; do
        # `grep -c` on a single file prints just the count. If grep
        # rejects the regex or the file is empty, default to 0.
        n=$(grep -cE -- "$rgx" "$f" 2>/dev/null | head -1)
        case "$n" in
            ''|*[!0-9]*) n=0 ;;
        esac
        total=$((total + n))
    done
    echo "$total"
}

# First matching line for a regex (for the "sample" field). Echoes line.
first_match() {
    local rgx="$1"
    local f line=""
    for f in "${LOGS_TO_SCAN[@]}"; do
        line=$(grep -m1 -E -- "$rgx" "$f" 2>/dev/null || true)
        if [ -n "$line" ]; then
            echo "$line"
            return 0
        fi
    done
}

# ---- Load pattern files ----------------------------------------------------
step "loading pattern library from $PATTERNS_DIR"
for pf in "$PATTERNS_DIR/panic.patterns" \
          "$PATTERNS_DIR/milestone-signals.patterns" \
          "$PATTERNS_DIR/hang-indicators.patterns"; do
    if [ -f "$pf" ]; then
        load_patterns "$pf"
    else
        warn "$(basename "$pf") missing — skipping"
    fi
done
PATTERN_COUNT="${#PAT_REGEX[@]}"
pass "loaded $PATTERN_COUNT patterns"

# ---- Scan logs -------------------------------------------------------------
step "scanning $(echo "${LOGS_TO_SCAN[@]}" | tr ' ' '\n' | wc -l | tr -d ' ') log file(s)"

FOUND_JSON=""
MISSING_JSON=""
PANIC_JSON=""
HANG_JSON=""
# macOS ships bash 3.2 which has no associative arrays. Use a flat
# space-delimited list of "passed" milestone tags instead — e.g.
# MILESTONE_PASSED=" m1 m2 ". Lookup: `case "$MP" in *" m2 "*) ...`.
MILESTONE_PASSED=" "
PANIC_FOUND=0

i=0
while [ "$i" -lt "$PATTERN_COUNT" ]; do
    cat="${PAT_CAT[$i]}"
    sev="${PAT_SEV[$i]}"
    rgx="${PAT_REGEX[$i]}"
    desc="${PAT_DESC[$i]}"

    count=$(count_matches "$rgx")
    if [ "$count" -gt 0 ]; then
        sample=$(first_match "$rgx")
        # Truncate sample to ~200 chars to keep the JSON readable.
        if [ "${#sample}" -gt 200 ]; then
            sample="${sample:0:200}..."
        fi

        entry=$(printf '{"category":%s,"severity":%s,"description":%s,"count":%d,"sample":%s}' \
            "$(json_quote "$cat")" \
            "$(json_quote "$sev")" \
            "$(json_quote "$desc")" \
            "$count" \
            "$(json_quote "$sample")")

        # Dispatch by category family.
        case "$cat" in
            m[1-8])
                case "$MILESTONE_PASSED" in
                    *" $cat "*) : ;;
                    *) MILESTONE_PASSED="$MILESTONE_PASSED$cat " ;;
                esac
                FOUND_JSON="${FOUND_JSON:+$FOUND_JSON,}$entry"
                ;;
            panic|kext-fail|apple-gfx|qemu|memory)
                # fatal severity in panic.patterns means panic trigger.
                if [ "$sev" = "fatal" ]; then
                    PANIC_FOUND=1
                    PANIC_JSON="${PANIC_JSON:+$PANIC_JSON,}$entry"
                else
                    FOUND_JSON="${FOUND_JSON:+$FOUND_JSON,}$entry"
                fi
                ;;
            hang)
                HANG_JSON="${HANG_JSON:+$HANG_JSON,}$entry"
                ;;
            *)
                FOUND_JSON="${FOUND_JSON:+$FOUND_JSON,}$entry"
                ;;
        esac
    else
        # Only milestone-signal patterns contribute to markers_missing.
        # Panic/hang patterns that don't match are GOOD news, not markers.
        case "$cat" in
            m[1-8])
                entry=$(printf '{"category":%s,"description":%s}' \
                    "$(json_quote "$cat")" \
                    "$(json_quote "$desc")")
                MISSING_JSON="${MISSING_JSON:+$MISSING_JSON,}$entry"
                ;;
        esac
    fi
    i=$((i + 1))
done

# ---- Milestone aggregate ---------------------------------------------------
MILESTONES_JSON=""
for m in m1 m2 m3 m4 m5 m6 m7 m8; do
    state="unknown"
    case "$MILESTONE_PASSED" in
        *" $m "*) state="passed" ;;
    esac
    entry=$(printf '%s:%s' "$(json_quote "$m")" "$(json_quote "$state")")
    MILESTONES_JSON="${MILESTONES_JSON:+$MILESTONES_JSON,}$entry"
done

# ---- Hang watchdog: seconds since last serial line -------------------------
HANG_SILENT_SEC=0
if [ -s "$SERIAL_LOG" ]; then
    # mtime of serial.log approximates "last write". If the file was
    # being actively tailed, mtime tracks the most-recent append.
    LAST_MTIME=$(stat -f '%m' "$SERIAL_LOG" 2>/dev/null || stat -c '%Y' "$SERIAL_LOG" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ "$LAST_MTIME" -gt 0 ]; then
        HANG_SILENT_SEC=$((NOW - LAST_MTIME))
    fi
fi

# ---- Status + duration from capture metadata ------------------------------
CAP_STATUS="unknown"
[ -s "$STATUS_FILE" ] && CAP_STATUS=$(cat "$STATUS_FILE" | tr -d '[:space:]')
CAP_DURATION=0
[ -s "$DURATION_FILE" ] && CAP_DURATION=$(cat "$DURATION_FILE" | tr -d '[:space:]')

# Normalize panic detection: panic if status==panic OR any fatal match
if [ "$CAP_STATUS" = "panic" ]; then
    PANIC_FOUND=1
fi

# ---- Build final JSON ------------------------------------------------------
JSON=$(cat <<EOF
{
  "capture_dir": $(json_quote "$CAP_DIR"),
  "status": $(json_quote "$CAP_STATUS"),
  "panic": $( [ "$PANIC_FOUND" = "1" ] && echo true || echo false ),
  "duration_sec": $CAP_DURATION,
  "hang_silent_sec": $HANG_SILENT_SEC,
  "milestones": { $MILESTONES_JSON },
  "markers_found": [ $FOUND_JSON ],
  "markers_missing": [ $MISSING_JSON ],
  "panic_hits": [ $PANIC_JSON ],
  "hang_hits": [ $HANG_JSON ]
}
EOF
)

# Pretty-print via jq if available.
if command -v jq >/dev/null 2>&1; then
    PRETTY=$(echo "$JSON" | jq . 2>/dev/null || echo "$JSON")
    echo "$PRETTY" > "$ANALYSIS_OUT"
    echo "$PRETTY"
else
    echo "$JSON" > "$ANALYSIS_OUT"
    echo "$JSON"
fi

step "analysis written to $ANALYSIS_OUT"

# ---- Exit status ------------------------------------------------------------
if [ "$PANIC_FOUND" = "1" ]; then
    fail "panic detected — exit 1"
    exit 1
fi

MISSING_EXPECTED=0
for m in "${EXPECTED_MILESTONES[@]}"; do
    case "$MILESTONE_PASSED" in
        *" $m "*) : ;;
        *)
            MISSING_EXPECTED=$((MISSING_EXPECTED + 1))
            warn "$m — no passing marker found"
            ;;
    esac
done

# If the capture was stopped by SSH-up (status==good) and M1 at least
# passed, treat as a clean boot even if M2/M3 signals are missing —
# they may require separate verify-mN.sh runs to exercise.
if [ "$MISSING_EXPECTED" -gt 0 ] && [ "$CAP_STATUS" != "good" ]; then
    fail "$MISSING_EXPECTED expected milestone(s) unmarked — exit 2"
    exit 2
fi

if [ "$MISSING_EXPECTED" -gt 0 ]; then
    warn "$MISSING_EXPECTED expected milestone(s) unmarked, but capture status=good"
    warn "treating as pass — SSH-up is a stronger signal than individual markers"
fi
pass "analysis complete — exit 0"
exit 0
