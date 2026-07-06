# plugin-simulator — CoreSimulator

> **Phase H · Plugin id:** `dev.cleaner.simulator` · **Target release:** v0.5 ·
> **Depends on:** plugins/README, plugin-xcode (adjacent scope), 13, 14, 16, 19, 00 Art. 4/5.

Cleans Apple's CoreSimulator storage: unavailable/old runtimes, orphaned or derived device data,
and per-device caches. Distinct from `dev.cleaner.xcode` (which owns `CoreSimulator/Caches` only);
this plugin owns the **device and runtime** subtrees, which can be huge (each device is a full
disk image; each runtime is a multi-GB OS image).

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.simulator", name: "iOS Simulators", category: .developer,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [
        RootSpec(base: .developer, glob: "CoreSimulator/Devices/**"),   // per-device data
        RootSpec(base: .developer, glob: "CoreSimulator/Caches/dyld/**"),
        // Runtimes live under a Library path handled read-only via native analysis + simctl probe:
        RootSpec(base: .developer, glob: "CoreSimulator/Profiles/Runtimes/**"), // user-installed runtimes
    ],
    defaultRisk: .medium,                       // devices/runtimes CAN hold app state & test data
    capabilities: [.dryRun, .estimate, .rollback, .audit],
    requiresElevation: false, trust: .firstParty)
