# 19 — Detection Algorithms

> **Phase D · Depends on:** 00-constitution (Principle 1 safety-over-savings, Art. 4 risk/score,
> "not hardcoded paths — combine metadata signals"), 10-tech-stack (CryptoKit SHA-256, xxHash,
> swift-collections `Heap`), 13-plugin-architecture (detection lives *inside* plugins; propose-only),
> 14-domain-model (`Finding`, `Item`, `Evidence`, `RiskLevel`, `SafetyScore`, `Recoverability`,
> `FindingID` DM-7), 16-filesystem-strategy (Evidence signals: whereFroms, lastUsed, hardlink
> clusters, clones, `getattrlistbulk`), 17-scan-engine (driven walk), 18-rule-engine (rules refine
> detection output) · **Depended on by:** 20 (cleanup acts on findings), 22 (safety scorer consumes
> the same signals), and every `specs/plugins/*`.

## 1. Purpose & scope

This spec defines the **smart-detection heart** of cleaner-cli. Per the Constitution, detection is
**not hardcoded paths** — every classifier combines **metadata signals** (`Evidence`, spec 16 §5/6)
into a decision, so the tool generalizes beyond a fixed path list and *explains* itself (Principle
8). Hardcoded well-known paths are used only as **priors/anchors** (a `RootSpec` says "look here"),
never as the sole justification for deleting.

Each algorithm below is specified with a fixed template:

- **Goal** — what it detects.
- **Inputs** — which `Evidence` signals (spec 16) it consumes.
- **Algorithm** — concrete steps.
- **False-positive mitigations** — how we avoid deleting something needed (Principle 1).
- **Risk & recoverability** — how it maps to `RiskLevel`/`Recoverability`/`SafetyScore` (Art. 4).
- **Complexity** — time/space, tied to NFR-001/002/010.

All algorithms run *inside plugins* (spec 13) via the injected read-only providers; they emit
`Finding`s that the engine re-scores (gate ①) and re-guards (gate ③). Detection **proposes**;
it never deletes. `FindingID` is derived deterministically (DM-7): `"<pluginID>:<canonicalPrimaryPath>"`,
plus a content-hash discriminator only for duplicate findings (OQ-14.1).

## 2. Shared signal primitives

Reused across algorithms; each maps to `Evidence` (spec 14 §4.7) populated by spec 16.

```swift
struct DetectionSignals: Sendable {                 // a lens over Evidence + injected clock
    let now: Date                                   // ClockReading (Principle 5 determinism)
    let ev: Evidence
    // Derived helpers:
    var ageMTime: Duration? { ev.mtime.map { now - $0 } }
    var ageLastUsed: Duration? { (ev.lastUsedDate ?? ev.atime).map { now - $0 } }   // spec 16 §5
    var isRedownloadable: Bool { (ev.whereFroms?.isEmpty == false) }
    var isUserAuthored: Bool { (ev.finderTags?.isEmpty == false) }                  // lowers score
    var onDisk: Int64 { ev.allocatedSize ?? 0 }                                     // reclaim basis
    var isProtectedShape: Bool { (ev.isDataless ?? false) || ev.snapshotRef != nil }
}
```

**Recency source of truth (spec 16 §5):** prefer `kMDItemLastUsedDate` (Spotlight) over `atime`
(unreliable under `relatime`/`noatime`; treat `atime` as a *lower-bound* only, OQ-14.4). When both
are absent, recency is **unknown** → detectors treat unknown conservatively (do not claim "stale").

**Score composition.** Each detector proposes a `SafetyScore` from weighted signals; the shared
scorer (spec 22) has final authority and may only *lower* it (DM-2). Common weights:
`+regenerability`, `+redownloadable (whereFroms)`, `+age`, `−userAuthored (tags)`,
`−in-use/locked`, `−irreplaceable-kind`.

## 3. Real-vs-fake cache classification

**Goal.** Decide whether a directory *named* like a cache (or under a cache anchor) is a **true
regenerable cache** (safe) vs. a **misnamed store of real data** (e.g. an app that keeps its only
copy of user content under `~/Library/Caches`). The Constitution forbids trusting the name alone.

**Inputs.** `spotlightKind` of children, `whereFroms`, `mtime`/`lastUsedDate` distribution,
child file-type histogram, presence of `finderTags`, existence of a sibling "canonical" store,
write-frequency (many recent small writes ⇒ live cache).

**Algorithm.**
1. Sample the directory's children (bounded: first *K*=256 by streaming, spec 16 §2 — never load
   all).
