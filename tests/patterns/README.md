# Boot-log pattern library

Pattern libraries consumed by `tests/capture-boot-log.sh` and
`tests/analyze-boot-log.sh`. Each `*.patterns` file is line-oriented,
pipe-separated, and written to be trivial to grep over. The three
files partition the signal space:

- `panic.patterns` — kernel panic / hard fault signatures. Any match
  trips capture's "panic" trigger and analyze's exit-1 path.
- `milestone-signals.patterns` — positive boot-progress markers for
  M1 through M8. Used by analyze to fill in the per-milestone
  passed/unknown state.
- `hang-indicators.patterns` — common "boot got stuck" fingerprints
  (last-output watchdog, looping service starts, DHCP timeouts).

## Line format

```
<category>|<severity>|<regex>|<one-line human description>
```

- `<category>` — short tag. Conventionally: `panic`, `kext-fail`,
  `timeout`, `mX` (milestone id), `hang`, etc. Free-form; analyze
  groups matches by this field in its JSON output.
- `<severity>` — one of `info`, `warn`, `error`, `fatal`. `fatal`
  in `panic.patterns` trips the capture-side panic trigger.
- `<regex>` — an extended regex (passed to `grep -E`). Anchor if the
  pattern is prone to false positives (e.g. prefix with `panic\(`).
  Escape literal parens / brackets. Do NOT include the delimiters.
- `<description>` — human-readable; shows up in analyze's
  `markers_found` JSON field.

Lines beginning with `#` and blank lines are ignored. Whitespace
inside the regex field IS significant (the split is on `|`).

## Authoring new patterns

1. Reproduce the failure, capture a `serial.log` via
   `tests/capture-boot-log.sh`.
2. Grep the log for a distinctive, low-false-positive phrase. Prefer
   strings emitted by our own code (`lagfx_`, `apple_gfx_pci_`,
   `AppleParavirtGPU`) over generic kernel strings.
3. Add a line to the matching `.patterns` file (one of the three
   above) with a category that groups similar signals.
4. Re-run `tests/analyze-boot-log.sh` against the same capture dir
   and verify the new marker shows up in `markers_found`.
5. Add an inverse entry to `markers_missing`-side logic if the
   pattern is an expected-always marker (edit `analyze-boot-log.sh`
   `EXPECTED_MARKERS`).

## Regex portability note

Patterns are consumed by BSD grep on macOS (dev machines) and GNU
grep in the Alpine container. Both support `grep -E` with the POSIX
ERE subset. Avoid perl-only constructs (`\d`, `\w`, lookaheads). Use
`[0-9]`, `[A-Za-z_]`, character classes.

## Testing a new pattern locally

```bash
# Test against an existing capture:
./tests/analyze-boot-log.sh tests/capture-boot-logs/<stamp>/

# Or test one pattern by hand:
grep -E 'my-new-regex' tests/capture-boot-logs/<stamp>/serial.log
```

## When to add a pattern vs fix the code

Patterns are observability, not a fix. If the log is noisy enough to
produce false positives, tighten the pattern OR quiet the log
emitter. A high-false-positive pattern in this library is worse than
no pattern — it trains operators to ignore the analyzer output.
