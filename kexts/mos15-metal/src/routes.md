# Route-resolution strategy for mos15-metal (Phase -1.A.4)

Closed by Phase -1.A.4 of the Software Metal plan. Live-verified on
the VM on 2026-04-19.

## Question

Does `mos-patcher`'s hardcoded resolver fallback block Metal work,
where the primary kext is `IOAcceleratorFamily2` or
`AppleParavirtGPU` instead of `IONDRVSupport`?

## What we did

Replaced the hardcoded `com.apple.iokit.IOGraphicsFamily` fallback
with a caller-supplied **NULL-terminated array** of kext bundle
ids. Element 0 is primary (required); subsequent non-NULL entries
are fallbacks tried in order when primary lookup misses. Passing a
1-entry chain `{primary, NULL}` disables fallback.

New signature (mos-patcher):

```c
int mp_route_on_publish(const char *class_name,
                        const char *const *kext_bundle_ids,
                        mp_route_request_t *reqs,
                        size_t count);
```

QDP's call site (docker-macos) now declares its chain explicitly:

```cpp
static const char *const qdp_kexts[] = {
    "com.apple.iokit.IONDRVSupport",     // primary
    "com.apple.iokit.IOGraphicsFamily",  // base-class fallback
    nullptr
};
mp_route_on_publish("IONDRVFramebuffer", qdp_kexts, reqs, n);
```

## Why an array and not a single fallback

Inheritance depth isn't always two. For Branch A (AppleParavirtGPU
attaches), a natural chain is
`AppleParavirtGPU → IOAcceleratorFamily2 → IOGraphicsFamily` — three
deep. A fixed primary+fallback API couldn't express it. The array
form scales to any depth with no further API surface.

## Zero regression

Post-deploy on the VM:

- `kextstat`: mos15-patcher, QDP, mos15-metal all loaded
- `ioreg -c IONDRVFramebuffer`: `MPMethodsHooked=24`, `MPMethodsMissing=0`
- `MPStatus` string character-for-character identical to the
  pre-change baseline:
  `Pf Pf Pf Pf Pf Pf PX PX PX PX PX PX PX Pf PX Pf Pf Pf Pf Pf Pf Pf Pf Pf`
- `verify-modes.sh` 8/8
- `metal-probe` count=0 (monotone rule)
- No panic

## What this unlocks for Metal

When Phase 1.1 declares its route table, mos15-metal will pass the
appropriate chain for the active branch:

- **Branch A** (AppleParavirtGPU attaches, -1.D positive):
  ```c
  static const char *const kexts[] = {
      "com.apple.driver.AppleParavirtGPU",
      "com.apple.iokit.IOAcceleratorFamily2",
      nullptr
  };
  ```
- **Branch B** (we publish our own IOService):
  ```c
  static const char *const kexts[] = {
      "com.docker-macos.kext.mos15Metal",
      nullptr
  };
  ```

No further mos-patcher changes needed for either branch.

## Gating test for -1.A.4

> "Compile + deploy either path; empty kext still loads; no test regressions."

Satisfied:

- mos-patcher rebuilt with array API, deployed into
  `docker-macos/kexts/deps/mos15-patcher.kext`.
- QDP rebuilt against new API, deployed.
- mos15-metal (empty scaffold) still loads — kextstat idx 59,
  `mos15-metal: start` breadcrumb present.
- QDP MPStatus byte-for-byte identical → zero regression to
  existing consumer.
- verify-modes.sh 8/8, metal-probe count=0.
