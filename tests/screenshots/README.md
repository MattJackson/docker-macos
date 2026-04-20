# tests/screenshots — reference-image workflow

This directory holds the inputs and outputs of the pixel-diff verify
scripts:

| Script                       | Milestone | Reference                         |
|------------------------------|-----------|-----------------------------------|
| `../verify-m4.sh`            | M4        | `reference/clear-color-red.png`   |
| `../verify-login-screen.sh`  | M6        | `reference/login.png`             |
| `../verify-desktop-idle.sh`  | M7        | `reference/desktop-idle.png`      |

It's how we turn "the screen looks right" from a subjective claim into
a green/red CI signal.

## Layout

```
tests/screenshots/
  README.md                             # this file
  .gitignore                            # ignore rules for run-outputs
  capture-reference.sh                  # operator: promote a capture to reference
  diff-reference.sh                     # CI: diff capture vs reference
  check-prereqs.sh                      # diagnostics: what's missing locally?
  reference/                            # committed ground-truth images
    README.md                           # per-reference description + how to regenerate
    clear-color-red.png                 # M4 reference (DEFERRED — scaffold)
    clear-color-red.capture-metadata.txt
    login.png                           # M6 reference (DEFERRED)
    login.capture-metadata.txt
    desktop-idle.png                    # M7 reference (DEFERRED)
    desktop-idle.capture-metadata.txt
  diffs/                                # diff images from failed runs (ignored)
  YYYY-MM-DD_HHMMSS-<milestone>.png     # per-run captures (ignored)
```

Run-outputs stay on disk for manual inspection after a red run. They
are NOT committed — see `.gitignore`.

## Status (Phase 0 snapshot)

No real references have been captured yet. The pixel path (Phase 2.B)
hasn't landed, so there's nothing valid to reference. All three verify
scripts run in SCAFFOLD mode (`GATE_ON_DIFF=0`) — they perform
infrastructure checks (VM reachable, processes running, screenshot
pipeline works) and warn loudly that the visual-diff step is deferred.

See `reference/README.md` for per-milestone status and the regeneration
procedures.

## Why this workflow exists

The project's end state is visual — a 1080p desktop useful for real
work (see `~/mos/memory/project_100pct_target.md`). Log-grep
("QDP fired!") is not the same as "the user can see something".
Visual regression tests are the only way to know the pixels kept
working once Phase 3 lands.

Per `memory/feedback_iterate_dont_bigbang.md`: every iteration should
include user-visible verification, not just log signals. That's what
these screenshots are for.

## The three scripts

### `capture-reference.sh` — operator-facing

Promotes a single live VM framebuffer snapshot into a committed
reference image.

```bash
# Typical use:
DOCKER_HOST=user@host ./tests/screenshots/capture-reference.sh \
    clear-color-red "first red frame via apple-gfx-pci + lavapipe"
```

Writes:
- `reference/<milestone>.png`
- `reference/<milestone>.capture-metadata.txt` (UTC timestamp, VM OS
  version, git SHAs of docker-macos + mos-qemu + libapplegfx-vulkan,
  capture method used)

Capture methods, tried in this order under `--method=auto`:

1. **`vncsnapshot`** — runs inside the docker container against QEMU's
   VNC server on `127.0.0.1:5901`. This is what the verify-*.sh
   scripts' existing `take_screenshot()` helper uses, so it's the
   most-exercised path. Needs `vncsnapshot` installed in the container
   image.
2. **`qemu-monitor`** — issues `screendump` via QEMU's HMP monitor
   socket (`/tmp/qemu-monitor.sock` by default). Most reliable because
   it bypasses the VNC server entirely — works even if VNC isn't
   attached. Needs QEMU launched with `-monitor unix:...,server,nowait`.
3. **`xvfb`** — `xwd | convert` against a headless X display on the
   guest. Dev-only fallback for non-macOS guest variants; not useful
   for the mainline macOS path.

Refuses to overwrite existing references without `--force`. Run
`--help` for full option docs.

### `diff-reference.sh` — shared diff implementation

Takes two PNGs and emits pass/fail. Used standalone for ad-hoc diffs;
the verify-*.sh scripts currently embed their own
`compare_screenshot()` helper (simpler for a standalone script), but
they can delegate here once their tolerance shapes have converged.

```bash
./tests/screenshots/diff-reference.sh capture.png reference/login.png
./tests/screenshots/diff-reference.sh cap.png reference/clear-color-red.png --exact
./tests/screenshots/diff-reference.sh cap.png reference/desktop-idle.png \
    --metric=MAE --tolerance=30
```

Default metric is `AE` (absolute pixel count differing) with
tolerance 100 — tuned for minor subpixel noise from Lavapipe's CPU
rasterizer without masking structural regressions. Synthetic frames
(M4 clear-color) should use `--exact` for a zero-tolerance gate.

On failure, writes a highlighted diff image to
`diffs/<reference-name>-<timestamp>.png`.

Exit codes: 0 match, 1 diff > tolerance, 2 missing file, 3 tool
missing, 4 argument error.

### `check-prereqs.sh` — diagnostics

Prints which tools are installed locally and in the docker container,
with platform-specific install commands (`brew install ...` /
`apk add ...`). Run this before your first `capture-reference.sh`
invocation.

```bash
./tests/screenshots/check-prereqs.sh                     # local only
DOCKER_HOST=user@host ./tests/screenshots/check-prereqs.sh  # + container
```

## End-to-end workflow: first reference capture

When Phase 2.B lands the first real pixels:

### 1. Get to the target state

- M4: run `tests/metal-clear-screen` on the VM. Confirm noVNC shows
  solid red.
