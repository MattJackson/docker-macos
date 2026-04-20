# Route-resolution strategy for mos15-metal (Phase -1.A.4 verdict)

Closed by Phase -1.A.4 of the Software Metal plan. Live-verified
against the current VM on 2026-04-19.

## Question

Does the mos-patcher symbol resolver's hardcoded fallback kext
(`com.apple.iokit.IOGraphicsFamily`, `src/notify.cpp:118`) block
Metal work, where the primary kext is
`com.apple.iokit.IOAcceleratorFamily2` or
`com.apple.driver.AppleParavirtGPU`?

## Verdict

**No — `MP_ROUTE_EXACT` against the right primary kext covers every
Metal-work hook we have in scope through Phase 3.** No mos-patcher
change needed for -1.A exit.

## Evidence

Live `ioreg -c IONDRVFramebuffer` shows QDP's 24-hook status string:

```
MPMethodsHooked  = 24
MPStatus         = "Pf Pf Pf Pf Pf Pf PX PX PX PX PX PX PX Pf PX Pf Pf Pf Pf Pf Pf Pf Pf Pf "
MPMethodsMissing = 0
```

Legend (`mos15-patcher/src/notify.cpp:152`): one char per route,
where MP_ROUTE_PAIR emits two routes (derived + base).

- `P` — primary kext resolved AND vtable slot patched
- `F` — fallback kext resolved AND slot patched
- `u` / `f` — resolved but slot not present in this instance
- `X` — unresolved

All 24 hooked methods land on `P` (derived resolved via primary =
`IONDRVSupport`). The `f`/`X` entries are the *secondary* base-class
lookups that MP_ROUTE_PAIR also emits — they don't add to the hook
count when the derived route already won, and their outcome doesn't
affect functionality. **The IOGraphicsFamily fallback is useful for
belt-and-suspenders but is not load-bearing** even for the
framebuffer case.

## Applied to Metal

When we hook `IOAccelerator` subclass methods:

- **Branch A** (AppleParavirtGPU attaches, Phase -1.D): primary =
  `com.apple.driver.AppleParavirtGPU`. Subclass overrides resolve
  via primary. Inherited-but-not-overridden base methods resolve
  against `IOAcceleratorFamily2` — handled by passing explicit
  mangled names to `MP_ROUTE_EXACT` and using `mp_route_kext` for
  kext-scoped resolution. The hardcoded `IOGraphicsFamily` fallback
  is irrelevant (we don't route through it).
- **Branch B** (we publish our own IOAccelerator, -1.B/-1.C):
  primary = our own kext. Same pattern; no upstream dependency.

## What this does *not* commit us to

- Phase 1.1.2 will enumerate exact mangled names with `nm`/`otool`
  against the running kernel binaries. If that pass reveals a
  surface where an `IOAcceleratorFamily2`-hosted base method is
  needed *via fallback* (i.e., MP_ROUTE_PAIR semantics against an
  AppleParavirtGPU subclass where the derived route misses),
  parameterizing the fallback in `mp_route_on_publish` becomes a
  small targeted diff then — not now.
- Phase -1.B may change the primary-kext identity (if we ship a
  stub plugin bundle and publish our own IOService). Route table
  is re-scoped then.

## Gating test for -1.A.4

> "Compile + deploy either path; empty kext still loads; no test regressions."

Satisfied by the -1.A.3 deploy:

- `mos15-metal.kext` compiles (Phase -1.A.1).
- Deploys and loads on boot (Phase -1.A.3; `kextstat` idx 59,
  `IOMatchedAtBoot=Yes` in ioreg, `mos15-metal: start` breadcrumb).
- `verify-modes.sh` remains 8/8. `metal-probe` remains count=0
  (monotone floor).
- No mos-patcher change — QDP's route table unchanged, still 24/24
  hooked with 0 missing.
