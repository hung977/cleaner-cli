# 20 — Cleanup Engine

> **Phase D · Depends on:** 00-constitution (Principles 1/2/3/5, Art. 4.4 hard invariants, Art. 5
> protected paths, Art. 7 exit codes, CC-7 stage-then-purge, CC-10 reclaim), 07-nfr
> (NFR-005/030/032/035/040/042), 13-plugin-architecture (§10 propose→dispose split, `CleanDirective`,
> error isolation §9), 14-domain-model (`CleanPlan`, `PlannedAction`, `Disposition`, `CleanReport`,
> `ActionOutcome`, `ReclaimActual`, DM-5/8/9), 15-data-model (§5 staging manifest, §6 audit),
> 16-filesystem-strategy (§9 TOCTOU, §11 disposition mechanics, §7 volume), 17-scan (`ScanResult`),
> 18-rule-engine (gated dispositions), 21-rollback (staging structure it writes) ·
> **Depended on by:** 21 (rollback restores what this stages), 22 (safety re-validation),
> 28 (audit), 30/31 (bench/test).

## 1. Purpose & scope

The **Cleanup Engine** executes a confirmed `CleanPlan` (spec 14 §4.13) **safely**. It is the only
component that mutates the filesystem, and it does so behind the four-gate funnel re-applied at
*disposal time* (spec 13 §10), not just scan time. It owns:

- the **propose→dispose split**: plugins produce `CleanDirective`s (spec 13 §3); the engine
  *disposes* (Art. 4.4 — plugins never delete);
- **pre-flight safety re-validation**: re-check protected paths, re-stat for TOCTOU (spec 16 §9),
  verify the item is unchanged since scan (checksum/mtime/inode) before touching it;
- **disposition execution**: `stage` (default) / `trash` / `purge` / `skip` via spec 16 §11
  mechanics;
- **staging move**: atomic `rename` within a volume; copy+verify+delete across volumes; capturing
  restore metadata *before* the move (spec 15 §5, spec 21);
- **transactional grouping & partial-failure handling**: per-item success/skip/fail → exit code 3;
- **progress + live reclaim tally**; **dry-run** (compute everything, mutate nothing, *identical*
  numbers — Principle 3, DM-9);
- **concurrency & ordering**: delete children before parents, respect volume, bounded parallelism;
- **idempotence** (re-running finds nothing new, NFR-030); **post-clean verification** and the
  `CleanReport` (spec 14 §4.14) with *measured* reclaim (CC-10).

Non-goals: deciding *what* to clean (specs 18/19), restoring (spec 21), computing base scores
(spec 22). The engine **distrusts** plugin output and re-guards everything (spec 13 §10).

## 2. Propose → dispose split

```
 CleanPlan (confirmed) ──▶ CleanupEngine.execute(plan)
      │  actions[] reference Findings (by FindingID) + Disposition + ConfirmationState
      ▼
 for each plugin group:  plugin.clean(items, ctx) ──▶ [CleanDirective]   (PROPOSAL only)
      │                     proposedDisposition (usually .stage; .trash for TrashPlugin)
      ▼
 CleanupEngine DISPOSES — the plugin's directive is ADVICE; the engine:
   ① re-runs ProtectedPathGuard (roots ∩ allow − deny, symlink escape)   → reject → exit 8
   ② overrides disposition per policy (default .stage; .purge impossible from plugin; .trash
      only for Trash category)                                           (spec 13 §10 gate ④)
   ③ re-validates identity (TOCTOU, checksum/mtime/inode)                → drift → skip
   ④ executes the mutation via FilesystemService.dispose (spec 16 §11)
   ⑤ records audit + manifest + measured reclaim
```

The engine calls `plugin.clean` only to obtain the *proposal* (and any `RollbackHint`); it never
lets the proposal decide the actual disposition or path. A malicious/buggy plugin that proposes
purging `/System` is rejected at gate ① with exit 8 (spec 13 §9). This is the load-bearing safety
property (Art. 4.4).

## 3. Per-item state machine

Every planned item advances through this machine; the terminal state maps to an `ActionResult`
(spec 14 §4.14). This is the spine of transactional correctness and crash recovery.