2. Build a **type histogram** from `spotlightKind`/extension: cache-typical (`.cache`, `.db`,
   `.ldb`, hashed blob names, `.tmp`, sqlite WAL) vs. user-typical (`Documents`, images, videos,
   source code, office docs).
3. Compute **regenerability score** `r`:
   - `+` high proportion of hashed/opaque names, `.cache`/`.tmp`/sqlite;
   - `+` `whereFroms` present on many children (downloaded/derived);
   - `+` a known cache marker file (`CACHEDIR.TAG` per the Cache Directory Tagging spec — a strong
     positive signal; if present, treat as true cache with high confidence);
   - `−` presence of user-authored kinds (documents, media), `finderTags`, or unique extensions;
   - `−` the directory is the *only* copy of something (no regenerating producer detectable).
4. Classify: `r ≥ τ_high` → **true cache** (safe); `τ_low < r < τ_high` → **medium** (regenerable
   but costly / uncertain); `r ≤ τ_low` → **not a cache** → do **not** flag (or flag `dangerous`
   for user review only).

**False-positive mitigations.**
- `CACHEDIR.TAG` present → decisive true-cache (industry-standard opt-in marker).
- Any user-authored kind or Finder tag in the sample → cap risk at `medium` and lower score.
- Never rely on the parent being named "Caches" (Principle: not hardcoded paths).
- Streaming sample only; a huge cache is not fully read.

**Risk & recoverability.** true cache → `safe`, `recoverability = manual` (regenerated).
uncertain → `medium`. contains user data → `dangerous` (or excluded).

**Complexity.** O(K) sampled children per directory; O(1) memory (histogram counters).

## 4. Build-artifact detection

**Goal.** Identify compiler/build outputs (object files, `DerivedData`, `target/`, `build/`,
`.gradle`, `dist/`, `__pycache__`, `.next`, `Pods`) that a build regenerates.

**Inputs.** Presence of a **producer** (a project/build file that regenerates the artifact:
`Package.swift`, `*.xcodeproj`, `Cargo.toml`, `package.json`, `pom.xml`, `Makefile`), directory
name convention (prior only), child-type histogram (object files `.o`/`.class`/`.pyc`,
`whereFroms` absent — locally produced), `mtime` recency.

**Algorithm.**
1. From an artifact candidate dir, locate the **owning project** by walking up to the nearest
   ancestor containing a producer manifest (bounded depth).
2. Confirm the artifact is *derived*: child histogram dominated by compiled objects / no
   `whereFroms` (locally built, not downloaded) / matches the toolchain's known output layout.
3. If a producer exists and is intact → artifact is **regenerable** (safe). If the producer is
   **gone** (orphaned build dir) → hand off to §16 (zombie/orphan) — still safe but noteworthy.

**False-positive mitigations.**
- Require a producer *or* an unambiguous artifact signature (e.g. `DerivedData/<Name>-<hash>/Build`).
  A bare `build/` with source files inside and no producer → do not assume; downgrade to `medium`.
- Exclude anything with `finderTags` or user documents mixed in.
- Never delete the producer/manifest itself (it is source, not artifact).

**Risk & recoverability.** `safe`, `recoverability = manual` (rebuild). Costly rebuilds
(large C++/Rust targets) → the plugin may present `medium` to warn of rebuild time (Art. 4.1
"regenerated but costs time").

**Complexity.** O(ancestor depth) for producer lookup + O(K) sample. Producer existence check is
a single `stat` (spec 16), cached per project root within the scan.

## 5. Generated-file detection

**Goal.** Individual files that are machine-generated and reproducible (`*.pyc`, `*.class`,
`*.o`, `*.d`, `*.tsbuildinfo`, `Package.resolved` lockfiles are *not* generated-safe — excluded,
minified bundles with a source map + source present, `.DS_Store`).

**Inputs.** Extension/`spotlightKind`, presence of a sibling **source** whose `mtime` ≤ generated
file's `mtime` (source is older ⇒ generated is derived), `whereFroms` absent, generator marker
comments are *not* read (we do not open contents unless cheap & necessary; avoid dataless faults).

**Algorithm.**
1. Match a generated-file signature (extension + optional sibling-source rule).
2. Verify a **source predecessor** exists and is not newer than the generated file (`src.mtime ≤
   gen.mtime`), establishing the derive relationship without reading contents.
3. Emit per-file or coalesce into the parent artifact finding (§4) to avoid millions of tiny
   findings (coalesce when > N siblings share the signature).