```

Scope boundary: only `~/Library/Developer/CoreSimulator`. It never deletes the *booted* device,
never a device with unsaved app data unless explicitly confirmed, and never system-installed
runtimes shipped inside Xcode.app (Art. 5 protects the app bundle).

## 2. What it targets

| Sub-item | Path leaf | Why junk / regenerates | Risk |
|---|---|---|---|
| Unavailable devices | `Devices/<UUID>/` whose runtime is gone | `simctl` marks them "unavailable"; unusable until the runtime returns. | 🟡 |
| Orphaned device data | `Devices/<UUID>/` not in `device_set.plist` | Not registered with CoreSimulator; leftover. | 🟢/🟡 |
| Per-device caches | `Devices/<UUID>/data/Library/Caches`, `tmp`, logs | Regenerated on boot. | 🟢 |
| Old runtimes | `Profiles/Runtimes/<name>.simruntime` for retired OS | Re-downloadable from Apple; multi-GB. | 🟡 |
| dyld shared cache | `Caches/dyld/**` | Rebuilt on demand. | 🟢 |

Does **not** target: a **booted** device, a device flagged as holding user-authored test data
(see §3), the default device set registration file, or runtimes bundled with Xcode.

## 3. Detection signals & algorithm

**Native path analysis is primary; `simctl` corroborates.**

1. Parse `~/Library/Developer/CoreSimulator/Devices/device_set.plist` natively → the set of
   registered device UUIDs, their runtime identifiers, and names. A `Devices/<UUID>` directory
   **absent** from this plist → `Evidence.orphaned` (🟢 if also stale, 🟡 otherwise).
2. For each registered device, read `<UUID>/device.plist` → `runtime` identifier and `state`.
   - If the runtime identifier is not among installed runtimes → **unavailable** → 🟡.
   - `state == 3` (booted) → **never** cleaned; skip with rationale "device is booted."
3. **User-data guard:** inspect `<UUID>/data/Containers/Data/Application/` — if it contains app
   containers with recent `mtime` (< 30 days) or Finder-tagged files, escalate that *device* to
   🔴 and never pre-select ("may hold manual test data / screenshots"). Per-device *caches*
   (`data/Library/Caches`, `tmp`) are always 🟢 regardless.
4. Runtime staleness: parse each `.simruntime`'s `Info.plist` (`CFBundleShortVersionString`) →
   apply spec 19 versions-behind threshold; keep the newest N unselected.
5. `FindingID = "sim:<subcategory>:<canonicalPath>"` (deterministic, DM-7).

The `simctl` fallback (§8) provides authoritative device *availability* and *booted* state when
plist parsing is ambiguous.

## 4. Roots / paths with justification

| RootSpec | Resolves to | Justification |
|---|---|---|
| `.developer / CoreSimulator/Devices/**` | `~/…/CoreSimulator/Devices/<UUID>/` | Simulator device images; under the dev anchor; per-device confirmable via plist. |
| `.developer / CoreSimulator/Profiles/Runtimes/**` | `~/…/CoreSimulator/Profiles/Runtimes/iOS 15.simruntime` | User-installed runtimes (Xcode 14+ downloadable runtimes) live here; re-downloadable. |
| `.developer / CoreSimulator/Caches/dyld/**` | `~/…/CoreSimulator/Caches/dyld/` | Pure regenerable cache. |

Runtimes bundled *inside* `Xcode.app` are not declared (the app bundle is protected, Art. 5).

## 5. Risk & safety scoring

| Sub-item | Risk | Score inputs |
|---|---|---|
| Orphaned device (no data, stale) | 🟢 88 | unregistered, no user data, old |
| Unavailable device | 🟡 70 | runtime gone; may still hold state |
| Device w/ recent app containers | 🔴 35 | possible user test data → never pre-select |
| Per-device cache/tmp | 🟢 92 | pure cache |
| Old runtime | 🟡 72 | re-downloadable, multi-GB |
| Booted device | — | excluded (skip) |

Plugin lowers scores with evidence only (DM-2). A device flagged for user data gets
`recoverability = .manual` at best (re-create + re-run tests) — but if it looks like *captured*
data (screenshots, DB snapshots), 🔴 stands.

## 6. Recoverability & staging

- `Disposition = .stage` for all (Principle 2). Staging a multi-GB device dir uses same-volume
  `renameat` (atomic, no copy — spec 16 §11), so it is fast and cheaply reversible.
- `Recoverability`: devices/runtimes = `.manual` (re-create device / re-download runtime via
  `simctl` or Xcode), caches = `.manual`.
- `RollbackHint`: `restoreFromStaging`, note "restoring a device does **not** re-register it with
  CoreSimulator; run `xcrun simctl` or re-open Xcode to re-detect." (honest limitation.)

## 7. Dry-run / estimate

- `estimate`: recursive `allocatedSize` per device/runtime (CC-10). Simulator disk images are
  often sparse → `isSparse` respected, only allocated blocks counted; `confidence = .exact` unless
  sparse anomalies detected.
- `--dry-run` lists devices grouped by (available / unavailable / orphaned / booted-excluded) and
  runtimes by version, with the 🔴 user-data devices separated.

## 8. Shell fallback & its safety

`simctl` has **no native equivalent**; the plugin uses it read-only for ground truth:

- `context.process.run(["/usr/bin/xcrun", "simctl", "list", "-j", "devices"])` and
  `["/usr/bin/xcrun", "simctl", "list", "-j", "runtimes"])` — argv array, 10 s timeout, JSON
  parsed for `isAvailable`, `state`, `availabilityError`, and runtime `identifier`/`version`.
  Read-only. Never `simctl delete` / `erase` — **deletion is always the engine's staging**, never
  a `simctl` mutation (keeps the propose/dispose split and reversibility, Principle 2).
- If `simctl` is unavailable (no Xcode CLT) or times out → fall back to native `device_set.plist`
  parsing (§3); scan still succeeds with slightly weaker availability evidence.

Justification: CoreSimulator exposes no public Foundation API for device availability/boot state;
`simctl -j` is the documented interface. The mutating subcommands are deliberately not used.

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Booted device swept | `state == 3` (or `simctl` "Booted") → hard skip. |
| Device holding manual test data/screenshots | Recent app containers / tags → 🔴, never pre-select. |
| Orphan is actually mid-creation by Xcode | `isOpenOrLocked` on `device.plist` → skip (spec 16 §8). |
| Runtime in use by a booted device | Cross-check: a runtime referenced by any booted device → not removable. |
| `simctl` and plist disagree | Prefer the *more conservative* (keep) signal; if either says booted/available, don't pre-select. |
| Sparse simulator images overstate size | `isSparse` → count allocated only (spec 16 §4.2). |
| Overlap with `dev.cleaner.xcode` on `CoreSimulator/Caches` | Xcode owns `Caches/**` broadly; this plugin scopes to `Caches/dyld/**` + `Devices`/`Runtimes`; engine de-dups (spec 13 OQ-13.3). |

## 10. Test cases

- **T1 device absent from device_set.plist, mtime 200d** → 🟢 orphan, pre-selected.
- **T2 device with runtime id not installed** → 🟡 unavailable.
- **T3 booted device (state 3)** → skipped.
- **T4 device with app container modified yesterday** → 🔴, not pre-selected.
- **T5 old runtime `iOS 14.simruntime`, newest present iOS 17** → 🟡, keepLatestN respected.
- **T6 simctl unavailable** → native plist path used; scan succeeds.
- **T7 simctl says available but plist missing** → conservative keep (not pre-selected).
- **T8 sparse device image** → estimate counts allocated blocks only.

## 11. Config keys

`plugins.simulator`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `removeUnavailable` | bool | `true` | Surface unavailable devices. |
| `removeOrphaned` | bool | `true` | Surface unregistered device dirs. |
| `runtimes.keepLatestN` | int | `2` | Keep N newest runtimes unselected. |
| `userDataAgeDays` | int | `30` | App-container mtime under which a device escalates to 🔴. |
| `useSimctl` | bool | `true` | Allow read-only `simctl -j` probe. |

## Open Questions

- **OQ-sim.1** Should "erase device contents" (clear `data/` but keep the device registered) be a
  distinct, lower-risk action than removing the whole device? *Leaning: yes as a v1.0 sub-action;
  it is 🟢 and reclaims most of the size.*
- **OQ-sim.2** Detect runtimes bundled in Xcode vs. user-downloaded reliably without shelling?
  *Leaning: user runtimes live under `CoreSimulator/Profiles/Runtimes`; bundled ones are inside
  the app and simply not declared.*
- **OQ-sim.3** How to correlate a device to "manual test data worth keeping" beyond mtime/tags —
  screenshot detection heuristics? *Leaning: mtime+tags for v1; defer content heuristics.*

## Dependencies

**Consumes:** 13 (contract, `process` fallback), 14 (types), 16 §4.2/§8/§9/§11 (sparse, in-use,
canonicalization, rename-stage), 19 (versions-behind), 00 Art. 4/5. **Feeds:** 20 (stages
devices/runtimes), 22 (finalizes scores), 25 (grouping), and pairs with plugin-xcode on the
`CoreSimulator` subtree boundary.