```
                     ┌─────────────┐
                     │  proposed   │  (from CleanPlan; disposition + confirmation)
                     └──────┬──────┘
        re-guard fails →    │ pre-flight safety re-validation (§4)
        exit 8 (blocked)◄───┤   protected? symlink escape? mount root?
                            │ ok
                     ┌──────▼──────┐   identity drift / locked / vanished
                     │  validated  ├──────────────────────────────► skipped
                     └──────┬──────┘        (report reason; not a failure of intent)
                            │ execute disposition
             ┌──────────────┼───────────────┬───────────────┐
             │ stage        │ trash          │ purge         │ skip
        ┌────▼────┐   ┌─────▼────┐     ┌─────▼────┐    ┌─────▼────┐
        │ staging │   │ trashing │     │ purging  │    │ (noop)   │
        └────┬────┘   └─────┬────┘     └─────┬────┘    └────┬─────┘
   verify OK │ fail    OK   │ fail      OK   │ fail        │
        ┌────▼────┐    ┌────▼───┐      ┌─────▼───┐    ┌─────▼────┐
        │ staged  │    │trashed │      │ purged  │    │ skipped  │
        └────┬────┘    └────────┘      └─────────┘    └──────────┘
             │ (staged is NOT terminal for the session's rollback window — spec 21)
             ▼
        post-verify → ActionOutcome(result: staged, reclaimed, stagedAs)

  any mutation throw → failed  (partial run → exit 3; already-staged items STAY staged)
  invariant breach   → blockedBySafety → exit 8 (fatal; run aborts)
```

State transitions are **journaled** (write-intent to audit before, confirm after — spec 15 §6/12)
so a `SIGKILL` mid-transition is recoverable to a definite state (NFR-032): an item is either fully
`proposed` (untouched) or fully `staged` — never half-moved, because the move itself is an atomic
`rename` (§6) or a temp-then-rename copy (§6.2).

```swift
enum ItemState: Sendable { case proposed, validated, staging, trashing, purging,
                                staged, trashed, purged, skipped, failed, blockedBySafety }
```

## 4. Pre-flight safety re-validation (TOCTOU)

The scan happened at time *T0*; disposal happens at *T1 > T0*. The filesystem can change in
between (Principle 5 idempotence + Art. 4.4). Before **every** item the engine re-validates,
operating on **file descriptors**, not path strings (spec 16 §9):

```swift
struct PreflightGate {
    func validate(_ action: PlannedAction, _ finding: Finding) throws -> Validated {
        // ① Re-guard the CANONICAL path (deny-list may have grown via config; symlink may be new)
        try ProtectedPathGuard.assertActionable(finding.item.primaryPath)      // else → exit 8
        // ② Open parent dir O_DIRECTORY|O_NOFOLLOW; open child openat(O_NOFOLLOW); fstat it.
        let fd = try openLeaf(finding.item.primaryPath)                        // spec 16 §9
        // ③ IDENTITY check vs. what the scan recorded (dev, inode, type, nlink)
        guard fd.identity.matches(finding.evidence) else { throw .identityDrift }  // → skip
        // ④ UNCHANGED check: mtime/size unchanged since scan; for confirmed items, optional
        //    checksum re-verify (staging manifest will re-hash anyway, §6).
        guard fd.mtimeNs == finding.evidence.mtimeNs, fd.size == finding.evidence.size
              else { throw .modifiedSinceScan }                                // → skip
        // ⑤ In-use / locked (spec 16 §8): UF_IMMUTABLE/SF_IMMUTABLE, advisory lock, open handle
        guard !fd.isOpenOrLocked || action.override else { throw .lockedInUse } // → skip
        // ⑥ Dataless / snapshot guard (spec 16 §4.3/4.4) — never act
        guard !fd.isDataless, fd.snapshotRef == nil else { throw .protectedShape } // → skip
        // ⑦ Volume writability: refuse system/read-only volumes (spec 16 §7)
        guard fd.volume.isWritable else { throw .readOnlyVolume }               // → skip
        return Validated(fd: fd, finding: finding, action: action)
    }
}
```