- M6: let the VM boot to `loginwindow`. Confirm the login UI is painted
  through our stack (not VMware-SVGA fallback).
- M7: auto-login, wait ~10s for UI to settle.

### 2. Run the verify-*.sh scaffold

```bash
DOCKER_HOST=user@host VM=user@vm-ip ./tests/verify-m4.sh
```

This captures `YYYY-MM-DD_HHMMSS-<milestone>.png` in this directory
and degrades gracefully through "reference missing" since no reference
exists yet. The capture is what you'll inspect.

### 3. Inspect visually

Open the timestamped capture. Confirm by eye that it matches the
expected visual state. This is the ONLY moment in the workflow where
human judgement enters the loop.

### 4. Promote to reference

```bash
DOCKER_HOST=user@host ./tests/screenshots/capture-reference.sh \
    <milestone> "<description>"
```

`capture-reference.sh` takes a FRESH snapshot (rather than copying the
timestamped capture) so the reference and its metadata were produced
in the same run. Less room for "which run was this from?" confusion.

### 5. Commit

```bash
git add tests/screenshots/reference/<milestone>.png \
        tests/screenshots/reference/<milestone>.capture-metadata.txt
git commit -m 'tests: <milestone> reference — <description>'
```

Update `reference/README.md` to flip the status from `DEFERRED` to
`REAL`.

### 6. Flip the gate

Edit the corresponding verify-*.sh to default `GATE_ON_DIFF=1`:

```diff
-GATE_ON_DIFF="${GATE_ON_DIFF:-0}"
+GATE_ON_DIFF="${GATE_ON_DIFF:-1}"
```

Commit. From this point, CI fails when the diff exceeds tolerance.

## Updating a reference

When the expected visual state changes intentionally (macOS update,
OpenCore theme, etc.):

```bash
DOCKER_HOST=user@host ./tests/screenshots/capture-reference.sh \
    login "macOS 15.5 login UI refresh" --force
git diff --stat tests/screenshots/reference/  # confirm change is intentional
git add tests/screenshots/reference/login.png \
        tests/screenshots/reference/login.capture-metadata.txt
git commit -m 'tests: update M6 reference — macOS 15.5 login UI'
```

See `reference/README.md` for per-milestone regeneration notes.

## How the diff works

`diff-reference.sh` shells out to ImageMagick's `compare` command. The
default metric is `AE` (absolute error — count of pixels that differ).
Alternatives:

- `AE` — good default for synthetic / solid-color frames. Tolerance
  units = pixel count.
- `MAE` — mean absolute error per channel, 0..1 normalized. Good for
  noisy UI captures. Tolerance units = MAE * 255 (per-channel
  intensity delta).
- `RMSE` — root-mean-square error. Penalises large single-pixel
  deltas more than MAE; use if noise is spatially clustered.
- `PAE` — peak absolute error. Max per-pixel delta. Use to catch a
  single wildly-off pixel (tile corruption).

The verify-*.sh scripts currently use `MAE` with tolerance 20-30.
`diff-reference.sh` defaults to `AE` / 100 because it's intended for
ad-hoc use where "did anything change?" is the question, not "did it
drift by 8% per channel?".

Why not an exact pixel-hash match:
- Lavapipe is CPU-rendered. Subgroup size and thread-count differences
  across hosts produce tiny per-pixel deltas in subpixel AA, gradient
  rasterization, and font hinting.
- Exact hashes would flake on every minor host difference.

Raise tolerance if we see flakes in known-good runs; lower it if we
see regressions sneaking through.

## Tolerance tuning (starting values)

| Reference              | Metric | Tolerance | Rationale                                   |
|------------------------|--------|-----------|---------------------------------------------|
| `clear-color-red.png`  | AE     | 0 (exact) | Synthetic solid color — zero-noise.         |
| `login.png`            | MAE    | 20        | Mostly static — logo, password field.       |
| `desktop-idle.png`     | MAE    | 30        | Dynamic cursor, clock, menu-bar battery.    |

Re-tune after Phase 3 once we have a week of known-good runs to
measure noise floor.

## Dependencies

- **`compare` / `convert` (ImageMagick)** on the host running the
  verify scripts and the operator running `capture-reference.sh`.
  - macOS: `brew install imagemagick`
  - Alpine: `apk add imagemagick`
- **`vncsnapshot`** inside the docker container. If absent, capture
  falls back to `qemu-monitor` (preferred) or `xvfb` (dev-only).
  Add to the Dockerfile's runtime `apk add` list.
- **`socat` or `nc`** inside the container for `qemu-monitor` method.
- Run `./check-prereqs.sh` for a precise per-tool report.

## FAQ

**Q: What if the diff fails but the image looks fine to me?**
Manually compare the capture against `reference/<milestone>.png` in
Preview. If the difference is intentional (macOS update etc.),
follow "Updating a reference" above. If unintentional, you've caught
a regression.

**Q: Can I test without noVNC running?**
Yes — the `qemu-monitor` capture method doesn't need VNC. Pass
`--method=qemu-monitor` to `capture-reference.sh`. The verify-*.sh
scripts still use VNC for their take_screenshot path today; extending
them to also try the monitor path is future work.

**Q: Why not just diff framebuffers natively from QEMU?**
The `qemu-monitor` capture method does exactly that for reference
captures. We use the VNC path in verify-*.sh for the LIVE diff because
we want to test what noVNC sees, not what QEMU thinks it sent —
subtle bugs can live in that gap. Use qemu-monitor for references
(reliability) and VNC for live diffs (what-the-user-sees).

**Q: How do I regenerate a reference after a macOS update?**
`./capture-reference.sh <milestone> "<reason>" --force`. See
`reference/README.md` for per-milestone notes about what to check
before capturing.