**False-positive mitigations.**
- `.DS_Store` is always safe. Lockfiles (`Package.resolved`, `Cargo.lock`, `yarn.lock`,
  `Podfile.lock`) are **never** "generated-safe" — they pin builds; excluded from this detector.
- Require the source-predecessor check, not extension alone, for ambiguous cases.

**Risk & recoverability.** `safe`, `manual`.

**Complexity.** O(1) per file (a sibling `stat`); coalesced to keep finding count bounded (NFR-013).

## 6. Stale-cache detection (age + last-access)

**Goal.** Caches that are *valid* but haven't been used in a long time — reclaim without breaking
anything actively used.

**Inputs.** `lastUsedDate` (primary), `atime` (lower-bound fallback), `mtime`, category-specific
staleness threshold (config, spec 24), `whereFroms` (re-downloadable ⇒ safer).

**Algorithm.**
1. `age = now − max(lastUsedDate, mtime)` using the strongest available recency (spec 16 §5).
2. If `age ≥ threshold(category)` (e.g. 30 d for DerivedData, 90 d for logs) → **stale**.
3. Combine with §3 (must also be a real cache) — staleness only *strengthens* an already-safe
   cache; it does not by itself make user data deletable.

**False-positive mitigations.**
- Unknown recency (both `lastUsedDate` and `atime` nil) → **not** stale (Principle 1; RE-5 mirror).
- `atime` alone is a lower-bound (files may have been read without updating atime) → require
  `lastUsedDate` or `mtime` for the *safe* tier; `atime`-only staleness caps at `medium`.

**Risk & recoverability.** stale true-cache → `safe` with a score boost from age; `manual`.

**Complexity.** O(1) per item.

## 7. Duplicate FILE detection (multi-stage, clone-aware)

**Goal.** Find byte-identical files so the user can reclaim redundant copies — **without**
counting APFS clones or hardlinks as "duplicates" (they already share blocks; deleting one frees
nothing).

**Inputs.** `size` (logical), `allocatedSize`, `inode`, `hardlinkCount`/`isHardlink`,
`isClone`, `volumeID`; content via staged hashing (SHA-256, CryptoKit) with an xxHash prefilter
(spec 10).

**Algorithm (staged funnel — cheap→expensive, only escalate on collision).**

```
 ┌─ Stage 0: enumerate → (size, inode, volumeID) tuples ─────────────────────┐
 │  bucket by size. Singletons dropped (a unique size can't have a dup).      │
 └───────────────────────────────────────────────────────────────────────────┘
 ┌─ Stage 1: within a size bucket, collapse identity-sharing groups ─────────┐
 │  group by (volumeID, inode): same inode ⇒ HARDLINKS, not duplicates.       │
 │  APFS clone check: distinct inodes that share extents (Evidence.isClone /  │
 │  F_LOG2PHYS_EXT overlap, spec 16 §4.1) ⇒ CLONES, not duplicates.           │
 │  → these are reported as "shared-block groups" (§8-adjacent), NOT dupes.   │
 └───────────────────────────────────────────────────────────────────────────┘
 ┌─ Stage 2: cheap hash prefilter (xxHash64 of a HEAD+TAIL sample, e.g. 4 KiB │
 │  each + the size) within a size bucket. Splits the bucket into candidate    │
 │  groups; non-colliding files are dropped WITHOUT a full read.               │
 └───────────────────────────────────────────────────────────────────────────┘
 ┌─ Stage 3: full xxHash64 of entire content for surviving candidates ───────┐
 │  (fast, non-crypto) → finer split; drops near-misses cheaply.              │
 └───────────────────────────────────────────────────────────────────────────┘
 ┌─ Stage 4: SHA-256 CONFIRM on remaining collision groups only ─────────────┐
 │  cryptographic confirmation of true byte-identity (collision-safe).        │
 │  Optional final byte-compare on a hash tie for absolute certainty.         │
 └───────────────────────────────────────────────────────────────────────────┘
 → duplicate SET = files with identical SHA-256, EXCLUDING inode/clone-shared.
```

For each confirmed duplicate set of *n* identical files, the tool proposes keeping one
(**keeper policy**: oldest `birthtime`, or the one outside cache dirs, or user-chosen) and
staging the other *n−1*. **Reclaim** credits only *unshared* on-disk blocks (spec 14 §6): if the
copies are actually clones, reclaim ≈ 0 and they are *not* offered as dupes.

**False-positive mitigations.**
- Clone/hardlink exclusion (Stage 1) is mandatory — the headline correctness guarantee.
- SHA-256 confirmation (Stage 4) before any deletion; hashing runs on `< 5 %` of bytes in the
  common case (NFR-004) because size+prefilter eliminate most files.
