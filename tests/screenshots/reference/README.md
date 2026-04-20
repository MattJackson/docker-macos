# tests/screenshots/reference — committed ground-truth images

Each PNG in this directory is the authoritative visual target for one
verify-*.sh script. The verify scripts diff live captures against these
references; a delta above tolerance is a failed gate.

## IMPORTANT: scaffold mode

As of Phase 0, no real references exist yet. The pixel path (Phase 2.B)
hasn't landed, so there is nothing to capture. Until the first real
capture lands:

- This directory may be empty or contain PLACEHOLDER images.
- All verify-*.sh scripts run with `GATE_ON_DIFF=0` (their default).
  They warn "reference missing" or "delta exceeds tolerance" but
  continue to exit 0 for the scaffold.
- CI should NOT set `GATE_ON_DIFF=1` for any of these milestones yet.

When a real reference is captured (see workflow below), commit it,
update this README's "Status" column to `REAL`, and flip
`GATE_ON_DIFF=1` on the corresponding verify script.

## The references

| File                    | Milestone | Status      | Size      | Description                                                     |
|-------------------------|-----------|-------------|-----------|-----------------------------------------------------------------|
| `clear-color-red.png`   | M4        | DEFERRED    | 1920x1080 | Entire framebuffer pure red (255,0,0,255). No cursor. No overlays. Produced by running `tests/metal-clear-screen` on the VM. |
| `login.png`             | M6        | DEFERRED    | 1920x1080 | Apple loginwindow: default wallpaper, user account list visible, no menu-bar dropdowns. |
| `desktop-idle.png`      | M7        | DEFERRED    | 1920x1080 | Clean desktop after auto-login: Dock at bottom, menu bar populated, no app windows, no Finder windows open, cursor parked at top-left. |

`DEFERRED` = reference not yet captured. The corresponding verify-*.sh
runs in scaffold mode and passes on infrastructure checks only.
`REAL` = captured via `capture-reference.sh` and committed.
`PLACEHOLDER` = if we ever commit solid-color stand-ins for CI wiring
(see below), they go here in this column.

## Why no placeholder images?

We considered committing PLACEHOLDER PNGs (solid-black 1920x1080 with
"PLACEHOLDER" text) so verify-*.sh would fail diff loudly during
scaffold. We chose NOT to, because:

1. verify-*.sh already handle missing references gracefully — they
   warn and pass in scaffold mode (`GATE_ON_DIFF=0`).
2. Committing placeholder PNGs adds ~100KB to the repo for no CI
   benefit; CI is already correctly scaffolded.
3. A placeholder image in the diff path is worse than no image — an
   operator glancing at a "delta=58000 > tolerance=20" failure is
   harder to triage than "reference missing, capture with X".

If the CI policy later requires a present-but-intentionally-failing
image to prove the diff path works end-to-end, the one-liner is:

```bash
convert -size 1920x1080 xc:black -fill white -pointsize 100 \
  -gravity center -annotate +0+0 "PLACEHOLDER\nm4/m6/m7 not yet captured" \
  tests/screenshots/reference/<milestone>.png
```

Mark the row `PLACEHOLDER` in the table above when doing this.

## Capturing a real reference

```bash
# Boot the VM to the target state, visually confirm it looks right on noVNC,
# then:
DOCKER_HOST=user@host ./tests/screenshots/capture-reference.sh \
    clear-color-red "first red frame via apple-gfx-pci + lavapipe"
```

See `../capture-reference.sh --help` for method selection and options,
and `../README.md` for the end-to-end workflow.

## Regenerating a reference

When the expected visual state changes intentionally (macOS update changes
the login wallpaper, we ship a new theme, etc.):

```bash
DOCKER_HOST=user@host ./tests/screenshots/capture-reference.sh \
    login "macOS 15.5 login UI refresh" --force
git add tests/screenshots/reference/login.png \
        tests/screenshots/reference/login.capture-metadata.txt
git commit -m 'tests: update M6 reference — macOS 15.5 login UI'
```

Per-reference regeneration notes:

### clear-color-red.png (M4)
Regenerate only if the target color changes (unlikely) or the resolution
defaults change (e.g. 1920x1080 → 2560x1440). Run
`tests/metal-clear-screen` on the VM, confirm the noVNC view is solid
red, then `capture-reference.sh clear-color-red "<description>" --force`.

### login.png (M6)
Regenerate on:
- macOS minor version updates (wallpaper / login layout can shift)
- Any change to OpenCore config that affects boot splash / resolution
- User account changes (adding/removing accounts changes the panel)

Before capturing, wait long enough post-boot for the login window to
fully render (passwords field focused, no loading spinners).

### desktop-idle.png (M7)
Regenerate on:
- macOS minor version updates (Dock icons / menu-bar items shift)
- Wallpaper changes
- Installing / removing apps that auto-start (they'd show in the Dock)

Before capturing, wait at least 10s after auto-login (`IDLE_WAIT` in
verify-desktop-idle.sh) so the Spotlight / Notification icons settle.
Mouse cursor should be parked — consider a pre-capture `cliclick m:0,0`
on the VM to move it to a consistent position.

## Metadata file

Each `<milestone>.png` is committed alongside a
`<milestone>.capture-metadata.txt`, produced automatically by
`capture-reference.sh`. It records:

- When the capture was taken (UTC timestamp)
- Which capture method was used (vncsnapshot / qemu-monitor / xvfb)
- macOS version running in the VM at capture time
- Git SHAs of docker-macos, mos-qemu, and libapplegfx-vulkan
- Who captured it

Treat the metadata as part of the reference — commit them together.
When diffs flake, the metadata tells you whether the reference was
captured against a meaningfully different software stack.
