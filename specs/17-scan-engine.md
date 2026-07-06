# 17 — Scan Engine Design

> **Phase D · Depends on:** 00-constitution (Art. 4/5, Principles 5/9, CC-3, Art. 7 exit codes),
> 07-nonfunctional-requirements (NFR-001/002/006/010/013/030/031/040/041), 10-tech-stack
> (Swift Concurrency, swift-collections `Heap`/`Deque`), 13-plugin-architecture (`CleanerPlugin`,
> `PluginContext`, four-gate funnel, error isolation §9), 14-domain-model (`Finding`, `Item`,
> `ScanResult`, `SafetyScore`, DM-2/6/7), 15-data-model (§7 incremental cache),
> 16-filesystem-strategy (`FilesystemService`, `BulkEnumerator`, `VolumeInfo`, TOCTOU) ·
> **Depended on by:** 18 (rule gate), 19 (detection), 20 (cleanup consumes `ScanResult`),
> 22 (safety scorer ceiling), 25 (TUI progress), 30/31 (bench/test).

## 1. Purpose & scope

The **Scan Engine** is the orchestrator that turns *N* plugins' read-only `scan(context)`
streams into a single, deterministic, memory-bounded `ScanResult` (spec 14 §4.12). It owns:

- root resolution and intersection with allow-space − deny-list (Art. 5), per plugin;
- de-duplication of overlapping roots across plugins so a subtree is walked **once**;
- the streaming pipeline: `AsyncStream<Finding>` fan-out over a `TaskGroup`, back-pressured,
  with a per-volume concurrency limiter (spec 16 §7);
- the four-gate safety funnel (spec 13 §10) applied to every emitted `Finding`;
- progress reporting to the TUI (bytes scanned, files visited, ETA) at ≥ 2 Hz without blocking
  scan work (NFR-023);
- cancellation at directory boundaries < 200 ms (NFR-040) and resume from checkpoint (NFR-041);
- incremental scan against the spec 15 §7 cache keyed on `path+inode+mtime+size(+alloc,mode,uid)`;
- streaming aggregation via an `actor` — **no whole tree in RAM** (NFR-002, < 300 MB RSS);
- per-plugin deadlines/timeouts and error isolation (a bad plugin degrades to a skip, spec 13 §9).

The engine is **not** where detection heuristics live (that is spec 19, inside plugins) nor where
allocated-size measurement is implemented (spec 16). It *coordinates* those and enforces the
invariants the plugins are not trusted to enforce (DM-2/6/7).

Non-goals: mutation (read-only pass, Art. 3 "Scan"), UI rendering (spec 25 consumes the progress
stream), config parsing (spec 24).

## 2. Where the engine sits

```
 CLI (scan/analyze/clean) ─▶ ScanEngine.run(request) ─▶ ScanResult
                                     │
        ┌────────────────────────────┼─────────────────────────────┐
        ▼                            ▼                              ▼
 RootResolver              PluginContext factory            ScanAccumulator (actor)
 (Art.5 intersect,         (injects FilesystemService,      folds Findings, subtotals,
  dedup overlaps)           MetadataReading, clock, token)   skipped, per-plugin stats
        │                            │                              ▲
        ▼                            ▼                              │
 [WalkUnit]               plugin.scan(ctx) ─▶ AsyncThrowingStream<Finding>
 (volume-partitioned)             │                                 │
        │                         ▼                                 │
   ConcurrencyLimiter ─▶ TaskGroup fan-out ─▶ SafetyFunnel (4 gates) ┘
   (per-volume caps)                          ①score ②rules ③guard ④normalize
```

The engine consumes plugins through the exact contract in spec 13 §3: it calls
`plugin.scan(context)`, consumes an `AsyncThrowingStream<Finding>`, and **re-scores and
re-guards every Finding** (spec 13 §10). Plugins are advisory; the engine is authoritative.

## 3. Root resolution, allow/deny intersection & dedup

### 3.1 Resolution pipeline

Each plugin declares `[RootSpec]` (symbolic anchor + glob, spec 13 §4). The engine resolves
these into concrete, guarded `ResolvedRoot`s before any plugin code runs:

```swift
struct ResolvedRoot: Sendable, Hashable {
    let owner: PluginID
    let canonical: FilePath        // spec 16 §9 canonicalized, symlink-resolved
    let volume: VolumeID           // DiskArbitration (spec 16 §7)
    let globSuffix: String?        // residual pattern under the anchor, matched during walk
    let medium: VolumeMedium       // drives concurrency (spec 16 §7)
}

enum RootResolutionError: CleanerError { case outsideAllowSpace, protectedRoot, unresolved }
```

Algorithm `resolve(plugins) -> [ResolvedRoot]` (Art. 5 enforcement, DM-4 upstream):

1. Expand each `RootSpec.base` anchor against the real user (`~` → `$HOME`, `.libraryCaches`
   → `~/Library/Caches`, `.developer` → `~/Library/Developer`, …).
2. `canonicalize` (spec 16 §9): NFC-normalize, resolve `.`/`..` and symlink components.
3. Compute `allowed = (⋃ declaredRoots ∩ allowSpace) − denyList`. A root that lands wholly in
   the deny-list (e.g. `~/Documents`) is **rejected at resolution** → the plugin is skipped for
   that root, an `RunEvent.rootRejected` is logged, and the scan continues (this mirrors the
   validation-time rejection in spec 13 §4 but re-checks because config can add protected paths).
4. Attach `VolumeID`/`medium` via DiskArbitration; a root on a `isSystemVolume || isReadOnly`
   volume is scan-allowed (read is safe) but marked so no disposition can later target it.

### 3.2 Overlap de-duplication (walk once, attribute many)

Two plugins can declare overlapping roots (OQ-13.3: DevCache and Xcode both under
`~/Library/Caches`). We **must not** walk `~/Library/Caches` twice.

The engine builds a **prefix forest** of resolved roots and coalesces:

```
   roots: A=~/Library/Caches/**        (DevCache)
          B=~/Library/Caches/com.apple.dt.Xcode/**  (Xcode)
   ──▶ B ⊂ A  ⇒  single WalkUnit rooted at ~/Library/Caches,
                 tagged with interested plugins {DevCache, Xcode},
                 each plugin's globSuffix decides which nodes it sees.
```

```swift
struct WalkUnit: Sendable {
    let root: FilePath                 // the coalesced walk root (shortest common prefix)
    let volume: VolumeID
    let medium: VolumeMedium
    let interested: [InterestedPlugin] // plugins whose globs intersect this subtree
}
struct InterestedPlugin: Sendable { let id: PluginID; let globSuffix: String? }
```

Coalescing rule: if root *B* is a descendant of root *A*, drop *B* as a WalkUnit and add its
plugin to *A*'s `interested` list with *B*'s residual glob. A single `BulkEnumerator` (spec 16
§2) walks each WalkUnit; each yielded `FSNode` is offered only to the plugins whose `globSuffix`
matches (glob match is a cheap `fnmatch`-style test on the relative path). This satisfies
NFR-007 (≤ 1 alloc/file) by not re-enumerating and OQ-13.3 (dedup by canonical path).

**Finding-level dedup.** If, after all that, two plugins still emit a `Finding` for the same
canonical `primaryPath`, the accumulator (§6) keeps **first-Finding-wins with merged Evidence**
(spec 13 OQ-13.3): the surviving Finding's `producedBy` is the first plugin; the loser's
`Evidence` fields are merged in where the winner's are `nil`, and a `RunEvent.findingMerged` is
recorded for audit.

## 4. The streaming pipeline

### 4.1 Pipeline diagram

```
 WalkUnit ──BulkEnumerator (spec16 §2, fd-relative, O_NOFOLLOW)──▶ AsyncThrowingStream<FSNode>
    │                                                                     │ back-pressured
    │  per-node: offer to interested plugins (glob match)                 ▼
    │                                                            ┌──────────────────┐
    │  plugins run INSIDE the walk via a shared node feed:       │ node → plugin(s)  │
    │  the engine drives enumeration; plugins receive FSNodes    │ scan callback     │
    │  through PluginContext.fs (they do not re-open the tree).  └────────┬─────────┘
    │                                                                     │ Finding
    ▼                                                                     ▼
 ConcurrencyLimiter.acquire(volume) ─▶ TaskGroup child per WalkUnit ─▶ Channel<Finding>
    │  (bounded; SSD=cores×2, HDD=1..2, net=1)                              │ bounded buffer
    │                                                                       ▼
    └────────────────────────────────────────────────▶ SafetyFunnel.process(finding)
                                                          ① SafetyScorer (spec22) clamp ceiling
                                                          ② RuleEngine (spec18) whitelist/target
                                                          ③ ProtectedPathGuard (spec16 §9)
                                                          ④ normalize (DM-1/3/6 split volumes)
                                                                       │ accepted Finding
                                                                       ▼
                                                          ScanAccumulator (actor) fold
                                                                       │ every ~250ms / N nodes
                                                                       ▼
                                                          ProgressReporter ─▶ AsyncStream<ScanProgress> ─▶ TUI
```

