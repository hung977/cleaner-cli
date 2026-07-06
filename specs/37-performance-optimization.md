# 37 — Performance Optimization

> **Phase G · Depends on:** 00-constitution (Principle 9 performance, CC-3 concurrency, CC-10 reclaim
> measurement), 07-nonfunctional (every performance/scalability/responsiveness NFR), 10-tech-stack
> (Swift Concurrency, System `FilePath`, Darwin APIs), 12-module (`CleanerEngine`/`CleanerPlatform`
> hot paths), 16-filesystem-strategy (getattrlistbulk, allocated-size, per-volume concurrency), 17
> (scan engine), 30 (each technique's guarding benchmark) ·
> **Depended on by:** 17/19/20 implementation, 34 (perf gate enforces the wins).

## 1. Purpose & how to read this spec

This is the **playbook** for meeting the performance NFRs (spec 07 §2–4, §14). Each technique below is
stated as: *what*, *the NFR target it serves*, *the benchmark from spec 30 that guards it*, and *the
mitigation for its downside*. Nothing here is speculative — every optimization is tied to a number and a
test, per Constitution Principle 9 ("performance is a feature") and Art. 11 ("no number is a defect").

The overarching model (spec 16 §13): **stream, don't materialize; batch syscalls; act on file
descriptors, not path strings; bound concurrency to the volume; and never allocate per file in the hot
loop.**

## 2. Perf budget breakdown (where the time goes)

For a full-volume `analyze` on **W-large** (5 M files, RM), the target wall-time is dominated by
enumeration; the budget allocates it so each phase has an owner and a benchmark:

| Phase | Target share of `analyze` wall | Owner | NFR | Bench (spec 30) |
|---|---|---|---|---|
| Directory enumeration (`getattrlistbulk`) | ~60 % | `CleanerPlatform.BulkEnumerator` | NFR-001 | `scan-throughput` |
| Allocated-size measurement | ~5 % (must be < 5 % overhead) | enumerator (same syscall) | NFR-008 | `measure-overhead` |
| Rule matching + safety scoring | ~15 % | `RuleEngine`/`SafetyScorer` | NFR-003 | `analyze-latency` |
| Evidence enrichment (candidates only) | ~15 % | `MetadataReading` | NFR-003 | `analyze-latency` |
| Accumulation + sort for output | ~5 % | `ScanAccumulator` actor | NFR-031 | `analyze-latency` |

Memory budget (NFR-002): **< 300 MB RSS** for scan regardless of tree size → working set is O(open-dir
depth × batch buffer + bounded accumulators + finding page), *never* O(files). Dedup pass gets a
separate **< 500 MB** budget (§9). Startup budget (NFR-120): **< 150 ms** RM → §11.

## 3. Enumeration — `getattrlistbulk` batching (NFR-001, `scan-throughput`)

The single biggest lever (spec 16 §2). One `getattrlistbulk(2)` returns *many* directory entries *with*
their attributes in one syscall, versus `readdir`+`stat` per entry.

- **Batch into a reused fixed buffer** (~64 KiB) decoding N≈100 entries/call → roughly **one syscall per
  ~100 files** instead of one `stat` each. This is *the* reason we hit 250 K files/min.
- **Request exactly the lean attribute set** the hot walk needs (name, `fsobj_type`, `st_ino`,
  `ATTR_FILE_ALLOCSIZE` + `st_size`, `st_mtime` ns, `st_flags`, `nlink`, mode/uid) — one shot, no
  double-fetch. Richer evidence (xattrs, Spotlight) is deferred to *candidate* findings only (§7).
- **fd-relative descent:** `open(dir, O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`, enumerate via the fd, descend
  with `openat` on child names — no per-level path re-resolution, and TOCTOU-safe (spec 16 §9).
- **Downside/mitigation:** raw C attribute-buffer packing is error-prone → isolated in one
  `// SAFETY:`-noted `BulkEnumerator` adapter with exhaustive decode tests (spec 31 `CleanerPlatformTests`
  cross-checks decoded fields against `FileManager`). Network/`ENOTSUP` volumes fall back to
  `FileManager.enumerator` (spec 16 §2.3) — correctness preserved, throughput target waived on those.
- **Guard:** `scan-throughput` (files/min) + the `T-syscall-batching` invariant test (spec 31/30 §3)
  asserting syscalls scale ~n/100, not ~n.

## 4. Avoid path-string allocations — `FilePath`/file descriptors (NFR-007, `alloc-per-file`)

Hot-loop allocation is the enemy of both throughput and the < 300 MB RSS ceiling.

- **`System.FilePath`, not `URL`/`String`.** `URL` allocates (and CFString-bridges) per entry;
  `FileManager` resource-value dictionaries allocate `NSDictionary`. `FilePath` is value-type, contiguous,
  and appends a child component without a fresh heap `String` where the API allows in-place growth.
- **Build child paths by appending to a reused parent `FilePath`**, not by formatting `"\(parent)/\(name)"`
  (which allocates a `String` and a new `URL`). Better still, **don't build a full path at all** in the
  walk — carry the parent **directory fd + name**, materializing a path only when a finding is *recorded*
  (a tiny fraction of entries).
- **Reuse buffers:** the `getattrlistbulk` buffer, the attribute-decode scratch, and the name decode
  buffer are per-worker and reused across batches (no per-file allocation).
- **Target:** ≤ **1 heap allocation per file amortized** (NFR-007). The `FSNode` value is a struct held
  briefly on the stack / in the batch buffer, not boxed.
- **Downside/mitigation:** `FilePath` ergonomics are lower-level than `URL`; wrapped so plugins never
  see it (they get resolved `Item` paths). **Guard:** `alloc-per-file` benchmark (mallocs/file ≤ 1.0) on
  `W-manysmall` — the worst case (2 M tiny files).

## 5. Streaming aggregation, bounded memory (NFR-002, `mem-rss`/`heap-peak`)

- **Never build an in-memory tree.** Enumeration is an `AsyncThrowingStream<FSNode>`; directory sizes are
  accumulated by *streaming* addition into a running `Int64` per open directory (spec 16 §3), folded
  upward as a `Deque`-based work queue drains. Working set ~ O(depth × buffer), not O(files).
- **Bounded accumulators:** the `actor ScanAccumulator` (CC-3) holds per-directory subtotals keyed by
  inode, released as subtrees complete — not every file's record.
- **Paged findings (NFR-013):** findings stream to the presenter/`--json`/TUI in pages; ≥ 1 M findings
  are never all resident (§8). The report writer serializes incrementally (`JSONEncoder` over a stream,
  not one giant array in memory).
- **Downside/mitigation:** streaming makes a global sort need a bounded external/heap-based approach
  (§8). **Guard:** `mem-rss/W-large` and `mem-rss/W-huge` (< 300 MB), `scale-4tb` asserts flat RSS as
  file count grows.

## 6. Bounded concurrency tuned per volume (NFR-006/012, `cpu-scaling`)

- **`TaskGroup` fan-out with a concurrency limiter** (CC-3, spec 17) sized from `VolumeInfo.medium`
  (DiskArbitration, spec 16 §7): SSD → ~cores×2; HDD → low/serial (seeks dominate, more threads = more
  thrash); network → very low + longer timeouts; external → moderate. Multiple volumes scanned
  concurrently, each with its own cap (NFR-012).
- **Work-stealing over directories**, not files: each task owns a directory fd and enumerates it fully,
  so batching (§3) stays effective and the limiter throttles *directory* concurrency.
- **Don't spin idle cores, don't oversubscribe:** default parallelism = `min(cores, IO-derived cap)`
  (NFR-006). Over-concurrency shows up as context-switch storms — measured (`.contextSwitches`, spec 30
  §3) and tuned down.
- **Downside/mitigation:** wrong cap tanks HDD/network throughput → the cap is data-driven from the
  actual volume medium, with a `--concurrency` override for power users and CI determinism.
- **Guard:** `cpu-scaling` (≥ 5× speedup 1→8 cores on SSD, NFR-006); `T-multi-volume` correctness.

## 7. Lazy evidence, candidate-only enrichment (NFR-003, `analyze-latency`)

- **Two-tier enumeration:** the bulk walk gathers only the lean attribute set (§3). Expensive **evidence**
  — xattrs (`whereFroms`, quarantine, tags), Spotlight `kMDItemLastUsedDate`/kind, Launch Services
  registration — is fetched **only for entries that a rule already flagged as a candidate** (spec 16
  §5, OQ-16.4). Enriching 100 % of 5 M files would blow the latency budget; enriching the ~1 % that are
  findings is cheap.
- **Downside/mitigation:** a rule that needs an evidence field to *decide* candidacy would defeat this →
  such rules declare their needed fields in a manifest so the enumerator can batch-fetch just those
  cheaply, and the scorer requests the rest lazily. **Guard:** `analyze-latency/W-small` cold < 20 s.

## 8. Lazy loading & pagination of findings (NFR-013, `T-large-result-stream`)

- Findings are an `AsyncStream` from engine → presenter. The TUI holds only the **visible window +
  a small look-ahead** (spec 25); scrolling pulls more. `--json` writes findings incrementally.
- **Bounded global sort:** where a total ordering is required (largest-first), use a **bounded heap**
  (`swift-collections` `Heap`) of the top-K plus streamed spill, or a stable external merge — never load
  all findings to sort. Sort keys are stable (path/inode) for determinism (NFR-031).
- **Guard:** `T-large-result-stream` (≥ 1 M findings paged, memory flat).

## 9. Duplicate detection — cheap prefilter then parallel hash (NFR-004/002, `dupe-pipeline`)

The dedup pipeline (spec 19, `CleanerPlugins/Duplicates`) must hash **< 5 % of total bytes** and finish
W-dupes in < 8 min, within a 500 MB RSS budget:

1. **Group by size** (free — already have `st_size` from the bulk walk). Singleton size-classes can't be
   duplicates → discarded with zero I/O.
2. **Cheap prefilter on collision groups:** a fast **head/tail sample hash** (e.g. `xxHash`/rolling over
   the first+last 4 KiB, spec 10 §2) to split same-size files without reading full contents. Most
   accidental size-collisions separate here.
3. **Full SHA-256 (CryptoKit) only on surviving groups**, hashed in **parallel** (`TaskGroup`, bounded
   like §6) with **streamed reads** (fixed reused buffer, no whole-file-in-memory) so a group of huge
   files doesn't blow RSS.
4. **APFS-clone awareness (spec 16 §4.1):** files already sharing extents (clones) are *not* reclaimable
   duplicates → detected and excluded before hashing (don't hash what deleting won't free).
- **Downside/mitigation:** the sample-hash can theoretically pass non-duplicates → the full SHA-256 on
  survivors is authoritative before any dedup action (Principle 1 — never dedup on a weak hash).
- **Guard:** `dupe-pipeline` wall < 8 min **and** `hash-bytes-ratio < 5 %` (spec 30 §8), RSS < 500 MB.

## 10. Disposal throughput — rename, not copy (NFR-005, `dispose-throughput`)

- **Intra-volume staging is `renameat`/`renameatx_np`** — O(1) per item, no data movement, atomic
  (spec 16 §11). Moving a 40 GB DerivedData dir to staging is a metadata op, not a 40 GB copy.
- **Cross-volume fallback** (`clonefile` where possible, else streamed `copyfile`) is bounded and
  *reported* as slower (truth-in-reporting) — but staging is same-volume by construction (session
  staging lives on each target's volume) so the fast path is the norm.
- **Batch the journal writes** (spec 21) — one fsync per batch of moves, not per item, while keeping
  crash-consistency (NFR-032): the journal records intent before the batch and completion after.
- **Guard:** `dispose-throughput` ≥ 10 K items/min.

## 11. Startup time (NFR-120, `startup`)

- **< 150 ms** `cleaner --version` on RM → keep the composition root lean: no eager plugin scanning, no
  config parse on `--version`, no DiskArbitration/Spotlight session until a command needs it (lazy
  provider construction).
- **Static-ish linking** (spec 32 §3) avoids dylib resolution cost; **version is compiled in** (spec 32
  §11), no file read.
- **Defer heavy init:** the emoji-width table, theme tables, and plugin registry initialize on first use,
  not at process start.
- **Guard:** `startup` (< 150 ms RM / < 300 ms SM) and `ConfigBench` ensures config load doesn't creep
  into the startup path.

## 12. Foundation avoidance in hot loops

- Prefer Darwin/`System` over Foundation where Foundation bridges to CF/ObjC per call: raw
  `getattrlistbulk` over `FileManager.enumerator`; `FilePath` over `URL`; manual `Int64` byte math over
  `ByteCountFormatter` in the loop (format only at *display* time, NFR-081); avoid `Date` allocation per
  file (compare raw `mtimeNs` `Int64` against a precomputed threshold; construct `Date`/`FormatStyle`
  only for the ~1 % of displayed findings).
- **Downside/mitigation:** less ergonomic, and locale-aware formatting (NFR-081) still must happen — it
  does, but at the presentation boundary (`CleanerReport`/`CleanerTUI`), not in the scan. **Guard:**
  `alloc-per-file`, `analyze-latency`.

## 13. Incremental scan cache (NFR-003 warm, FR-007)

- The tool caches per-directory `(inode, mtime, size, subtree-total)` stamps under `~/.cleaner/cache`
  keyed by `VolumeID` (spec 16 §7). On a warm re-scan, a directory whose `mtime` and entry-count are
  unchanged is **skipped** (its cached subtree total reused) — turning a 20 s cold `analyze` into a < 5 s
  warm one (NFR-003).
- **Invalidation:** any mtime/size drift, a changed `VolumeID` (remounted different volume), or a config/
  plugin change bumps a cache epoch and forces re-scan of affected subtrees. Correctness beats speed —
  a stale cache never causes a wrong finding (the cache stores *sizes/structure*, and every actionable
  disposition re-validates live via TOCTOU checks, spec 16 §9).
- **Resume (NFR-041):** a checkpoint file lets a cancelled scan resume re-scanning < 10 % (spec 17).
- **Guard:** `analyze-latency/W-small/warm` < 5 s; `T-resume`.

## 14. Cancellation checkpoints (NFR-040/023, `T-cancel-latency`)

- `Task.checkCancellation()` at **directory boundaries** (not per-file — too frequent) gives cancel
  latency < 200 ms while keeping the check off the per-file hot path (spec 16 §2, spec 17). Work runs off
  the render actor so the TUI stays interactive (NFR-023).
- **Downside/mitigation:** a single pathological directory with 1 M direct children (W-wide) could delay a
  cancel > 200 ms → within such mega-directories we also check cancellation every *batch* (§3), bounding
  latency without per-file cost.
- **Guard:** `T-cancel-latency`, `T-tui-nonblocking`.

## 15. Memory pooling / buffer reuse

- Per-worker reusable buffers: the `getattrlistbulk` buffer, attribute-decode scratch, hash read buffer
  (§9), and the report serialization buffer are allocated once per worker/task and reused across
  iterations — no churn, stable RSS.
- Value types (`FSNode`, `Item`, `SizePair`) avoid heap boxing; collections are pre-`reserveCapacity`'d
  where the size is known (batch counts).
- **Guard:** `heap-peak`, `alloc-per-file`.

## 16. ARC / retain-cycle avoidance & Sendable discipline (NFR-033)

- Hot data-flow uses **value types** (structs) so there's no ARC traffic in the enumeration loop (ARC
  retain/release on class instances per file would be a measurable tax).
- **`actor`s** (`ScanAccumulator`, `StagingManager`) serialize shared mutation without locks (CC-3);
  closures captured by tasks use `[weak]`/`unowned` where a cycle is possible; long-lived provider
  objects are structs or actors, not retained-graph classes.
- Swift 6 **strict concurrency** (NFR-033, spec 34 gate) catches data races at compile time; **zero
  `@unchecked Sendable`** without a `// SAFETY:` note (Art. 6). No `@unchecked` used to paper over a real
  race for speed.
- **Guard:** strict-concurrency build gate (spec 34); `contextSwitches`/`cpu-scaling` catch lock
  contention regressions.

## 17. Measuring — Instruments & signposts

- Every major phase emits an `os_signpost` interval (`OSSignposter`, category `com.cleaner.perf`) —
  `enumerate`, `measure`, `score`, `enrich`, `stage`, `hash` — the *same* names the benchmarks use
  (spec 30 §11). A regression flagged by `bench.yml` (spec 34 §6) is re-run under **Instruments** (Time
  Profiler for CPU attribution, Allocations for `alloc-per-file`, System Trace for syscalls) and the
  offending signposted phase is isolated.
- `--debug` surfaces per-phase durations + per-plugin counts to **stderr** (NFR-112, not polluting
  `--json` stdout) so a user can profile in the field without Instruments.
- **Guard:** the signpost names are a contract; a bench asserts they bracket the measured window.

## 18. Known bottlenecks & mitigations

| # | Bottleneck | Symptom | Mitigation | NFR | Guard bench |
|---|---|---|---|---|---|
| B1 | Per-entry `stat`/`URL` allocation | RSS climb, low throughput | `getattrlistbulk` + `FilePath` + fd descent (§3/§4) | 001/007 | `scan-throughput`, `alloc-per-file` |
| B2 | Whole-tree in memory | OOM on W-huge | streaming enumeration + bounded accumulators (§5) | 002/010 | `mem-rss`, `scale-4tb` |
| B3 | Eager evidence on all files | analyze latency blow-up | candidate-only enrichment (§7) | 003 | `analyze-latency` |
| B4 | Hashing every same-size file | dedup too slow, RSS spike | size + sample-hash prefilter, clone exclusion (§9) | 004/002 | `dupe-pipeline` |
| B5 | Copy-based staging | slow disposal on big dirs | `renameat` intra-volume O(1) (§10) | 005 | `dispose-throughput` |
| B6 | HDD/network over-concurrency | seek thrash, worse-than-serial | per-volume concurrency cap (§6) | 006/012 | `cpu-scaling`, `T-multi-volume` |
| B7 | Mega-directory cancel lag | cancel > 200 ms | per-batch cancellation checkpoint (§14) | 040 | `T-cancel-latency` |
| B8 | `ByteCountFormatter`/`Date`/`URL` in loop | CPU + alloc tax | raw math, format at display boundary (§12) | 003/007 | `analyze-latency`, `alloc-per-file` |
| B9 | Cold re-scan every run | slow warm `analyze` | incremental cache (§13) | 003 | `analyze-latency/warm` |
| B10 | Allocated-size double query | measure overhead > 5 % | reuse `getattrlistbulk` ALLOCSIZE, no separate URL query (§2/§3) | 008 | `measure-overhead` |
| B11 | Sync/fsync per staged item | disposal stall | batch journal fsync (§10) | 005/032 | `dispose-throughput`, `T-crash-consistency` |
| B12 | TUI full-frame redraw | frame > 33 ms, flicker | double-buffered diff render, off-render-actor work (§ spec 25) | 020/023 | `tui-frame` |

## Open Questions

- **OQ-37.1** Optimal `getattrlistbulk` batch buffer size and attribute set (lean vs. rich) — inherits
  spec 16 OQ-16.4; final number set by re-baselining `scan-throughput`/`alloc-per-file` on the RM.
- **OQ-37.2** Sample-hash prefilter (§9): head+tail 4 KiB vs. a rolling hash over sparse offsets — which
  best minimizes `hash-bytes-ratio` without raising false-negative dedup risk? *Leaning: head+tail 4 KiB,
  validated against W-dupes.*
- **OQ-37.3** Incremental cache (§13) invalidation granularity — per-directory mtime is cheap but misses
  in-place same-mtime edits (rare); do we also stamp entry counts / a cheap content signal? *Leaning:
  mtime + entry-count + size; never trust cache for the *action* (live TOCTOU re-check regardless).*
- **OQ-37.4** Per-volume concurrency defaults (§6) — exact multipliers for SSD/HDD/network need empirical
  tuning on RM/SM + a network share; ship conservative defaults, expose `--concurrency`.
- **OQ-37.5** Is the 300 MB scan RSS ceiling (NFR-002) achievable alongside the emoji-width table +
  accumulators (spec 07 OQ-07.1)? Re-measure `mem-rss` once the width table lands; if tight, lazy-load
  the table only when the TUI is active (headless/`--json` scan skips it).

## Dependencies

**Consumes:** 00 (Principle 9 performance, CC-3 concurrency, CC-10 reclaim measurement), 07 (every
performance NFR quantified here: 001–008, 010–013, 020–023, 040–042, 120–121), 10 (Swift Concurrency,
`System.FilePath`, Darwin `getattrlistbulk`/`renameatx_np`, CryptoKit/`xxHash`), 12 (the `CleanerEngine`/
`CleanerPlatform` hot-path targets these techniques live in), 16 (getattrlistbulk batching, allocated-
size, fd-relative traversal, per-volume concurrency, clone/sparse/hardlink semantics), 17 (scan engine
concurrency limiter, cancellation checkpoints, incremental cache), 30 (each technique cites its guarding
benchmark and the signpost phase contract).

**Feeds:** 17/19/20 implementation (this is their optimization brief), 34 (the benchmark-regression gate
enforces these wins don't rot), and back into 30 (the known-bottleneck table names the benchmark that
guards each mitigation).