- Never auto-select a keeper for duplicates that live under user-content roots
  (those are protected anyway) — deleting a "copy" can
  surprise a user who organized them deliberately.
- Dataless files excluded (never hashed — would trigger download, spec 16 §4.4).

**Risk & recoverability.** `medium` by default (user may want both copies); `instant` (staged).
Duplicates *within* a known cache → `safe`.

**Complexity.** Size bucketing O(n). Prefilter reads O(sampled bytes). Full hash only on
survivors. Worst case O(total colliding bytes) for SHA-256 but bounded to `< 5 %` typical
(NFR-004). Memory: hash groups keyed by digest, `Heap`/dictionary bounded by candidate count, not
n (NFR-002, dupe pass < 500 MB).

## 8. Duplicate CACHE detection

**Goal.** Detect redundant *copies of the same logical cache* across tools/versions (e.g. two npm
caches, duplicated model downloads, per-user duplicate Homebrew downloads) — coarser than file
dedup.

**Inputs.** Cache root signatures (manifest/index files), aggregate content digest (tree-manifest
hash, spec 15 §5), `whereFroms`, size, per-cache last-used.

**Algorithm.**
1. Identify cache roots (via §3 real-cache classification + known anchors).
2. Compute a **tree-manifest hash** per cache (sorted `(relpath, size, xxHash)` — same construct
   as staging integrity, spec 15 §5) — cheap, no full crypto.
3. Group caches with identical or high-overlap manifests (Jaccard over file-hash sets) → redundant
   copies; propose keeping the most-recently-used, staging the rest.

**False-positive mitigations.**
- Require high overlap (≥ τ, e.g. 0.9) — partial overlap is normal (shared base layers) and is
  *not* a duplicate.
- Version-aware: two caches for different tool versions are not duplicates even if overlapping.

**Risk & recoverability.** `safe`/`medium` (re-downloadable), `manual`.

**Complexity.** O(files) for manifest hashing (shared with dedup Stage 3 where possible); grouping
O(caches²) but #caches is small.

## 9. Large-file detection (top-N via bounded heap)

**Goal.** Surface the biggest space consumers for user review — *not* auto-deletable, purely
informational + user decision.

**Inputs.** `allocatedSize` (on-disk, spec 16 §3 — truthful), `spotlightKind`, `whereFroms`, path.

**Algorithm.**
1. Maintain a **bounded min-heap** of size *N* (default 100) keyed by `allocatedSize`
   (swift-collections `Heap`).
2. Stream the walk (spec 17); for each file, if `allocatedSize > heap.min` push and pop → heap
   holds the current top-N. O(1) memory regardless of tree size (NFR-002).
3. Emit top-N as `large-files` findings, annotated with kind and origin.

**False-positive mitigations.**
- Surfaced for review only, never auto-cleaned (`cleaner find large` is informational; user content
  requires an explicit choice). Disk images, VMs, media are surfaced, not recommended.
- Report on-disk (allocated) size so sparse/clone giants aren't overstated (spec 14 §6).

**Risk & recoverability.** `medium`/`dangerous` (likely user data); disposition user-chosen;
default `stage`.

**Complexity.** O(n log N) time (heap), O(N) memory — meets NFR-010 (bounded).

## 10. Old-file detection (atime/mtime + Spotlight)

**Goal.** Files untouched for a long time, for user review (downloads, forgotten installers).

**Inputs.** `lastUsedDate` (primary), `mtime`, `atime` (lower-bound), `birthtime`, `whereFroms`,
size threshold (only surface old files above a size floor to avoid noise).

**Algorithm.**
1. `age = now − max(lastUsedDate, mtime)` (spec 16 §5 recency preference).
2. If `age ≥ threshold` **and** `allocatedSize ≥ floor` → **old-file** finding.
3. Combine with §11 (downloads) for stronger signals (whereFroms + Downloads location + age).

**False-positive mitigations.**
- Unknown recency → excluded (Principle 1).
- Old ≠ unwanted: default `medium`, surfaced for review not auto-cleaned. `atime`-only age capped at `medium`.

**Risk & recoverability.** `medium`, user-chosen disposition, `manual`/`hard` (may be unique).

**Complexity.** O(1) per file.

## 11. Temporary-download detection

**Goal.** Detect re-downloadable / abandoned downloads (installers, DMGs, archives in
`~/Downloads`) that are safe to reclaim.