Outcomes:

- **Invariant breach** (protected/symlink-escape/mount-root) → `blockedBySafety` → **exit 8**,
  run aborts (a contract violation, not a soft skip — Art. 4.4, spec 13 §9).
- **Drift/modified/locked/dataless/read-only** → `skipped` with a specific reason → contributes to
  **exit 3** (partial), never acts on the wrong or changed file (Principle 1).
- **Clean** → proceed to disposition holding the verified fd (act relative to it, never re-resolve
  the path — closes the symlink-swap race, spec 16 §9).

Confirmation re-check (DM-5): before executing, the engine re-asserts that any `.purge` or
`.dangerous` action carries `confirmed ∈ {typedConfirmation, automationPolicy}` — even though the
plan was validated, the engine never trusts the caller (spec 14 §4.13 invariant).

## 5. Ordering & concurrency

### 5.1 Ordering rules

1. **Children before parents.** When a plan contains nested paths, deeper paths are disposed
   first so a parent directory rename/removal never orphans a child's pending action. Actions are
   topologically sorted by path depth descending within a volume.
2. **Safe before risky.** Within the plan, `safe` items first, then `medium`, then `dangerous`
   (spec 14 §4.13 "ordered safe→risky"), so an early failure/cancel leaves the safest work done
   and the riskiest untouched.
3. **Volume grouping.** Actions are grouped by `VolumeID` (DM-6 guarantees each Item is
   single-volume); same-volume actions use `rename` (O(1)); cross-volume use copy (§6.2).

### 5.2 Concurrency

Disposal is parallel across items but bounded per volume (reuse spec 17 §5.2
`ConcurrencyLimiter`): `rename` is cheap so staging throughput hits NFR-005 (≥ 10 K items/min)
even at modest parallelism; cross-volume copies are throttled per medium (network/HDD low). A
directory and its descendants are **not** disposed concurrently (ordering rule 1) — the parent
waits for children.

```swift
func execute(_ plan: CleanPlan, dryRun: Bool) async throws -> CleanReport {
    let ordered = order(plan.actions)                    // §5.1
    let tally = ReclaimTally()                            // actor, live totals (§7)
    let staging = try StagingSession.open(plan.sessionID) // spec 21; opens manifest + lock
    let limiter = ConcurrencyLimiter(volumes: plan.volumes)
    var outcomes: [ActionOutcome] = []
    try await withThrowingTaskGroup(of: ActionOutcome.self) { group in
        for action in ordered {
            group.addTask {
                await limiter.withPermit(volume: action.volume, medium: action.medium) {
                    await self.runItem(action, staging: staging, dryRun: dryRun, tally: tally)
                }
            }
        }
        for try await o in group { outcomes.append(o) }
    }
    return await finalize(plan, outcomes, tally, staging, dryRun)  // §8
}
```

## 6. Disposition execution (spec 16 §11 mechanics)

### 6.1 Stage (default, same-volume)

```
 stage(validated):
   1. capture restore metadata BEFORE moving: owner/gid/mode/ACL/xattrs/BSD flags/timestamps/
      symlinkTarget/hardlinkCount  → StagingManifestEntry.original (spec 15 §5)
   2. compute checksum (xxHash tree-manifest for dirs, sha256 for files — spec 15 §5, OQ-15.2)
   3. renameat/renameatx_np(fd-relative) into staging/<session>/files/<mirrored path>  (ATOMIC)
   4. fsync the manifest append (crash durability, spec 15 §12)
   5. measure reclaim: on-disk blocks moved, clone/hardlink-corrected (spec 14 §6)
   6. audit item.staged (spec 15 §6)  → state=staged
```

Same-volume stage is a pure metadata operation (rename) — no data copy, so even a 50 GB
DerivedData folder stages in O(1) (NFR-005). Reclaim is realized immediately because the blocks
leave the live tree (they now live in staging, counted against the retention budget, spec 21).

### 6.2 Stage (cross-volume) — copy + verify + delete

When the staging root is on a different volume than the item (rare; staging is normally
same-volume as `~/.cleaner`), atomic rename is impossible:

```
 cross-volume stage:
   1. capture metadata + source checksum (as above)
   2. clonefile if same volume else streamed copyfile(3) → staging temp path
   3. VERIFY: re-checksum the copy == source checksum   (else → failed, leave source intact)
   4. re-apply captured metadata to the copy (owner/mode/ACL/xattr/flags/timestamps)
   5. only after verified copy: unlink the source (fd-relative)   ← the point of no return
   6. atomic rename temp → final staged path; fsync manifest
```

This is **copy-verify-then-delete**: the source is never removed until the copy is
checksum-verified, so a crash before step 5 leaves the source intact (NFR-032). Step 5 is
journaled write-intent-then-act so recovery is deterministic.

### 6.3 Trash

`FileManager.trashItem` (spec 16 §10). Terminal from the tool's view (recovery via Finder, not
tool rollback). Same pre-flight + audit; `recoverability` labeled honestly (spec 13 §7). Only the
Trash category may propose it (gate ④).

### 6.4 Purge (permanent — escalation only)

Reached only via explicit escalation (DM-5: `--no-stage` + typed confirmation, or `staging purge`
of already-staged items — spec 21). `unlinkat`/fd-relative recursive removal (spec 16 §11).
Journaled write-intent before the irreversible unlink. Purge of live items (not from staging) is
the one path with no rollback — the audit records it emphatically.

## 7. Progress & live reclaim tally

```swift
actor ReclaimTally {
    private(set) var itemsDone = 0, itemsSkipped = 0, itemsFailed = 0
    private(set) var onDiskFreed: Int64 = 0, logicalRemoved: Int64 = 0
    func record(_ o: ActionOutcome) { /* fold ReclaimActual, count by result */ }
    func snapshot() -> CleanProgress { … }
}
struct CleanProgress: Sendable {
    let itemsDone, itemsTotal, skipped, failed: Int
    let onDiskFreed: Int64                     // running realized reclaim (CC-10)
    let current: FilePath?
    let phase: CleanPhase                       // .validating | .disposing | .verifying
    let eta: Duration?                          // items remaining / current item-rate
}
```

Same decoupled-sampling model as scan progress (spec 17 §7): the disposal tasks bump the actor;
a reporter polls `snapshot()` at ~250 ms onto an `AsyncStream<CleanProgress>` the TUI consumes
(NFR-022/023). The live tally shows **realized** on-disk bytes as they free, never projected.

## 8. Dry-run — identical numbers (Principle 3, DM-9)

Dry-run computes **everything** — pre-flight validation, metadata capture, checksum, reclaim
measurement, ordering, the full outcome list — and **mutates nothing**. Crucially it uses the
**identical measurement code path** as a real run (DM-9), so the projected `ReclaimActual` a
dry-run reports equals what a real run would realize (modulo TOCTOU drift):

```swift
func runItem(_ a: PlannedAction, staging: StagingSession, dryRun: Bool, tally: ReclaimTally) async -> ActionOutcome {
    let v = try? preflight.validate(a, finding(a))       // SAME validation in dry-run
    guard let v else { return skippedOutcome(a) }
    let reclaim = measure(v.fd)                            // SAME measurement (CC-10, spec 16 §3)
    if dryRun {
        // record what WOULD happen; no rename/copy/unlink; no manifest write.
        return ActionOutcome(result: dispositionResult(a), reclaimed: reclaim, stagedAs: nil, error: nil)
    }
    return await dispose(v, staging: staging, tally: tally)
}
```

The only differences a real run introduces are (a) actual byte movement and (b) manifest/audit
writes. Reclaim math, ordering, skip decisions, and the printed totals are byte-identical between
dry-run and real-run — this is what makes preview trustworthy (Principle 1: preview-first). A
mismatch between dry-run projection and real realized reclaim (from TOCTOU) is surfaced in the
report's `reclaimDelta` (spec 15 §8), never hidden.

## 9. Transactional grouping & partial-failure

The engine is **not** all-or-nothing (that would strand a huge clean on one bad file). It is
**per-item transactional** with honest partial reporting (Principle 3, NFR-035):

