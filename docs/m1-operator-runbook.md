# M1 operator runbook — first docker build on portainer-1

Sit down at a terminal, light up M1 for the first time, 60 minutes
budgeted. Copy-pastable, operator-facing (not developer-facing).

**Sibling docs:**

- `tests/verify-m1.sh` — automated CI-style gate. Run after the manual
  walkthrough. Final M1 green/red signal.
- `docs/test-runbook.md` — multi-milestone overview (M1..M8).
- `docs/m1-dry-run-prediction.md` — paper audit behind the triage
  table. Deeper "why" for each predicted failure.

**M1 green =** `docker compose build` exits 0, container up,
`qemu-system-x86_64 -device help` lists `apple-gfx-pci`, no kernel
panic in the serial log, `verify-m1.sh` exits 0. Login screen via
noVNC is a bonus, not a gate.

---

## 0. Pre-flight checklist

Before you sit down. All must be true.

- [ ] SSH key access: `ssh matthew@portainer-1 true` succeeds.
- [ ] Both mos-side repos pushed — the Dockerfile fetches tarballs
  from GitHub, not local trees. Run
  `git -C /Users/mjackson/libapplegfx-vulkan push && git -C /Users/mjackson/qemu-mos15 push`.
- [ ] Docker engine up on the host (`systemctl status docker` via SSH).
- [ ] `sequoia_recovery.img` (~3.2 GB) and `OpenCore.img` already in
  `~/mos/docker-macos/` on the host. See `SETUP.md` step 2.
- [ ] Optional: `vulkaninfo --summary` on the host shows a lavapipe
  ICD line. Helpful but not load-bearing — the container ships its
  own lavapipe.

---

## 1. Step-by-step execution

Set two session-level env vars up front — every later command uses
them.

```bash
set -u
export DOCKER_HOST_SSH="matthew@portainer-1"
export REPO_DIR="~/mos/docker-macos"
```