### 4.2 Two consumption models (why plugins ride the shared walk)

A naïve design lets each plugin open its own enumeration; that re-walks shared subtrees and
blows NFR-001/007. Instead, the engine offers two modes, negotiated by
`CapabilitySet.incremental`/plugin style:

- **Driven mode (default, preferred).** The engine drives the `BulkEnumerator` for a WalkUnit
  and pushes each `FSNode` into `PluginContext.fs.enumerate(root:)` as a *replayed* stream that
  the plugin consumes. The plugin never issues its own `getattrlistbulk`; it filters by glob and
  emits Findings. Shared subtrees are walked once. This is how first-party plugins are written
  (spec 13 examples already call `ctx.fs.enumerate`).
- **Autonomous mode.** A plugin that must enumerate its own way (e.g. it reads a manifest file
  and probes specific paths, like a Docker or npm plugin) calls `ctx.fs` directly for point
  lookups. These do not participate in WalkUnit coalescing but are cheap (few paths).

The `FileSystemReading.enumerate` the plugin sees is backed, in driven mode, by an in-memory
**bounded replay buffer** (a `Deque` window, not the whole tree) fed by the engine's single
enumerator — preserving the "walk once, stream, bounded memory" guarantee.

### 4.3 Back-pressure

Every hop is bounded so a fast producer cannot outrun a slow consumer and balloon memory
(NFR-002):

- The `BulkEnumerator` yields into an `AsyncThrowingStream` with a **bounded buffering policy**
  (`.bufferingNewest(k)` is wrong — we cannot drop findings; we use a custom bounded channel that
  *suspends the producer* when full).
- Between the funnel and the accumulator sits a `BoundedChannel<Finding>` (capacity ~1–4 K).
  When full, the enumerating task suspends at the next node boundary. Because suspension happens
  at directory boundaries, it composes with cancellation (§8).

```swift
/// Bounded async channel: send suspends when full, receive suspends when empty. Sendable.
actor BoundedChannel<Element: Sendable> {
    init(capacity: Int)
    func send(_ e: Element) async            // suspends producer if full (back-pressure)
    func finish()
    func makeStream() -> AsyncStream<Element> // single consumer
}
```

## 5. Concurrency: TaskGroup fan-out + per-volume limiter

### 5.1 Fan-out

One `withThrowingTaskGroup` spawns a child task **per WalkUnit**, but admission is gated by a
per-volume limiter so we never oversubscribe a spindle or a network mount (NFR-006/012):

```swift
func run(_ req: ScanRequest) async throws -> ScanResult {
    let units = plan(req)                              // §3 resolve + coalesce
    let acc = ScanAccumulator(clock: req.clock)
    let limiter = ConcurrencyLimiter(volumes: req.volumeInfos)   // §5.2
    try await withThrowingTaskGroup(of: Void.self) { group in
        for unit in units {
            group.addTask { [acc] in
                await limiter.withPermit(volume: unit.volume, medium: unit.medium) {
                    try await self.scanUnit(unit, into: acc, deadline: req.deadline(for: unit))
                }
            }
        }
        try await group.waitForAll()                   // structured; cancellation propagates
    }
    return await acc.finalize()                        // deterministic sort (§9)
}
```

### 5.2 Per-volume concurrency limiter

A counting-semaphore actor keyed by `VolumeID`, with the **cap derived from volume medium**
(spec 16 §7) so SSDs get parallelism and HDDs/network stay serial (NFR-006/012):

```swift
actor ConcurrencyLimiter {
    // caps: ssd = min(cores*2, ioCap); external = cores; hdd = 2; network = 1; unknown = 2
    private var permitsFree: [VolumeID: Int]
    private var waiters: [VolumeID: Deque<CheckedContinuation<Void, Never>>]

    func withPermit<R>(volume: VolumeID, medium: VolumeMedium,
                       _ body: () async throws -> R) async rethrows -> R {
        await acquire(volume, medium); defer { release(volume) }   // conceptual; real defer async
        return try await body()
    }
}
```