- Each item is its own mini-transaction (§3 state machine). Success/skip/fail is independent.
- **Already-staged items stay staged** if a later item fails — we never "roll back the whole run"
  and re-materialize freed space (that would be surprising and slow); the report lists exactly
  what moved (NFR-042).
- Aggregate result:

| Condition | Exit code (Art. 7) |
|---|---|
| All items staged/trashed/purged as planned | 0 (`ok`) |
| Some items skipped or failed, rest succeeded | 3 (`partial`) |
| A safety invariant breached (protected path attempt) | 8 (`safety`), run aborts |
| Plugin `clean` threw (couldn't propose) | 3 (`partial`) for its items (spec 13 §9) |
| Needed permission (FDA/admin) not granted | 4 (`permission`) |
| User cancelled mid-clean | 5 (`cancelled`), journaled partial (NFR-042) |

Cancellation mid-clean (NFR-040/042): the current item finishes its atomic step or is skipped at
the next boundary; the manifest + audit reflect exactly what moved; exit 5. Because each move is
atomic, no item is left half-disposed (NFR-032).

## 10. Idempotence & post-clean verification

**Idempotence (NFR-030, FR-112).** After a successful clean, the freed paths no longer exist, so
a re-scan produces no findings for them and a re-run of `clean` finds nothing new to do. The
engine relies on deterministic `FindingID`s (DM-7) and the fact that staged paths are gone from
the live tree — a second identical `clean` is a no-op (0 actions).

**Post-clean verification.** After disposal the engine verifies:
1. The source path is gone from the live tree (`fstatat` → `ENOENT`) for staged/purged items.
2. The staged copy exists and its checksum matches the captured one (for `stage`) — integrity of
   the rollback payload (spec 21).
3. Realized reclaim is cross-checked against a volume `statfs` delta (before/after) as a sanity
   bound; per-item accounting is the authority, the `statfs` delta is the guard against
   gross error (surfaced in `reclaimDelta`, spec 15 §8).

Verification failures downgrade the item's outcome (e.g. staged-but-checksum-mismatch → `failed`
with the source already moved is impossible because verify happens on the staged copy after an
atomic move; a mismatch means corruption → audit + warn, item marked `staged` with an integrity
warning flag for spec 21 to refuse silent restore).

## 11. Engine API sketch

```swift
public protocol CleanupEngine: Sendable {
    /// Execute a confirmed plan. dryRun computes identical numbers, mutates nothing (DM-9).
    func execute(_ plan: CleanPlan, dryRun: Bool) async throws -> CleanReport
    /// Live progress for the TUI (spec 25), independent of the result await.
    var progress: AsyncStream<CleanProgress> { get }
}

/// Re-validates & disposes; owns the four gates at CLEAN time (TOCTOU re-check).
struct Disposer: Sendable {
    let fs: FilesystemService            // spec 16 §11 dispose mechanics
    let guardGate: ProtectedPathGuard    // spec 16 §9 — re-run at clean, not just scan
    let scorer: SafetyScorer             // re-confirm risk didn't change (evidence re-gathered)
    let audit: AuditSink                 // spec 15 §6
    func dispose(_ v: Validated, staging: StagingSession, tally: ReclaimTally) async -> ActionOutcome
}

enum DisposalError: CleanerError {       // each carries an exit code (Art. 7)
    case protectedPath          // → 8
    case symlinkEscape          // → 8
    case identityDrift          // → skip (3)
    case modifiedSinceScan      // → skip (3)
    case lockedInUse            // → skip (3)
    case crossVolumeCopyFailed  // → failed (3)
    case checksumMismatch       // → failed (3)
    case permissionDenied       // → 4
}
```

`execute` never trusts `plan` blindly: it re-runs `plugin.clean` only to fetch directives, then
re-guards, re-stats, and re-confirms every action (spec 13 §10 gate ④). The `CleanReport` it
returns carries measured `realizedReclaim`, the estimate-vs-actual delta, `stagingSessionPath`,
per-item `ActionOutcome`s with `StagedRef`s, and the aggregate `exitCode` (spec 14 §4.14).

## 12. Performance targets (tie to spec 07)

