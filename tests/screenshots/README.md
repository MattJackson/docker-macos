# tests/screenshots — reference-image workflow

This directory holds the inputs and outputs of the pixel-diff verify
scripts (`verify-login-screen.sh` for M6, `verify-desktop-idle.sh` for
M7). It's how we turn "the screen looks right" from a subjective claim
into a green/red CI signal.

## Layout

```
tests/screenshots/
  README.md                         # this file
  reference/                        # committed reference images (known-good)
    login.png                       # M6 reference — Apple login at 1080p
    desktop-idle.png                # M7 reference — Dock + menu bar idle
  YYYY-MM-DD_HHMMSS-login.png       # per-run captures, ignored by git
  YYYY-MM-DD_HHMMSS-desktop-idle.png
```

Run-outputs stay on disk for manual inspection after a red run. They
are not committed (see `.gitignore` rule at repo root).

## Why this workflow exists

The project's end state is visual — 1080p desktop useful for real
work (see `~/mos/memory/project_100pct_target.md`). Log-grep
("QDP fired!") is not the same as "the user can see something".
Visual regression tests are the only way to know the pixels kept
working once Phase 3 lands.

Per `memory/feedback_iterate_dont_bigbang.md`: every iteration
should include user-visible verification, not just log signals.
That's what these screenshots are for.

## Capturing a reference image

References are captured MANUALLY, not automatically. The first time a
given milestone lands clean pixels, the operator inspects the result
on noVNC, confirms it looks right, and promotes the capture to a
reference.

### Step 1 — Get to the target state

For M6: boot far enough that `pgrep loginwindow` succeeds and the
Apple login screen is painted via our stack (not VMware-SVGA
fallback). Confirm by `qemu ... -device apple-gfx-pci` is in the
running cmdline and the guest kext has bound.

For M7: same as M6 but past auto-login, with Dock visible.

### Step 2 — Run the verify script

```bash
DOCKER_HOST=user@host VM=user@vm-ip ./tests/verify-login-screen.sh
```

This captures a screenshot to
`tests/screenshots/YYYY-MM-DD_HHMMSS-login.png`. Every run produces
a new timestamped file.

### Step 3 — Inspect visually

Open the capture. Confirm by eye that it shows the expected visual
state. This is the ONLY moment in the workflow where human judgement
enters the loop — after this, the reference image becomes the ground
truth that all future runs diff against.

### Step 4 — Promote to reference

```bash
cp tests/screenshots/2026-05-01_143012-login.png \
   tests/screenshots/reference/login.png
git add tests/screenshots/reference/login.png
git commit -m 'tests: M6 reference login screenshot (Phase 3 first-pass)'
```

Note: commit ONLY the reference image, not the timestamped run
capture.

### Step 5 — Flip the gate

Edit the top of `verify-login-screen.sh` (or pass via env) to
enable fail-on-diff:

```bash
GATE_ON_DIFF=1 ./tests/verify-login-screen.sh
```

Once the default should gate: change `GATE_ON_DIFF="${GATE_ON_DIFF:-0}"`
to `GATE_ON_DIFF="${GATE_ON_DIFF:-1}"` in the script and commit.

## Updating a reference image

References need to change when the expected visual state changes
intentionally (e.g. macOS update changes the wallpaper, we ship a
new OpenCore theme, we intentionally change the menu-bar).

```bash
# 1. Verify the new capture is what you want.
cp tests/screenshots/$(ls -t tests/screenshots/*-login.png | head -1) \
   tests/screenshots/reference/login.png
# 2. Diff vs previous reference to confirm the change is intentional.
git diff --stat tests/screenshots/reference/
# 3. Commit with a message explaining WHY this changed.
git add tests/screenshots/reference/login.png
git commit -m 'tests: update M6 reference — macOS 15.4 wallpaper change'
```

## How the diff works

`compare_screenshot()` in each verify script shells out to
ImageMagick's `compare -metric MAE` (mean absolute error per channel,
0..255). The scalar result is compared against `TOLERANCE` (default 20).

Why MAE and not a pixel-exact hash:
- Lavapipe is CPU-rendered. Subgroup size and thread-count differences
  across hosts produce tiny per-pixel deltas in subpixel AA, gradient
  rasterization, and font hinting. Exact hashes would flake.
- MAE at tolerance 20 (~8% per channel) catches structural changes —
  missing Dock, corruption, misplaced menu bar — without tripping on
  subpixel noise.

Raise tolerance if we see flakes in known-good runs; lower it if we
see regressions sneaking through.

## Tolerance tuning

Suggested starting tolerances (empirically re-tune post-Phase 3):

| Reference          | TOLERANCE | Rationale                                   |
|--------------------|-----------|---------------------------------------------|
| `login.png`        | 20        | Mostly static — Apple logo, password field. |
| `desktop-idle.png` | 30        | Dynamic cursor, clock, menu-bar battery.    |

## Dependencies

- **`compare` (ImageMagick)** — on the host running the verify script.
  macOS: `brew install imagemagick`. Alpine: `apk add imagemagick`.
  If missing, the diff step prints a warn and degrades to scaffold-
  mode (captures but doesn't diff).
- **`vncsnapshot`** — IN the docker container. The verify scripts
  prefer capturing via VNC (what the user actually sees through
  noVNC) over the macOS-side `screencapture` path (which bypasses our
  display stack entirely). To enable: add `vncsnapshot` to the
  Dockerfile's runtime `apk add` list. Without it, scripts fall back
  to `screencapture` and warn about it.

## FAQ

**Q: What if the diff fails but the image looks fine to me?**
Manually compare `tests/screenshots/YYYY-MM-DD-login.png` against
`tests/screenshots/reference/login.png` in Preview. If the difference
is intentional (macOS update etc.), follow "Updating a reference
image" above. If it's unintentional, you've caught a regression.

**Q: Can I test without noVNC running?**
Yes but you lose signal: the fallback path is `ssh VM && screencapture`,
which asks macOS to render its own framebuffer. That bypasses
libapplegfx-vulkan → lavapipe → VMware-SVGA → noVNC — i.e. exactly
the path we're trying to test. Use only for local debugging.

**Q: Why not just diff framebuffers natively from QEMU?**
QEMU has `-monitor` `screendump` which emits PPM. Cleaner than VNC
snapshot. We're not using it because we want to test what noVNC sees,
not what QEMU thinks it sent — subtle bugs can live in that gap.