**Inputs.** `whereFroms` (download origin — strong signal), `quarantine` info (agent = browser),
Downloads-anchor location (prior), `spotlightKind` (`Disk Image`, installer `.pkg`), age, whether
a matching app is already installed (Launch Services, §12).

**Algorithm.**
1. File under Downloads anchor with `whereFroms`/`quarantine` present → downloaded artifact.
2. If it is an installer/disk-image kind **and** age ≥ threshold **and** (for `.pkg`/`.dmg`) the
   app it installs is already present (Launch Services) → **safe to remove** (re-downloadable, no
   longer needed).
3. Else `medium` (re-downloadable but maybe wanted).

**False-positive mitigations.**
- `whereFroms` origin recorded in the finding so the user sees exactly where to re-download
  (Principle 3/8) — reduces regret.
- Never touch files without `whereFroms`/`quarantine` in Downloads (could be user-created).
- Recent downloads (< 7 d) kept by the built-in rule (spec 18 §4 `ignore-recent-downloads`).

**Risk & recoverability.** installer w/ app installed → `safe`, `manual` (re-download).
generic download → `medium`, `hard` (may be sole copy).

**Complexity.** O(1) per file + one Launch Services lookup per installer candidate.

## 12. Unused-application detection

**Goal.** Apps installed but not used in a long time (user review; apps are user data → careful).

**Inputs.** Launch Services `LaunchServicesInfo` (registered, install/first-seen date,
`lastUsedByApp`), `kMDItemLastUsedDate` on the `.app`, running-process check (is it running now?),
bundle size (`allocatedSize`), whether it is a system/critical app (excluded).

**Algorithm.**
1. Enumerate installed apps via Launch Services (spec 16 §5).
2. For each: `idle = now − max(lastUsedByApp, lastUsedDate)`; `installedFor = now − installDate`.
3. Flag if `idle ≥ threshold` (e.g. 180 d) **and** not currently running **and** not a
   system/protected app. The `.app` bundle itself is protected from *cache* cleaning (Art. 5) but
   the *user* may choose to remove an unused app + its support files (Application Support, caches,
   preferences) as a group Item.

**False-positive mitigations.**
- Running-process check (spec 16 §8, `NSWorkspace` optional / process scan) — never flag a running
  app.
- System/Apple apps and apps under `/Applications` core set excluded (Art. 5).
- Long idle threshold — this removes user data, so the whole set is staged and recoverable via `cleaner undo`.
- Present the full removal set (bundle + Application Support + caches + prefs + LaunchAgents) so
  the user sees everything, and stage all (reversible).