| Target | NFR | How met |
|---|---|---|
| ≥ 10 K items/min staging; intra-volume O(1) rename | NFR-005 | §6.1 `renameat`, no copy; bounded parallelism (§5.2). |
| Crash consistency: fully staged or untouched | NFR-032 | Atomic rename / copy-verify-then-delete (§6.2); journaled write-intent (§3, spec 15 §12). |
| Idempotent re-clean is a no-op | NFR-030 | Deterministic `FindingID` + gone-from-tree (§10). |
| Graceful degradation; partial → exit 3 | NFR-035 | Per-item transaction (§9), plugin isolation (spec 13 §9). |
| Cancel < 200 ms, partial journaled | NFR-040/042 | Boundary cancel + atomic step (§9); manifest/audit reflect reality. |
| Dry-run numbers == real numbers | NFR-... / DM-9 | Identical measurement path (§8). |

Benchmarks `dispose-throughput`, fault-injection `T-crash-consistency`, `T-idempotent-*`,
`T-partial-journal`, `T-cancel-latency` (spec 30/31) verify each.

## Open Questions

- **OQ-20.1** Checksum on stage for multi-GB trees: xxHash tree-manifest (fast, integrity) vs.
  SHA-256 (slower, security) — inherits spec 15 OQ-15.2. *Leaning: xxHash for staged-tree
  integrity; SHA-256 only where dedup already computed it.*
- **OQ-20.2** Should post-clean `statfs` cross-check be per-volume once at end (cheap) or per-item
  (expensive, precise)? *Leaning: per-item accounting is authority; one `statfs` delta per volume
  at end as a sanity bound (§10).*
- **OQ-20.3** Cross-volume staging is discouraged (staging normally same-volume as `~/.cleaner`);
  do we ever *want* cross-volume stage, or should we require staging on the item's own volume and
  only fall to copy for the rare mismatch? *Leaning: prefer per-volume staging roots to keep
  rename atomicity; copy path is the exception (spec 21).*
- **OQ-20.4** For `dangerous` items, do we require re-typed confirmation at clean time if a long
  gap passed since planning, or trust the plan's `ConfirmationState`? *Leaning: trust the plan
  within a session; a new session re-confirms. Coordinate with spec 25.*
- **OQ-20.5** Partial-failure: offer an optional `--atomic` all-or-nothing mode that rolls back
  staged items on any failure? *Leaning: no for v1 (surprising, slow); per-item partial is the
  documented contract. Revisit if users ask.*
- **OQ-20.6** Directory purge vs. stage of a huge tree that is partly protected (a protected file
  nested inside a cleanable dir): stage the dir but the guard must exclude the nested protected
  path — do we split the Item or refuse the whole dir? *Leaning: the scanner already excludes
  protected descendants (DM-4); a dir Item never contains a protected path. Assert at pre-flight.*

## Dependencies

**Consumes:** 00-constitution (Principles 1/2/3/5, Art. 4.4 invariants, Art. 5 protected paths,
Art. 7 exit codes 0/3/4/5/8, CC-7 stage-then-purge, CC-10 reclaim), 07-nfr
(NFR-005/030/032/035/040/042), 13-plugin-architecture (propose→dispose, `CleanDirective`,
`RollbackHint`, error isolation §9, funnel gate ④), 14-domain-model (`CleanPlan`, `PlannedAction`,
`Disposition` DM-5, `CleanReport`, `ActionOutcome`, `ReclaimActual` DM-8/9, confirmation
invariant), 15-data-model (§5 staging manifest write, §6 audit, §12 locking/fsync/atomic rename),
16-filesystem-strategy (§9 TOCTOU fd-relative mutation, §11 stage/trash/purge mechanics, §7 volume
writability), 17-scan-engine (consumes `ScanResult`; re-validates, never trusts cache), 18-rule
(gated dispositions), 22-safety-model (SafetyScorer re-confirm, invariants).

**Feeds:** 21-rollback-design (writes the staging tree + manifest it restores from), 22-safety-model
(clean-time gate enforcement), 28-logging (audit of every mutation), 30-benchmark-plan
(dispose/crash benches), 31-testing-strategy (idempotence/crash/partial tests).