(We use `DOCKER_HOST_SSH`, not `DOCKER_HOST`, to avoid clashing with
the Docker CLI's own `DOCKER_HOST=tcp://...` semantics.)

### Step 1 — SSH in + refresh the repo (2 min)

```bash
ssh "${DOCKER_HOST_SSH}" "git -C ${REPO_DIR} pull --ff-only origin main"
```

Expected: `Already up to date.` or a short fast-forward list. If it
says "non-fast-forward" / "divergent", stop and inspect with
`git -C ${REPO_DIR} log --oneline -20 origin/main` — do **not**
`reset --hard` without reading first.

### Step 2 — `docker compose build` (15-25 min cold, 2-3 min warm)

```bash
ssh "${DOCKER_HOST_SSH}" \
    "cd ${REPO_DIR} && sudo docker compose build 2>&1 | tee /tmp/build.log"
```

Expensive layers in order:

1. `apk add build-base ...` — 30s.
2. `git clone libapplegfx-vulkan + meson install` — 30-60s.
3. `curl qemu-10.2.2.tar.xz + tar xJ` — 2-4 min.
4. `./configure + make -j` — 10-15 min.
5. runtime-stage COPYs — 1-2 min.

Success looks like `=> => naming to docker.io/library/docker-macos-macos`.
Any non-zero exit → see Step 3.

### Step 3 — Common build failures + fixes

| Symptom (from build log) | Cause | Fix |
|---|---|---|
| `cp: cannot stat '.../pc-bios/apple-gfx-pci.rom'` | qemu-mos15 `origin/main` behind local. | `git -C /Users/mjackson/qemu-mos15 push`; re-run Step 2. |
| `C dependency libapplegfx-vulkan not found` | pkg-config name mismatch (library ships `applegfx-vulkan.pc`, overlay asks `libapplegfx-vulkan.pc`). | Add `filebase : 'libapplegfx-vulkan'` to `pkg.generate(...)` in libapplegfx-vulkan/meson.build, commit, push, retry. See dry-run §P0-2. |
| `undefined reference to 'apple_gfx_create_task'` (or ~5 similar) at link | `static` modifier hiding shell callbacks from pci-linux.c. | Drop `static` on the six callbacks in `apple-gfx-common-linux.c`, forward-declare in `apple-gfx-linux.h`. Dry-run §P0-3. |
| `implicit declaration of function 'trace_apple_gfx_pci_realize'` | Two trace events undefined. | Add two lines to `hw/display/trace-events` overlay, or delete the two `trace_apple_gfx_pci_*()` call sites. Dry-run §P0-4. |
| Build succeeds **but** Step 6 returns no apple-gfx-pci | Silent-drop: pkg-config mismatch with `required: false`. | Same fix as row 2 — do **not** skip it just because build was green. |
| `/bin/sh: bad substitution` mid-RUN | Dockerfile line-continuation corrupted by editor. | `git -C ${REPO_DIR} diff Dockerfile` on the host; restore from origin/main. |

After any fix: `git push` → Step 1 (pull on host) → Step 2 (rebuild).

### Step 4 — `docker compose up -d`

```bash
ssh "${DOCKER_HOST_SSH}" "cd ${REPO_DIR} && sudo docker compose up -d"
```

Expected: two container-ID lines (`macos-macos-1`, `novnc-1`). If
exits instantly or shows "Restarting", see triage "container exits
immediately".

### Step 5 — Verify the container is running

```bash
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker ps --filter name=macos-macos-1 --format '{{.Status}}'"
ssh "${DOCKER_HOST_SSH}" "sudo docker logs --tail 30 macos-macos-1"
```

Expected: `Up <N> seconds`, logs include `apple-gfx-pci: GPU_CORES=...
-> ...` and `Starting macOS VM (MAC=...)...`. If `Restarting` or
`Exited`, QEMU is crashing at launch — triage.

### Step 6 — Verify QEMU has `apple-gfx-pci`

The #1 silent failure mode. Probe the binary directly.

```bash
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker exec macos-macos-1 qemu-system-x86_64 -device help 2>&1 \
     | grep apple-gfx"
```

Expected:

```
name "apple-gfx-pci", bus PCI, desc "Apple Paravirtualized Graphics (PCI)"
```

Nothing? **Stop.** Build completed but meson silently dropped the
device. See triage "no apple-gfx-pci in binary".

### Step 7 — Watch the VM boot (2-4 min)

```bash
ssh "${DOCKER_HOST_SSH}" "sudo docker logs -f macos-macos-1" | head -200
```

Expected progression:

1. `OpenCore 1.0.7 ...` banner.
2. `EB|#LOG:EXITBS:START` — OpenCore exited boot services.
3. Kernel boot: `AppleSMC ... registered`, `IOBluetoothHCI`,
   `AppleKeyStore`, etc.
4. Eventually `loginwindow` or `WindowServer` lines.

Bail if: silent for 30s → container likely restarted, back to
Step 5; `panic(cpu N caller ...)` → triage "VM panics"; kernel
boot completes but no `loginwindow` after 3 min → triage "VM stuck
before login".

### Step 8 — SSH to the VM (once up)

Discover the VM IP via ARP after DHCP completes:

```bash
ssh "${DOCKER_HOST_SSH}" \
    "arp -a | grep -i \$(sudo docker exec macos-macos-1 \
                        cat /sys/class/net/macvtap0/address)"
```

Then:

```bash
export VM_SSH="matthew@<vm-ip-from-arp>"
ssh "${VM_SSH}" true
```

First-boot expected wait: 2-4 min after Step 5. Unreachable after
5 min → triage "SSH to VM fails".

### Step 9 — Run `tests/verify-m1.sh`

```bash
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m1.sh
```

Expected last line: `=== M1 gate: PASSED ===`. Any earlier `FAIL`
names the step that tripped; match the exit code against the
script's preamble (10 build / 20 container / 30 device-missing /
40 boot-timeout / 50 panic / 60 baseline-regression).

### Step 10 — Baseline the rest

M1 green does not retire M2-M5 scaffolds. Run them for a
pre-vs-post snapshot:

```bash
VM="${VM_SSH}" ~/mos/docker-macos/tests/verify-modes.sh
VM="${VM_SSH}" ~/mos/docker-macos/tests/verify-phase1.sh
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m2.sh
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m3.sh
```

Save the outputs — deltas are de-risking evidence for the next
milestone.

---

## 2. Triage

Each case: symptom → likely cause → fix.

**Build fails on libapplegfx-vulkan meson step.**
`meson setup` or `ninja install` aborts. origin/main is behind
local; missing `src/device.c` / `src/mmio.c` / `src/display.c` /
`pkg.generate(...)`. Push local, re-run. If it recurs, tag
`v0.0.1` and pin `git clone --branch v0.0.1` in the Dockerfile.

**Build fails on QEMU overlay (`cp`).**
`cp: cannot stat '/tmp/qemu-mos15-main/...'`. Tarball does not
contain the file. Confirm via GitHub UI; push if missing. Clear
any stale `/tmp/qemu-mos15-main` on the host. Overlay order is
`hw/display/*` → `pc-bios/*` → `./configure`; do not re-order.

**Container exits immediately.**
`docker ps` shows `Restarting`; logs say `required file not found`
or `cannot execute binary file`. Almost always the
Alpine-musl / glibc mismatch — a glibc-built QEMU ended up in the
Alpine runtime. Rebuild via `docker compose build` (which builds
inside Alpine). Do **not** scp a host-built QEMU in for M1.

**VM panics.**
`panic(cpu N caller ...)` in logs. Capture a noVNC screenshot (see
§3) and `docker logs --tail 200`; file the bug report (§4). If
the panic mentions `AppleParavirtGPU` or `apple-gfx`, it is our
decoder returning 0 for an offset the kext KASSERTs on. Dry-run §5
estimates ~40% probability on first boot — expected failure mode.

**No `apple-gfx-pci` in the binary (Step 6 empty).**
pkg-config silently returned not_found with `required: false`; the
source_set gate was false; binary built without the device. Fix:
align pkg.generate `filebase` in libapplegfx-vulkan/meson.build
with the `dependency('libapplegfx-vulkan')` consumer in the QEMU
overlay (see §P0-2 of dry-run). Push both ends, rebuild.

**VM boots but no `apple-gfx-pci` in guest `ioreg`.**
`ssh "${VM_SSH}" "ioreg -lw0 | grep -i apple-gfx"` empty. Verify
the QEMU cmdline actually passes it:

```bash
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker exec macos-macos-1 sh -c \
     'cat /proc/1/cmdline | tr \"\\0\" \" \"'" \
   | grep -o 'apple-gfx-pci[^ ]*'
```

Nothing? Stale `launch.sh` bind-mount or env override. Check
`docker-compose.yml` has `./launch.sh:/opt/macos/launch.sh:ro`,
then `sudo docker compose up -d --force-recreate`.

**SSH to VM fails.**
Check (1) boot completed — `docker logs --tail 100 macos-macos-1 |
grep loginwindow`; (2) DHCP lease — `arp -a` on host; (3) SSH
service on guest (`sudo systemsetup -setremotelogin on`; one-time
setup in `SETUP.md`). If lease missing, `HOST_IFACE` in
`docker-compose.yml` is wrong — `ip addr show` on the host to find
the real NIC name (default `eth0`; many hosts use `enp3s0`).

**VM stuck before login.**
No `loginwindow` line after 3+ min, no panic. Screenshot noVNC;
the visual (black, Apple-logo frozen, progress-bar stopped) points
at different root causes. M1 gate is "no panic", not "reaches
login" — re-run `verify-m1.sh` and note whether it exits 0 with
WARNs or 50 (panic).

---

## 3. Common commands

**Capture a noVNC screenshot.** Browser path:

```bash
open "http://${DOCKER_HOST_SSH#*@}:6080/vnc.html"
# right-click-save the viewport
```

Headless:

```bash
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker exec macos-macos-1 sh -c \
     'apk add --no-cache vncsnapshot > /dev/null 2>&1; \
      vncsnapshot -passwd /dev/null 127.0.0.1:5901 /tmp/shot.png' && \
     sudo docker cp macos-macos-1:/tmp/shot.png /tmp/shot.png"
scp "${DOCKER_HOST_SSH}":/tmp/shot.png ./m1-novnc.png
```

**Restart just QEMU without a full rebuild:**

```bash
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker exec macos-macos-1 sh -c 'kill -TERM 1'"
# Compose's restart policy re-execs launch.sh → new QEMU.
```

**Reset NVRAM (OpenCore boot-order recovery):**

```bash
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker exec macos-macos-1 touch /data/.reset-nvram && \
     sudo docker restart macos-macos-1"
```

`launch.sh` checks for the marker at startup and re-copies
`OVMF_VARS.clean.fd` over `OVMF_VARS.fd`.

**Fast-iterate a QEMU binary (post-M1 only).**
See `docs/qemu-mos15-build.md` "Fast-iterate build (host + swap)".
Do not use for M1 first light — it bypasses the Dockerfile, so
failures say nothing about whether `docker compose build` works.

**Tail a long-running build unattended:**

```bash
ssh "${DOCKER_HOST_SSH}" \
    "cd ${REPO_DIR} && \
     nohup sudo docker compose build > /tmp/build.log 2>&1 &"
# Come back later:
ssh "${DOCKER_HOST_SSH}" "tail -50 /tmp/build.log"
```

---

## 4. Bug-report checklist

For anything that does not match a §2 triage case. The minimum
viable bug report:

```bash
# SHAs — proves which tree was actually built
ssh "${DOCKER_HOST_SSH}" "git -C ${REPO_DIR} rev-parse HEAD"
git -C /Users/mjackson/libapplegfx-vulkan rev-parse HEAD
git -C /Users/mjackson/qemu-mos15         rev-parse HEAD
git -C /Users/mjackson/mos-opencore       rev-parse HEAD 2>/dev/null || echo n/a

# compose logs + build log
ssh "${DOCKER_HOST_SSH}" "sudo docker logs --tail 200 macos-macos-1" \
    > ./macos-tail.log
ssh "${DOCKER_HOST_SSH}" "tail -200 /tmp/build.log" > ./build-tail.log

# host identity
ssh "${DOCKER_HOST_SSH}" "uname -a"
ssh "${DOCKER_HOST_SSH}" "vulkaninfo --summary 2>&1 | head -40"

# noVNC screenshot if VM reached that far (see §3)
```

Attach all of the above plus a one-paragraph description of which
step in §1 failed and what the log said. Without the SHAs the
report is unactionable — half the predicted failures are "origin
was behind local".

---

## 5. Estimated total time

- Everything green first attempt: **45-60 minutes**.
- One issue to work through: **2-3 hours**.
- Two or more issues (typical first run): **4-6 hours** — at that
  point stop, escalate, file the bug report (§4) rather than grind.

If 3 hours in with no green signal on any step, hand off. It is
outside operator-runbook territory and almost certainly a
developer-side fix (missing push, patch in wrong repo, etc.).

---

## 6. Exit state — "M1 green"

All five must be true:

1. `docker compose build` exits 0.
2. `docker ps --filter name=macos-macos-1 --format '{{.Status}}'`
   shows `Up <N> minutes`.
3. `docker exec macos-macos-1 qemu-system-x86_64 -device help |
   grep '^name "apple-gfx-pci"'` returns a line.
4. `docker logs --tail 2000 macos-macos-1 | grep -E
   'panic\(cpu|Kernel trap'` returns nothing.
5. `tests/verify-m1.sh` exits 0.

Phase-2-forward observables (login screen via noVNC, kext probe
log lines, etc.) are **nice to have**, not M1 gates. M1 is "stack
wired end to end and does not crash", not "pixels render". Black
screen + no panic = still M1 green.

Once M1 is green, next work is **R1 — ring-buffer GPA mechanics
runtime capture** (`~/mos/memory/project_100pct_target.md`
open-confidence-lift targets). That de-risks M2-M5 in one shot and
is the highest-value next step. M1 runbook done; move on.