Rationale (spec 16 §7): HDD seeks dominate so parallel walks *thrash*; SSDs are seek-free so
parallel walks fill the IO queue; network volumes need low concurrency + long timeouts. The cap
is `min(medium-cap, cores)` and never spins idle cores on an SSD (NFR-006). Within a WalkUnit,
sub-directory descent is *serial per walker* (the `Deque` work-queue of spec 16 §2) — parallelism
is *across* WalkUnits/volumes, which keeps per-directory ordering stable for determinism (§9).

## 6. Streaming aggregation — `ScanAccumulator` actor

All shared mutable scan state lives in **one actor** (CC-3), fed immutable `Sendable` values, so
there is zero whole-tree materialization (NFR-002) and no data race (NFR-033):

```swift
actor ScanAccumulator {
    private var findingsByID: OrderedDictionary<FindingID, Finding>   // dedup + insertion order
    private var byCategory: [CategoryID: [FindingID]]
    private var dirSubtotals: [DirKey: SizePair]     // folded upward as walk drains (spec16 §3)
    private var skipped: [SkippedPath]
    private var pluginStats: [PluginID: PluginRunAccum]
    private var visitedFiles: Int64 = 0
    private var bytesScanned: Int64 = 0              // sum of node.sizeOnDisk seen
    private var cacheHits = 0, cacheMisses = 0

    func absorb(_ f: Finding) { /* first-wins + Evidence merge (§3.2); index; add reclaim */ }
    func note(visited node: FSNode) { visitedFiles += 1; bytesScanned += node.sizeOnDisk }
    func skip(_ p: FilePath, _ r: SkipReason) { skipped.append(.init(path: p, reason: r)) }
    func pluginFailed(_ id: PluginID, _ err: Error) { /* mark partial → exit 7 (spec13 §9) */ }

    func finalize() -> ScanResult { /* deterministic sort (§9), compute ScanTotals */ }
    func snapshotProgress() -> ScanProgress { /* cheap read for the reporter */ }
}
```

Memory bound: the accumulator holds *Findings* (junk is a small fraction of files) plus
`dirSubtotals` keyed by **open** directories only (folded and evicted as each directory
completes), so working set is `O(#findings + open-dir-depth × batch buffer)`, not `O(#files)` —
this is what meets NFR-002 (< 300 MB on 5 M files). `visitedFiles`/`bytesScanned` are scalar
counters, not lists.

The engine also enforces DM-2 here: after the `SafetyScorer` recomputes the score, the
accumulator asserts the plugin did not *raise* it above the ceiling (clamped in the funnel, but
double-checked) and DM-6 (an `Item` whose `paths` span volumes is split into per-volume Items
before absorption).

## 7. Progress reporting & ETA

The TUI must show live bytes scanned, files visited, current path, and an ETA, updated ≥ 2 Hz,
**without** the reporter contending on the hot path (NFR-020/022/023):

```swift
struct ScanProgress: Sendable {
    let filesVisited: Int64
    let bytesScanned: Int64            // on-disk sum of nodes seen
    let findingsSoFar: Int
    let reclaimableSoFar: Int64        // running ReclaimEstimate.onDiskBytes
    let currentRoots: [FilePath]       // one per active WalkUnit (for the tree view)
    let activeVolumes: Int
    let cacheHitRate: Double?          // incremental scans
    let eta: Duration?                 // §7.2
    let phase: ScanPhase               // .enumerating | .funnel | .finalizing
}
enum ScanPhase: Sendable { case enumerating, finalizing }
```

### 7.1 Decoupled sampling

The reporter is a separate task that *polls* `accumulator.snapshotProgress()` on a timer
(default 250 ms) and pushes onto an `AsyncStream<ScanProgress>` the TUI consumes. Polling (not
per-node pushing) means the hot enumeration loop never awaits the UI — it just bumps counters in
the actor. If the TUI consumer is slow, the stream uses `.bufferingNewest(1)` (progress *may* be
dropped; unlike Findings, a stale progress frame is harmless — Principle 3 is about the final
report, not intermediate frames).

### 7.2 ETA estimation