**Risk & recoverability.** `dangerous` (it's an app the user installed), `manual` (re-install),
default `stage`, recoverable via `cleaner undo`.

**Complexity.** O(#apps) — small; one Launch Services + one running-check per app.

## 13. Orphan-package detection (Homebrew / npm / pod leaves)

**Goal.** Package-manager artifacts with no owner: Homebrew leaves/old versions, global npm caches
for uninstalled packages, orphaned CocoaPods, stale `node_modules` for deleted projects.

**Inputs.** Package-manager state via **sandboxed shell-out adapters** (spec 13 `ProcessRunning`:
`brew leaves`/`brew list --versions`, `npm cache`, arg-escaped, timeout-bounded — spec 36),
directory structure, `mtime`, project existence.

**Algorithm (Homebrew example).**
1. `brew list --versions` → installed formulae + versions; `brew --cellar` → cellar path.
2. Enumerate cellar; any version dir **not** in the "current" set → **old version** (safe to
   remove — brew keeps them after upgrades). `brew leaves --installed-on-request=false` style →
   dependency leaves no longer needed.
3. For npm: global cache entries whose package is not referenced by any project (best-effort) →
   stale cache.

**False-positive mitigations.**
- Prefer the package manager's own notion (its adapter output) over guessing from the filesystem.
- Adapter failure/timeout → skip the finding (spec 13 §9), never guess destructively.
- Only *old versions* and *manager-confirmed leaves* are `safe`; ambiguous → `medium`.

**Risk & recoverability.** old versions → `safe`, `manual` (reinstall). Leaves → `medium`.

**Complexity.** O(#packages) + adapter latency (bounded by timeout).

## 14. Obsolete-SDK detection

**Goal.** Old SDKs/toolchains no longer targeted (old Xcode `iOS DeviceSupport`, old command-line
tools, old NDKs).

**Inputs.** Version-encoded directory names (parsed, not hardcoded — extract semantic version),
the set of *currently installed* toolchains, `lastUsedDate`, device-support OS versions vs.
installed Xcode's supported set.

**Algorithm.**
1. Parse version tokens from SDK/support directory names.
2. Determine the "keep set": latest N versions and/or versions matching an installed active
   toolchain.
3. Anything outside the keep set and stale (`lastUsedDate`) → **obsolete**.

**False-positive mitigations.**
- Always keep the latest and the active toolchain's required versions.
- Keep-latest-N configurable (spec 24, e.g. `keepDerivedDataDays`, `keepLatestSimulators`).

**Risk & recoverability.** `safe`/`medium` (re-downloaded on next device connect / Xcode fetch),
`manual`.

**Complexity.** O(#SDK dirs).

## 15. Stale-DerivedData detection

**Goal.** Xcode `DerivedData/<Name>-<hash>` folders whose **source project no longer exists** or
hasn't been opened recently.

**Inputs.** DerivedData folder name (encodes project name + path hash), the `info.plist` inside
DerivedData that records the source `.xcodeproj`/`.xcworkspace` path, existence of that source
(`fs.exists`), `lastUsedDate` of the DerivedData dir.

**Algorithm.**
1. Read the DerivedData folder's `info.plist` `WorkspacePath` (cheap, small file — allowed read).
2. If the workspace path **does not exist** → **orphaned** DerivedData (source gone) → `safe`.
3. Else if it exists but `age ≥ threshold` → **stale** (safe, rebuildable).

**False-positive mitigations.**
- Prefer the recorded source path over the hash (robust to renames).
- Existing + recently-used project → keep (active development).
- DerivedData is always rebuildable → even orphaned is `safe` (no user data).

**Risk & recoverability.** `safe`, `manual` (rebuild on next open).

**Complexity.** O(#DerivedData dirs) + one small plist read + one `stat` each.

## 16. Old-simulator-runtime detection

**Goal.** Old iOS/watchOS/tvOS simulator runtimes and unavailable/dead simulator devices.

**Inputs.** `xcrun simctl list --json` (sandboxed adapter, spec 13), runtime versions, device
availability (`isAvailable == false` / "unavailable" runtimes), last-boot dates, keep-latest
config.

**Algorithm.**
1. Adapter → runtimes + devices JSON.
2. Flag runtimes marked unavailable, and runtimes older than keep-N (keeping the latest per OS
   family and any required by the active Xcode).
3. Flag "dead" devices (unavailable, no runtime).

**False-positive mitigations.**
- Keep latest per family + active-Xcode-required (like §14).
- Adapter failure → skip (never delete simulator data by guessing).

**Risk & recoverability.** `safe`/`medium` (re-downloadable runtime), `manual`.

**Complexity.** O(#runtimes+devices) + adapter latency.

## 17. Old-archive detection (.xcarchive)

**Goal.** Xcode `.xcarchive` bundles (build artifacts that *may be shipped/notarized builds* — the
Constitution's canonical `dangerous` example, spec 13 §12).

**Inputs.** `.xcarchive` `mtime`/`birthtime`, embedded `Info.plist` (app version, distribution
state), age threshold, whether an App Store/notarization record suggests it shipped.

**Algorithm.**
1. Identify `.xcarchive` bundles under the Archives anchor.
2. Age + version metadata → old archives beyond keep-N.
3. Present grouped by app for user review; surfaced, not auto-cleaned.

**False-positive mitigations.**
- `dangerous` by construction (Art. 4.1): an archive may be the only copy of a shipped build's
  dSYMs for symbolication — irreplaceable.
- Always `stage` (never purge default); staged and recoverable via `cleaner undo`.

**Risk & recoverability.** `dangerous`, `hard`/`none` (dSYMs may be irreplaceable → `none` forces
dangerous, DM-1), default `stage`, recoverable via `cleaner undo`.

**Complexity.** O(#archives) + one plist read each.

## 18. Unnecessary-localization detection (.lproj)

**Goal.** Remove `.lproj` localization bundles for languages the user never uses (space in large
apps/frameworks) — a classic "monolingual" cleaner.

**Inputs.** System preferred languages (`AppleLanguages` / `Locale.preferredLanguages`), the set
of `.lproj` dirs in a bundle, which app bundles are user-owned vs. system (Art. 5), bundle
signature (removing files from a **signed** bundle breaks its signature).

**Algorithm.**
1. Read system preferred languages → keep-set (+ `Base.lproj`, `en.lproj` fallback always).
2. For a candidate bundle, `.lproj` dirs not in the keep-set → removable.
3. **Signature guard:** if the bundle is code-signed, removing `.lproj` invalidates the signature
   → only offer for bundles where this is safe, or warn explicitly.

**False-positive mitigations.**
- Never strip system apps or `/System` (Art. 5).
- Always keep `Base.lproj` + English fallback + every system-preferred language.
- Code-signature breakage is a hard `dangerous`/exclude — stripping a signed app can prevent it
  launching. Default: **exclude signed bundles** in v1; offer only clearly-safe resource bundles.

**Risk & recoverability.** `medium` (re-installable), `manual`; signed bundles → excluded/`dangerous`.

**Complexity.** O(#bundles × #lproj).

## 19. Zombie-directory detection

**Goal.** Empty or near-empty leftover directories, and support/config directories whose owning
app is uninstalled (orphaned `~/Library/Application Support/<gone-app>`, `~/Library/Caches/<gone
bundleID>`, `~/Library/Preferences/<gone>.plist`, LaunchAgents pointing at missing binaries).

**Inputs.** Bundle-ID directory names, Launch Services (is this bundle ID still installed?),
emptiness (streamed child count), `mtime`, LaunchAgent plist `Program`/`ProgramArguments` path
existence.

**Algorithm.**
1. For a bundle-ID-named support/cache/prefs dir, ask Launch Services whether that bundle ID is
   registered/installed (spec 16 §5).
2. If **not installed** and stale → **orphaned support data** → `medium` (may hold user settings
   the user might want if they reinstall — hence not `safe`).
3. For LaunchAgents/Daemons: if the referenced program path doesn't exist → **dead agent** → safe
   to remove (it can never run).
4. Truly empty directories → `safe`.

**False-positive mitigations.**
- Bundle-ID installed-check via Launch Services, not name guessing.
- Orphaned *preferences/support* default `medium` (settings/licenses may live there) — user data
  bias (Principle 1). Only empties and dead agents are `safe`.
- Never remove `~/Library` structural dirs themselves.

**Risk & recoverability.** empty dir / dead agent → `safe`, `manual`. orphaned support → `medium`,
`hard`.

**Complexity.** O(#candidate dirs) + one Launch Services lookup each.

## 20. Filesystem-shape handling (symlink / hardlink / sparse / snapshot / clone)

These are **cross-cutting correctness rules** every detector obeys (spec 16 §4/6); summarized as a
decision table because they gate reclaim truth and safety:

| Shape | Signal (`Evidence`) | Detection behavior | Reclaim treatment |
|---|---|---|---|
| **Symlink** | `isSymlink` | Report the *link*, never the target; never follow out of root to delete target (Art. 4.4). | Link's own tiny size only. |
| **Hardlink** | `isHardlink`, `hardlinkCount>1` | Group by `(volumeID, inode)`; a "duplicate" that is a hardlink is **not** a dup (§7 Stage 1). | Blocks credited only if **all** links within roots are removed; else `sharedExcluded` (spec 14 §6). |
| **APFS clone** | `isClone` / extent overlap | Clones are **not** duplicates (§7 Stage 1); reclaim ≈ unshared extents. | Shared extents excluded; `confidence=estimated` if exact introspection skipped (spec 16 §4.1). |
| **Sparse** | `isSparse` (`alloc<size`) | Report both sizes; large logical ≠ large reclaim. | Allocated blocks only. |
| **Snapshot** | `snapshotRef != nil` | Under a TM snapshot mount → **protected**, never a delete finding (Art. 5); report space informationally. | 0 actionable reclaim. |
| **Dataless** | `isDataless` (iCloud) | Never opened/hashed/deleted (spec 16 §4.4); skip with `SkipReason.dataless`. | 0 reclaim. |
| **Compressed** | `UF_COMPRESSED` | `allocatedSize` already truthful; used as a signal only. | Compressed footprint (already correct). |

These rules **override** any detector's inclination: e.g. duplicate detection must not present two
clones as reclaimable duplicates, and large-file detection must report a sparse VM's *allocated*
size, not its logical size.

## 21. Detector → risk/score summary matrix

| Detector (§) | Default risk | Recoverability | Score drivers | Auto-clean in `--yes`? |
|---|---|---|---|---|
| Real cache (3) | safe | manual | +regenerable, +CACHEDIR.TAG, −userdata | yes |
| Build artifact (4) | safe | manual | +producer present | yes |
| Generated file (5) | safe | manual | +source predecessor | yes |
| Stale cache (6) | safe | manual | +age, +redownloadable | yes |
| Duplicate file (7) | medium | instant | confirmed identical, −shared | no (medium) |
| Duplicate cache (8) | safe/medium | manual | +overlap, +redownloadable | safe: yes |
| Large file (9) | medium/danger | manual/hard | user data likely | no |
| Old file (10) | medium | manual/hard | +age | no |
| Temp download (11) | safe/medium | manual/hard | +whereFroms, +app installed | safe: yes |
| Unused app (12) | dangerous | manual | +idle, −running | no (typed) |
| Orphan package (13) | safe/medium | manual | +manager-confirmed | safe: yes |
| Obsolete SDK (14) | safe/medium | manual | +not-in-keepset, +stale | safe: yes |
| Stale DerivedData (15) | safe | manual | +orphaned/stale | yes |
| Old simulator (16) | safe/medium | manual | +unavailable, +old | safe: yes |
| Old archive (17) | dangerous | hard/none | irreplaceable dSYMs | no (typed) |
| Unnecessary lproj (18) | medium | manual | −signed bundle | no |
| Zombie dir (19) | safe/medium | manual/hard | +empty/dead-agent, orphan-support→medium | safe: yes |

In v0.6 all findings are surfaced together; the default run confirms via the `[Y · s · n]` prompt,
`--yes` cleans everything, and every removal is staged and recoverable via `cleaner undo`. The
classifications above are retained as internal metadata only.

## Open Questions

- **OQ-19.1** Duplicate keeper policy default (oldest `birthtime` vs. path-outside-cache vs.
  most-linked) — which minimizes surprise? *Leaning: keep the copy outside cache dirs, else
  oldest; always user-overridable.*
- **OQ-19.2** How much content may a detector read? `.xcarchive`/DerivedData plists are small &
  necessary; where is the line before it violates "attributes-only" scanning and risks dataless
  faults? *Leaning: allow bounded reads of small, non-dataless metadata files (plist/manifest);
  never read bulk content except for dedup hashing of non-dataless files.*
- **OQ-19.3** xxHash prefilter sample size/positions (head+tail 4 KiB) vs. false-negative risk for
  files that differ only in the middle — do we need a middle sample for certain kinds? *Leaning:
  head+tail+size for prefilter is only a *filter*; Stage 4 SHA-256 is authoritative, so a
  prefilter false-*collision* is harmless (extra work), and a false-*split* can't happen because
  identical files hash identically at every stage.*
- **OQ-19.4** Unused-app removal set composition (which support/prefs/agents to bundle) — one Item
  or per-path findings? *Leaning: one `group` Item (spec 14 ItemKind.group) for the app + its
  satellites, staged together for clean rollback.*
- **OQ-19.5** `.lproj` stripping of signed bundles — exclude entirely in v1 (safe) or offer with a
  loud re-sign/verify warning? *Leaning: exclude signed bundles in v1 (Principle 1).*
- **OQ-19.6** Snapshot/purgeable *reporting* needs `tmutil listlocalsnapshots` (read-only
  shell-out) — acceptable for the report-only path? *Inherits spec 16 OQ-16.2; leaning: read-only
  adapter behind an ADR, never for deletion.*
- **OQ-19.7** Should staleness thresholds be global or per-category defaults with per-category
  config override? *Leaning: per-category defaults (30 d dev cache, 90 d logs, 180 d apps),
  overridable in spec 24.*

## Dependencies

**Consumes:** 00-constitution (Principle 1 safety, Art. 4 risk model, the "combine metadata
signals, not hardcoded paths" mandate, Art. 5 protected paths), 10-tech-stack (CryptoKit SHA-256,
xxHash prefilter, swift-collections `Heap`), 13-plugin-architecture (detection runs in plugins,
propose-only, `ProcessRunning` adapters for brew/simctl), 14-domain-model (`Finding`, `Item`,
`Evidence`, `RiskLevel`/`SafetyScore`/`Recoverability`, `FindingID` DM-7, reclaim §6),
16-filesystem-strategy (Evidence signals: whereFroms/quarantine/lastUsed/finderTags/hardlink
clusters/clone detection/dataless/snapshot; `getattrlistbulk`), 17-scan-engine (driven walk,
streaming, bounded memory), 18-rule-engine (rules refine/override detector output).

**Feeds:** 20-cleanup-engine (findings become actions), 22-safety-model (scorer consumes the same
signals & weights, holds the ceiling), 24-config (staleness/keep-N thresholds), 25-tui (risk icons,
rationale, whereFroms display), and every `specs/plugins/*` detailed detector design.