ETA needs a denominator we do not have up front (we stream, we don't pre-count). Two estimators,
picked by availability:

1. **Cache-primed (warm scan).** If the incremental cache (§10) has a prior generation, the
   header records the last scan's total `filesVisited` per volume. ETA = `remaining_est /
   current_rate`, where `remaining_est = last_total − filesVisited` (clamped ≥ 0). This gives an
   accurate bar on warm scans (NFR-003 warm < 5 s).
2. **Cold scan (no prior).** No total is known, so we show an **indeterminate** rate-based
   estimate: a smoothed files/min and bytes/min (EWMA over the last few samples) and *no* percent
   bar — the TUI shows a spinner + throughput, never a fake percentage (Principle 3, truth in
   reporting). Optionally, once directory breadth is known, a coarse "N of ~M dirs" from the
   top-level fan-out is shown as *approximate*.

Rate smoothing: `rate ← α·instant + (1−α)·rate`, `α = 0.3`. Never let ETA jump backward more than
one sample (monotone display smoothing) to avoid a jittery bar.

## 8. Cancellation at directory boundaries

Cancellation must take effect < 200 ms and leave the FS consistent (trivially — scan is
read-only) (NFR-040/043):

```
 Ctrl-C / q ─▶ CancellationToken.cancel() ─▶ Task tree cancelled (structured)
                         │
   each walker checks Task.checkCancellation() at EVERY directory boundary
   (before descending into the next child dir) and after each getattrlistbulk batch
                         │
   in-flight batch finishes decoding (bounded ≤ batchSizeHint entries) ─▶ walker returns
                         │
   TaskGroup unwinds ─▶ accumulator.finalize(wasCancelled: true) ─▶ ScanResult(wasCancelled: true)
                         │
   terminal restored to cooked mode (NFR-043) ─▶ exit 5 (cancelled)
```

- Checks happen at **directory boundaries** (spec 16 §2 work-queue) and after each bulk batch, so
  worst-case latency is one batch decode (~100 entries) — well under 200 ms.
- Because enumeration is fd-relative and allocates no long-lived resources per node, unwinding
  closes directory FDs deterministically (`defer close(fd)`), satisfying NFR-043 (no orphaned
  FDs).
- A cancelled scan still returns a **valid partial** `ScanResult` (findings gathered so far,
  `wasCancelled = true`, `skipped` includes `SkipReason.cancelled` for un-visited roots) so the
  user can act on partial results or resume.

## 9. Checkpointing & resume

Resume (NFR-041, FR-092) re-scans < 10 % of already-covered subtrees after an interruption.

### 9.1 Checkpoint content

A checkpoint is a small journal written periodically (every M directories or T seconds) to
`~/.cleaner/cache/scan-checkpoint-<session>.ndjson`:

```jsonc
{ "schemaVersion": 1, "sessionID": "…", "generation": 38,
  "completedRoots": ["/Users/h/Library/Caches/com.foo"],   // fully drained WalkUnits
  "frontier": [ { "walkUnit": "…", "completedChildPrefix": "com.g" } ], // partial: last dir done
  "findingsCount": 812, "at": "2026-07-06T14:01:00Z" }
```

The **frontier** records, per in-progress WalkUnit, the lexicographically-last *immediate child*
directory fully completed. Because within a WalkUnit descent is deterministic (sorted child
order, §9.2), resume skips completed children and restarts at the frontier directory. Findings
already emitted are *not* persisted in the checkpoint (they are re-derivable and cheap for the
re-scanned < 10 %); the checkpoint is a **position**, not a result cache. (The result cache is
the incremental cache, §10, which does the heavy lifting.)

### 9.2 Determinism prerequisite

Resume and idempotence (NFR-030/031) both require a **stable enumeration order**. Filesystem
enumeration order is undefined, so the engine sorts each directory's children by a stable key
(`name` NFC byte order) before descending and before emitting. This makes: (a) checkpoints
meaningful (frontier is a real cut), (b) two scans of an unchanged FS byte-identical, (c) the
final `ScanResult.findings` deterministically ordered (sorted by `(category, risk descending,
onDiskBytes descending, FindingID)` in `finalize()`), independent of TaskGroup completion order.

### 9.3 Resume algorithm

```
 resume(session):
   load checkpoint; verify generation matches current cache generation
   for each WalkUnit:
     if unit ∈ completedRoots → skip entirely (trust incremental cache §10 for its findings)
     else if unit ∈ frontier  → enumerate children, skip those ≤ completedChildPrefix, resume rest
     else                     → full walk
   merge re-derived findings with cache-supplied findings for completed units
```

If the checkpoint is missing/corrupt, resume degrades to a full scan (the checkpoint, like the
cache, is a hint — never a correctness dependency).

## 10. Incremental scan via the cache (spec 15 §7)

Only plugins advertising `CapabilitySet.incremental` participate; others always full-scan
(correctness over speed, spec 13 §7).

### 10.1 Change key & skip decision

For each `FSNode` the engine consults the cache (spec 15 §7.1):

```
stamp(node) = (volumeUUID, inode, mtime_ns, size, allocatedSize, mode, ownerUID [, st_gen])
hit  ⇔ cache[canonicalPath].stamp == stamp(node)   AND, for directories,
       cache[path].childrenDigest == digest(immediate children (name,inode,mtime_ns,size))
```

- **File hit:** the node is unchanged since last scan; the engine **reuses the cached
  `producedFindingID` + cached `sizeOnDiskCorrected`** and does *not* offer the node to plugins
  (skip the heuristic work) — but it still counts it toward `filesVisited`/reclaim so totals are
  truthful. `cacheHits++`.
- **Directory hit:** the whole subtree is provably unchanged (stamp + `childrenDigest` match) ⇒
  **prune the descent** and fold in the cached subtree subtotal + cached findings. This is the
  big win: warm re-scans skip untouched subtrees wholesale (NFR-003 warm < 5 s).
- **Miss / doubt:** any field differs, digest differs, volume UUID changed, `st_gen` mismatch, or
  the entry is unmigratable ⇒ **full re-examination** of that node/subtree; the new stamp is
  appended to the journal. A miss never silently trusts stale data (spec 15 §7.4, Principle 1).

### 10.2 Safety rule (critical)

The cache is a **performance hint only** (spec 15 §7). It may make a scan *faster* but must never
cause the tool to *act* on stale data. Therefore:

- The cache feeds the **scan** phase (what to re-examine) and pre-populates *estimates*.
- It **never** feeds the **clean** phase: spec 20 re-stats every item at disposal time (TOCTOU,
  spec 16 §9) regardless of cache state. A cached finding whose path changed between scan and
  clean is caught by the cleanup engine's re-validation and skipped.

### 10.3 Cache write & compaction

New/updated stamps are appended to `cache/scan-index.ndjson` during the scan (append-only, no
fsync per-write — it's rebuildable, spec 15 §12). The generation counter bumps per full scan;
entries carry the generation for GC. Compaction (spec 15 §11) dedupes to the latest stamp per
path and drops vanished paths; it takes the `scan-index.ndjson.lock`.

## 11. Deadlines, timeouts & error isolation

### 11.1 Per-plugin / per-unit deadline

Each WalkUnit (and thus each interested plugin's work on it) runs under a deadline derived from
the volume medium (network gets longer) and a global scan-deadline budget:

```swift
func scanUnit(_ u: WalkUnit, into acc: ScanAccumulator, deadline: Duration) async throws {
    try await withDeadline(deadline) {          // races body against a timeout task
        for try await node in bulkEnumerate(u) { … }
    } onTimeout: {
        await acc.pluginFailed(/* stalled plugins on u */, TimeoutError())   // → exit 7, spec13 §9
    }
}
```

A plugin/walk that blows its deadline is treated as `pluginFailed`: its *partial* Findings for
that unit are **dropped** (we do not trust a half-finished, possibly inconsistent plugin pass —
spec 13 §9), a `RunEvent.pluginFailed`/`RunEvent.deadlineExceeded` is recorded, and other
WalkUnits continue. Terminal exit becomes 7 if any plugin failed at scan level (Art. 7).

### 11.2 Error isolation matrix (mirrors spec 13 §9, engine side)

| Failure | Engine reaction | Result field | Exit |
|---|---|---|---|
| Plugin `scan` stream throws mid-way | keep Findings emitted so far for *completed* dirs, mark plugin partial | `PluginRunSummary.error` | 7 |
| Plugin hangs past deadline | cancel unit, drop that unit's partial findings | `pluginFailed` | 7 |
| Enumeration `EACCES`/permission on a subtree | `skip(path, .permissionDenied)`, continue siblings | `skipped[]` | 3 (or 4 if root-level FDA) |
| I/O error on a node | `skip(path, .ioError)`, continue | `skipped[]` | 3 |
| Cycle / too-deep | `skip(path, .cycle/.tooDeep)`, continue | `skipped[]` | 3 |
| Dataless file (spec 16 §4.4) | `skip(path, .dataless)`, never open | `skipped[]` | 0/3 |
| Protected/symlink-escape path from plugin | funnel gate ③ drops it (display-only `isProtected`) | not a finding | 0 |
| Plugin proposes acting outside roots | (scan can't act; deferred to clean) guard flags it | — | — |

Isolation guarantee: **no single plugin or subtree failure aborts the whole scan** (NFR-035). A
completely clean run is exit 0; any skip → 3; any plugin-level failure → 7; a safety-invariant
breach at clean time → 8 (that path is spec 20, not scan).

## 12. `ScanEngine` / `ScanContext` API sketch

```swift
public struct ScanRequest: Sendable {
    let sessionID: SessionID
    let plugins: [any CleanerPlugin]     // already validated/registered (spec 13 §5)
    let profile: Profile?                // enabled plugins, includeRisk, options (spec 14 §4.16)
    let ruleSet: RuleSet                 // user whitelist/target rules (spec 18)
    let incremental: Bool                // use the cache (spec 15 §7)
    let resumeFrom: CheckpointRef?        // resume a prior session (§9)
    let clock: any ClockReading          // injected for determinism (Principle 5)
    let volumeInfos: [VolumeID: VolumeInfo]
    let globalDeadline: Duration?
    let progressInterval: Duration        // default .milliseconds(250)
}

public protocol ScanEngine: Sendable {
    /// Full scan → ScanResult (spec 14 §4.12). Deterministic, cancellable, resumable.
    func run(_ request: ScanRequest) async throws -> ScanResult
    /// Live progress for the TUI; independent of the result await (spec 25).
    var progress: AsyncStream<ScanProgress> { get }
}

/// What the engine hands each plugin (adapts to spec 13's PluginContext; the engine owns the
/// concrete providers; the plugin sees only the read-only protocol surface).
struct ScanContextFactory {
    func makeContext(for plugin: PluginID,
                     roots: [ResolvedRoot],
                     feed: NodeFeed,             // driven-mode replay buffer (§4.2)
                     token: CancellationToken,
                     clock: any ClockReading) -> PluginContext
}

/// Engine-internal events (feed audit + RunSummary; not user-facing directly).
enum RunEvent: Sendable {
    case rootRejected(PluginID, FilePath, RootResolutionError)
    case findingMerged(kept: FindingID, dropped: FindingID)
    case pluginFailed(PluginID, reason: String)
    case deadlineExceeded(PluginID, WalkUnitID)
    case checkpointed(dirs: Int)
    case cacheHit(FilePath), cacheMiss(FilePath)
}
```

The four-gate `SafetyFunnel` (spec 13 §10) is an engine component invoked per Finding *before*
`accumulator.absorb`:

```swift
struct SafetyFunnel {
    let scorer: SafetyScorer           // spec 22 — recompute + clamp ceiling (DM-2)
    let rules: RuleEvaluator           // spec 18 — whitelist/target/ignore
    let guard: ProtectedPathGuard      // spec 16 §9 — allow ∩ roots − deny, symlink escape
    func process(_ raw: Finding) -> FunnelOutcome  // .accept(Finding) | .drop(reason) | .protect(Finding)
}
```

## 13. Performance targets (tie to spec 07)

| Target | NFR | How this design meets it |
|---|---|---|
| ≥ 250 K files/min (RM, W-large) | NFR-001 | `getattrlistbulk` (spec 16 §2) + walk-once dedup (§3.2) + per-SSD parallelism (§5). |
| RSS < 300 MB on 5 M files | NFR-002 | Streaming accumulator (§6), no whole-tree; bounded channels (§4.3); dir subtotals evicted on completion. |
| Scale to 4 TB / ≥ 10 M files | NFR-010/011 | Iterative fd-relative descent (spec 16 §2), `Deque` work-queue — no recursion, no OOM. |
| CPU scales across cores, no idle spin | NFR-006/012 | Per-volume limiter (§5.2), cap = min(medium-cap, cores). |
| Warm `analyze` < 5 s (W-small) | NFR-003 | Incremental cache subtree pruning (§10) skips untouched trees. |
| ≥ 1 M findings streamed, not materialized | NFR-013 | `AsyncStream<Finding>` + paged accumulator; TUI consumes progressively. |
| Idempotent, deterministic | NFR-030/031 | Stable child sort (§9.2), deterministic finalize sort, injected clock. |
| Cancel < 200 ms | NFR-040 | Checks at every dir boundary + per-batch (§8). |
| Resume re-scans < 10 % | NFR-041 | Frontier checkpoint (§9) + cache pruning (§10). |
| ≤ 1 alloc/file hot loop | NFR-007 | Reused bulk buffers (spec 16), `System.FilePath`, no per-node URL in driven mode. |

Benchmarks `scan-throughput`, `mem-rss`, `cpu-scaling`, `analyze-latency`, `scale-4tb`,
`cancel-latency`, `resume` (spec 30) verify each row.

## Open Questions

- **OQ-17.1** Driven vs autonomous mode boundary: should the engine *require* driven mode for any
  plugin whose roots overlap another's (to force walk-once), or allow autonomous with a
  performance warning? *Leaning: require driven when overlap is detected; autonomous only for
  disjoint, point-probe plugins (Docker/npm).*
- **OQ-17.2** Frontier checkpoint granularity — immediate-child directory is coarse for a WalkUnit
  with one giant child dir (≥ 1 M entries, NFR-011). Do we need intra-directory offset
  checkpoints? *Leaning: add a batch-offset within the frontier dir for pathological cases.*
- **OQ-17.3** ETA on cold scans: is a coarse top-level-breadth percent acceptable (approximate,
  labeled), or does Principle 3 forbid any percent without a real denominator? *Leaning: spinner +
  throughput only on cold; percent only when cache-primed. Confirm with spec 25.*
- **OQ-17.4** Should Finding-level dedup (§3.2) be first-wins or a plugin-priority order (e.g.
  specialized Xcode beats generic DevCache)? *Leaning: priority order by manifest specificity;
  needs a tie-break rule — coordinate with spec 13 OQ-13.3.*
- **OQ-17.5** `childrenDigest` cost on directories with ≥ 1 M children (NFR-011): computing it
  each scan may dominate. Do we cap digest to a sampled subset + count, accepting rare missed
  invalidations? *Leaning: full digest but incrementally maintained; investigate in spec 37.*
- **OQ-17.6** Do incremental-cache hits still run the `SafetyScorer`/`RuleEngine` (config may have
  changed a whitelist since last scan) or trust the cached finding? *Leaning: always re-run gates
  ②③ on cache hits (cheap, in-memory) even when skipping enumeration — config drift must not be
  cached. Reflect in §10.1.*

## Dependencies

**Consumes:** 00-constitution (Art. 4.4 invariants, Art. 5 protected paths, Art. 7 exit codes,
Principles 5/9, CC-3), 07-nfr (NFR-001/002/006/010/011/012/013/030/031/040/041/043 targets),
10-tech-stack (Swift Concurrency, `TaskGroup`, swift-collections `Heap`/`Deque`/`OrderedDictionary`),
13-plugin-architecture (`CleanerPlugin.scan`, `PluginContext`, `CapabilitySet.incremental`,
four-gate funnel §10, error isolation §9), 14-domain-model (`Finding`, `Item`, `ScanResult`,
`ScanTotals`, `SkippedPath`, `PluginRunSummary`, DM-2/6/7), 15-data-model (§7 incremental cache
schema, §12 locking), 16-filesystem-strategy (`FilesystemService`/`BulkEnumerator`, `VolumeInfo`,
concurrency tuning §7, canonicalization/TOCTOU §9), 22-safety-model (SafetyScorer ceiling).

**Feeds:** 18-rule-engine (funnel gate ②), 19-detection-algorithms (plugins run inside the driven
walk; `FindingID` determinism DM-7), 20-cleanup-engine (consumes `ScanResult`; re-validates,
never trusts cache), 22-safety-model (invokes scorer per Finding), 25-tui (`ScanProgress` stream,
ETA), 30-benchmark-plan (scan benches), 31-testing-strategy (determinism/cancel/resume tests),
37-performance-optimization (limiter tuning, childrenDigest cost).
