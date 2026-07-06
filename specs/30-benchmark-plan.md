# 30 — Benchmark Plan

> **Phase G · Depends on:** 00-constitution (Art. 7 exit codes, Art. 10 CC-9), 07-nonfunctional
> (every `bench …` verification), 10-tech-stack (§9 package-benchmark, CC-9), 12-module-decomposition
> (`ScanBench` target, `CleanerTestKit`, `VirtualFileSystem`), 16-filesystem-strategy (getattrlistbulk,
> allocated-size, per-volume concurrency) ·
> **Depended on by:** 31 (shares the fixture generator), 34 (CI enforces the thresholds), 37
> (each optimization ties to a benchmark here).

## 1. Purpose & scope

This spec is the **executable proof** of the performance NFRs (spec 07 §2, §3, §4, §14). It defines:
the benchmark harness (`package-benchmark`, CC-9), the synthetic filesystem fixtures and their
generator, the scenario/workload matrix, the metrics collected, the numeric targets (each traced to
an NFR), the regression thresholds the CI gate enforces (spec 34), and how results are tracked over
time. Every `bench <name>` token that appears in spec 07's "Verification" column is realised here as a
named benchmark.

Non-goals: correctness testing (spec 31), profiling technique and code-level tuning (spec 37 —
though §11 here hands profiling *targets* to that spec).

**Golden rule (Constitution Principle 3 — truth in reporting):** a benchmark measures the *same code
paths* the product ships. No benchmark-only shortcuts, no measuring a stubbed enumerator. The scan
benchmark drives `ScanEngine.scan` exactly as `analyze` does.

## 2. Harness — package-benchmark (ordo-one)

- Benchmarks live in **benchmark targets** (spec 12 §4, `.benchmarkTarget`), one executable per
  subsystem, under `Benchmarks/`:

  | Benchmark target | Subsystem under test | NFRs |
  |---|---|---|
  | `ScanBench` | `CleanerEngine.ScanEngine` enumeration + measurement | NFR-001/002/003/006/007/008/010 |
  | `DedupBench` | `CleanerPlugins/Duplicates` + `CryptoKit` prefilter/hash | NFR-002(dupe)/004 |
  | `DisposeBench` | `CleanerEngine.StagingManager`/`CleanupEngine` | NFR-005/032 |
  | `TUIBench` | `CleanerTUI` renderer frame diff | NFR-020/024 |
  | `StartupBench` | `cleaner` executable process spin-up | NFR-120/121 |
  | `ConfigBench` | `CleanerConfig` load/merge (guards startup) | NFR-120 |

- `Package.swift` gates them behind the benchmark plugin so a normal `swift build` never compiles
  them (keeps dev builds fast, spec 12 §7):

```swift
// Benchmarks/ScanBench/Benchmarks.swift
import Benchmark
import CleanerEngine
import CleanerTestKit   // FixtureFS generator (§5), FixedClock, FakeProviders

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .throughput, .peakMemoryResident,
                  .mallocCountTotal, .syscalls, .cpuTotal, .contextSwitches],
        warmupIterations: 1,
        scalingFactor: .one,
        maxDuration: .seconds(20),
        maxIterations: 100,
        thresholds: [                                  // §8 regression gate
            .wallClock: .init(relative: [.p90: 8.0]),  // fail if p90 > +8 %
            .peakMemoryResident: .init(relative: [.p90: 5.0]),
            .mallocCountTotal: .init(relative: [.p90: 3.0]),
        ])

    Benchmark("scan-throughput/W-large/warm",
              configuration: .init(metrics: [.throughput, .wallClock])) { benchmark in
        let fs = FixtureCatalog.wLarge.materialized()          // §5 (cached on disk)
        benchmark.startMeasurement()
        var files = 0
        for try await _ in ScanEngine.production.scan(root: fs.root, options: .bulkWarm) {
            files += 1
        }
        benchmark.stopMeasurement()
        benchmark.measurement(.custom("files"), Double(files))
    }
}
```

- **Statistical rigor.** `package-benchmark` reports percentiles (p50/p75/p90/p99/p100), not a single
  mean; the gate keys on **p90** to tolerate scheduler noise without hiding real regressions. Absolute
  and relative thresholds both supported (§8).
- **Deterministic measurement window.** Fixture materialization and cache priming happen *outside*
  `startMeasurement()/stopMeasurement()`; only the code under test is inside the window.
- Baselines are stored per reference machine (§9) as `package-benchmark` baseline JSON under
  `Benchmarks/.baselines/<machine-id>/`.

## 3. What we measure (metrics)

| Metric | package-benchmark source | Why it matters (NFR) |
|---|---|---|
| **Wall time** (p50/p90/p99) | `.wallClock` | latency NFR-003, NFR-004, NFR-120 |
| **Throughput — files/s** | `.throughput` + custom `files` counter | NFR-001 (converted to files/min) |
| **Throughput — bytes/s** | custom `bytes` counter / wall | measurement/dispose sanity |
| **Peak RSS** | `.peakMemoryResident` | NFR-002 (<300 MB scan / <500 MB dupe) |
| **Heap peak / allocations** | `.mallocCountTotal`, `.memoryLeaked` | NFR-007 (≤1 alloc/file), NFR-002 |
| **Syscalls** | `.syscalls` (dtrace/`getrusage`) | validates getattrlistbulk batching (NFR-001, spec 16 §13) |
| **CPU total / scaling** | `.cpuTotal`, `.cpuUser`, `.cpuSystem` | NFR-006 (core scaling) |
| **Context switches** | `.contextSwitches` | over-concurrency / lock contention (NFR-006) |
| **Custom: alloc-per-file** | `mallocCountTotal / files` | NFR-007 headline (must be ≤ 1.0 amortized) |
| **Custom: hash-bytes-ratio** | `hashedBytes / totalBytes` | NFR-004 (<5 % bytes hashed) |
| **Custom: reclaim-overhead** | wall(scan+measure) / wall(scan-only) − 1 | NFR-008 (<5 %) |
| **Custom: fps / frame-ms** | `1000 / frameMs` | NFR-020 (≥30 fps, ≤33 ms p95) |

Syscall and page-fault counting on macOS uses `getattrlistbulk`-visible `getrusage` deltas plus a
DTrace probe provider gated behind `--syscall-trace` (needs SIP-relaxed CI runner; otherwise the
`syscalls` metric is reported as `n/a` and the batching invariant is checked via the unit test
`T-syscall-batching` in spec 31 instead — no CI hole).

## 4. Scenario & workload matrix

Two axes: **workload fixture** (the tree shape/size, §5) × **scenario** (which subsystem + cache
state). Not every cell is run in the PR gate (§8); the full grid runs nightly (spec 34).

### 4.1 Workloads (fixtures)

| Fixture | Files | Bytes (on-disk) | Shape | Purpose | Maps to spec 07 |
|---|---|---|---|---|---|
| `W-tiny` | 10 K | ~2 GB | balanced | fast PR-gate signal | smoke |
| `W-small` | 200 K | ~50 GB | realistic `$HOME` dev-cache mix | analyze latency | **W-small** |
| `W-medium` | 1 M | ~400 GB (sparse-backed) | mixed | mid-scale trend | interpolation |
| `W-large` | 5 M | ~800 GB (sparse-backed) | mixed | throughput/memory stress | **W-large** |
| `W-huge` | 10 M | ~1.2 TB (sparse-backed) | mixed | scale ceiling | NFR-010 |
| `W-dupes` | 1 M | 30 % duplicate bytes | dup clusters | dedup pipeline | **W-dupes** |
| `W-deep` | 500 K | — | depth ≥ 64, ≤ 20 children/dir | recursion/stack | NFR-011 |
| `W-wide` | 500 K | — | one dir with ≥ 1 M direct children | flat-dir enumeration | NFR-011 |
| `W-manysmall` | 2 M | ~4 GB (avg 2 KB) | tiny files | syscall/alloc worst case | NFR-001/007 |
| `W-fewlarge` | 500 | ~800 GB (sparse) | huge files | measurement/dispose | NFR-005/008 |
| `W-clones` | 200 K | logical 200 GB / on-disk 60 GB | APFS `clonefile` clusters | reclaim truthfulness | NFR-008, spec 16 §4.1 |
| `W-hostile` | 100 K | — | symlink loops, perm-denied dirs, dataless placeholders | robustness under load | NFR-035, spec 31 stress |

> **Sparse-backing note.** `W-large`/`W-huge` would be impractical to store at true size. The
> generator uses **sparse files** (`ftruncate` to logical size, no block allocation) and **APFS
> clones** so a 1.2 TB *logical* fixture occupies a few GB on the runner. Because the tool measures
> **on-disk allocated size** (CC-10, spec 16 §3), the benchmark separately configures which fixtures
> are sparse vs. block-backed: throughput/enumeration benches use sparse (file *count* is what matters);
> the `W-clones`/`W-fewlarge` reclaim-accuracy benches use real allocation so `sizeOnDisk` is truthful.

### 4.2 Scenarios (per subsystem)

| Scenario id | Command-equivalent | Subsystem | Cache | Fixtures |
|---|---|---|---|---|
| `scan-throughput` | `analyze --dry-run` enumeration | ScanEngine | warm+cold | W-large, W-huge, W-manysmall |
| `analyze-latency` | `analyze` end-to-end | ScanEngine+scorer | cold, warm | W-small |
| `mem-rss` / `heap-peak` | `analyze` | ScanEngine | warm | W-large, W-huge |
| `alloc-per-file` | enumeration only | ScanEngine | warm | W-manysmall, W-large |
| `measure-overhead` | scan w/ vs w/o allocated-size query | ScanEngine | warm | W-fewlarge, W-clones |
| `cpu-scaling` | scan @ P∈{1,2,4,8,cores} | ScanEngine limiter | warm | W-large |
| `dupe-pipeline` | `analyze --plugin duplicates` | Duplicates | warm | W-dupes |
| `dispose-throughput` | `clean --yes` (stage) | Staging/Cleanup | — | W-small subset, W-wide |
| `tui-frame` | live-scan render loop | CleanerTUI | — | synthetic finding stream |
| `startup` | `cleaner --version` | executable | — | — |
| `time-to-first-frame` | `analyze` → first frame | App+TUI | cold | W-small |
| `scale-4tb` | `analyze` (nightly only) | full pipeline | cold | W-huge |

## 5. Fixture generator design (`FixtureFS`)

Lives in `CleanerTestKit` (shared with spec 31 so unit tests and benches use *identical* trees) and is
driven by a declarative spec so fixtures are **reproducible** (Constitution Principle 5 —
determinism) and **cacheable** (materialize once, reuse across iterations/CI runs via content hash).

```swift
// CleanerTestKit/FixtureFS.swift
public struct FixtureSpec: Sendable, Codable, Hashable {
    public var fileCount: Int
    public var shape: Shape                 // .balanced(fanout:) | .deep(depth:) | .wide(children:)
    public var sizeModel: SizeModel         // .fixed(bytes:) | .lognormal(median:sigma:) | .sparse(logical:)
    public var dupFraction: Double = 0      // fraction of bytes that are byte-identical clusters
    public var cloneFraction: Double = 0    // fraction realised via clonefile(2) (shared extents)
    public var symlinkFraction: Double = 0
    public var hostile: HostileMix = .none  // loops, perm-denied, dataless placeholders
    public var seed: UInt64                  // deterministic PRNG — same seed ⇒ byte-identical tree
    public var mtimeModel: MTimeModel = .spread(days: 0...365, from: .fixedEpoch)  // FixedClock-aligned
}

public struct MaterializedFixture: Sendable {
    public let root: FilePath
    public let contentHash: String          // hash of the FixtureSpec → cache key
    public let manifest: FixtureManifest     // ground truth: expected file count, on-disk bytes,
                                             // dup clusters, clone clusters, protected decoys (§6)
}

public enum FixtureCatalog {
    public static let wLarge  = FixtureSpec(fileCount: 5_000_000, shape: .balanced(fanout: 64),
                                            sizeModel: .sparse(logical: .lognormal(median: 8_192, sigma: 2.5)),
                                            seed: 0xC1EA_1E5)
    public static let wDupes  = FixtureSpec(fileCount: 1_000_000, shape: .balanced(fanout: 32),
                                            sizeModel: .lognormal(median: 64_000, sigma: 1.8),
                                            dupFraction: 0.30, seed: 0xD00D)
    // … one per row of §4.1
}
```

Requirements on the generator:

- **Deterministic:** a `(FixtureSpec)` hashes to a stable `contentHash`; the same spec always yields a
  byte-identical tree (seeded PRNG for names/sizes/mtimes, `FixedClock` epoch for mtimes so warm-cache
  and idempotence benches are stable).
- **Cached materialization:** materialize into `$CLEANER_BENCH_FIXTURES/<contentHash>/`; if present and
  the stored manifest hash matches, reuse (a 5 M-file tree takes minutes to build — build once per
  runner, reuse across the whole matrix). A `--rebuild-fixtures` flag forces regeneration.
- **Fast build:** parallel `TaskGroup` creation, `getattrlistbulk`-free path (uses `openat`+`writeat`),
  sparse/`clonefile` shortcuts so multi-TB logical trees build in minutes and cost a few GB.
- **Ground-truth manifest:** emits the exact expected file count, on-disk bytes, dup/clone cluster
  membership, and injected **protected-path decoys** (§6) so a benchmark can *also* assert correctness
  (a scan that goes fast but wrong fails).
- **Isolation:** always under a temp root (`$TMPDIR` or a dedicated benchmark volume, §9); **never**
  under a real user directory (Constitution Principle 1). The generator refuses to write anywhere the
  deny-list (Article 5) would protect.

### 5.1 Optional dedicated benchmark volume

For `scale-4tb`/`W-huge` the runner may attach a **disk image** (`hdiutil create -fs APFS -size 4t
-type SPARSE`) mounted read-write; this gives a real APFS volume (clones, sparse, allocated-size all
behave natively) without a physical 4 TB disk and with clean teardown (`hdiutil detach`). DiskArbitration
then reports it as `medium: .ssd, isInternal: false` — the concurrency-tuning benches (`cpu-scaling`)
explicitly pin `VolumeMedium` via `FakeProviders` to remove that variance where it isn't the subject.

## 6. Correctness-under-load assertions

Because a fast-but-wrong scan is a failure (Principle 3), every macro benchmark also asserts against
the fixture manifest *after* the measurement window:

- file count enumerated == `manifest.expectedFileCount`
- summed `sizeOnDisk` == `manifest.expectedOnDiskBytes` (± clone/sparse tolerance recorded in manifest)
- dedup benchmark: detected duplicate clusters == `manifest.dupClusters`
- protected decoys (a fake `~/.ssh/id_rsa`, a `*.pem`, a Time-Machine-snapshot-shaped mount, a dataless
  placeholder) are **never** in the actionable set — an assertion failure here fails the benchmark and
  is escalated to the safety gate (spec 31 §safety, spec 34).

## 7. Cold vs. warm cache

Two orthogonal caches matter and both are controlled explicitly:

- **OS/VFS cache** (kernel inode/dnode cache). *Warm* = run once to prime, then measure. *Cold* = purge
  before measuring. On CI we cannot always `purge`(8) (needs privilege); the harness therefore:
  - **Warm** benches: one warmup iteration (default), measure subsequent.
  - **Cold** benches: run `sync && purge` when the runner permits (self-hosted, §9); otherwise
    materialize a **fresh** fixture path per iteration (different inodes ⇒ cold VFS) and label the
    result `cold*` (approximate cold — noted in the report so trends aren't compared across the `*`).
- **Tool incremental scan cache** (spec 17, `~/.cleaner/cache`, FR-007). *Cold* = empty cache dir
  (`CLEANER_HOME` pointed at a fresh temp dir). *Warm* = pre-populated by a prior scan of the same
  fixture. `analyze-latency` reports **both**: cold (<20 s) and warm (<5 s) map directly to NFR-003.

## 8. Targets & regression thresholds (the CI gate)

### 8.1 Absolute targets (from spec 07, on the Reference Machine)

| Benchmark | Metric | Target (RM) | Target (SM) | NFR |
|---|---|---|---|---|
| `scan-throughput/W-large` | files/min | ≥ 250 000 | ≥ 120 000 | NFR-001 |
| `mem-rss/W-large` | peak RSS | < 300 MB | < 300 MB | NFR-002 |
| `mem-rss/dupe/W-dupes` | peak RSS | < 500 MB | < 500 MB | NFR-002 |
| `analyze-latency/W-small/cold` | wall p90 | < 20 s | scaled §1 | NFR-003 |
| `analyze-latency/W-small/warm` | wall p90 | < 5 s | scaled | NFR-003 |
| `dupe-pipeline/W-dupes` | wall p90 | < 8 min | — | NFR-004 |
| `dupe-pipeline/W-dupes` | hash-bytes-ratio | < 5 % | — | NFR-004 |
| `dispose-throughput` | items/min | ≥ 10 000 | ≥ 10 000 | NFR-005 |
| `cpu-scaling/W-large` | speedup 1→8 cores | ≥ 5× | ≥ 4× | NFR-006 |
| `alloc-per-file/W-manysmall` | mallocs/file | ≤ 1.0 | ≤ 1.0 | NFR-007 |
| `measure-overhead/W-fewlarge` | overhead % | < 5 % | < 5 % | NFR-008 |
| `scale-4tb/W-huge` | completes, RSS bounded | no OOM, RSS < 300 MB, linear | — | NFR-010 |
| `tui-frame` | frame ms p95 | ≤ 33 ms | ≤ 33 ms | NFR-020 |
| `startup` | wall p90 | < 150 ms | < 300 ms | NFR-120 |
| `time-to-first-frame/W-small` | wall p90 | < 500 ms | < 500 ms | NFR-121/022 |

Absolute targets are asserted only on **known reference machines** (§9); on unknown/ephemeral GitHub
runners absolute wall-clock numbers are noise, so those runs enforce only **relative** thresholds and
**invariant** metrics (allocations, syscalls, RSS ceiling — hardware-insensitive).

### 8.2 Relative regression thresholds (every PR)

Compared against the committed baseline for the same machine class:

| Metric | Fail if p90 regresses by more than |
|---|---|
| Wall clock | **+8 %** |
| Peak RSS | **+5 %** |
| Allocations (`mallocCountTotal`) | **+3 %** |
| Syscalls (where measured) | **+5 %** |
| Throughput (files/s) | **−8 %** (drop) |

A regression beyond threshold **fails the `benchmark-regression` status check** (spec 34) and blocks
merge. An intentional regression (e.g. a safety fix that costs throughput) is landed by updating the
baseline in the same PR with a `perf-baseline-change:` commit trailer explaining why — reviewed like
any other change. Thresholds are per-metric and configurable in `Benchmarks/thresholds.yml`.

### 8.3 PR gate vs. nightly

- **PR gate (must be fast, spec 34, NFR-103):** `W-tiny`, `W-small`, `alloc-per-file/W-manysmall`,
  `startup`, `tui-frame`, `dispose-throughput` (subset). Budget < 6 min on the runner. Enforces
  **relative** thresholds + invariant metrics only.
- **Nightly (self-hosted reference machines):** the full §4 grid including `W-large`, `W-huge`,
  `scale-4tb`, `dupe-pipeline`, cold-cache scenarios. Enforces **absolute** targets and updates trend
  data (§10).

## 9. Reference machines

| Id | Class | Spec | Role |
|---|---|---|---|
| `rm-mstudio` | RM | Apple M-class, ≥16 GB, internal APFS SSD | absolute-target source of truth (spec 07 §1 RM) |
| `sm-intel` | SM | Intel x86_64, 8 GB, NVMe/SATA SSD | portability floor, x86_64 slice (NFR-091) |
| `gh-macos-arm` | ephemeral | GitHub `macos-14`/`15` arm64 runner | PR gate: relative + invariant metrics only |
| `gh-macos-x64` | ephemeral | GitHub `macos-13` x86_64 runner | PR gate on Intel slice |

`rm-mstudio` and `sm-intel` are **self-hosted, dedicated** runners (no other load during a bench run,
power/thermal settings pinned: `sudo pmset -a` fixed, no Low Power Mode, display sleep only). Each
publishes its own baseline set under `Benchmarks/.baselines/<id>/`. A machine records a
`machine-fingerprint` (model, core count, RAM, macOS build, APFS container) into every result so trends
never silently compare across hardware.

## 10. Reporting & trend tracking

- Each run emits `package-benchmark`'s JSON + a human summary (`swift package benchmark --format
  markdown`) posted as a **PR comment** by the benchmarks workflow (spec 34), showing per-metric delta
  vs. baseline with ✅/⚠️/❌ against the §8 thresholds.
- **Trend store:** nightly results append to a time series (`Benchmarks/history/<machine>/<date>.json`),
  published to a static dashboard (GitHub Pages) plotting throughput, RSS, alloc/file, and startup over
  time per machine. A silent 2 %-per-week drift that never trips the single-PR gate is caught by the
  trend view (owner reviews weekly).
- **Provenance:** every result carries the commit SHA, machine fingerprint, fixture `contentHash`, and
  macOS build, so any number is reproducible.

## 11. Profiling hooks handed to spec 37

Benchmarks emit `os_signpost` intervals (`OSSignposter`, category `com.cleaner.bench`) around the major
phases (`enumerate`, `measure`, `score`, `stage`, `hash`) so a bench run can be re-run under
Instruments (Time Profiler, Allocations, System Trace) to attribute a regression to a phase. The
signpost names are the contract between this spec and spec 37 §measuring. The known bottleneck list and
their mitigations live in spec 37 §known-bottlenecks; each entry names the benchmark here that guards it.

## Open Questions

- **OQ-30.1** Can we get SIP-relaxed self-hosted runners to enable the DTrace `syscalls` metric in CI,
  or do we permanently rely on the unit-level `T-syscall-batching` invariant test for that dimension?
  *Leaning: unit invariant in CI, DTrace on the nightly self-hosted box only.*
- **OQ-30.2** Sparse/clone-backed `W-huge` may under-report real I/O time vs. a true 1.2 TB block-backed
  tree (data never actually read on a metadata-only scan, so maybe fine). Do we need one *block-backed*
  large fixture on a dedicated physical disk for a true cold-cache I/O number? *Leaning: yes, quarterly,
  on `rm-mstudio` with a real external SSD.*
- **OQ-30.3** Final `W-large` throughput baseline (NFR-001) is pending the spec 16 getattrlistbulk
  prototype (OQ-07.2). Re-baseline `scan-throughput` once the enumerator lands; treat 250 K/min as
  provisional until then.
- **OQ-30.4** Should `tui-frame` be measured headless (piping to `/dev/null` with a synthetic terminal
  size) or against a pty? *Leaning: synthetic frame buffer (no real terminal) so CI is deterministic;
  a manual pty check covers real-terminal escape emission.*
- **OQ-30.5** Fixture cache size on ephemeral runners: `W-small` (~a few GB sparse) fits, larger sets do
  not — confirm the GitHub runner disk budget and cap PR-gate fixtures accordingly.

## Dependencies

**Consumes:** 00 (CC-9 testing/bench decision, Art. 7 exit codes for `--ci`), 07 (every NFR target and
`bench` token quantified here), 10 (§9 package-benchmark, native APIs whose cost we measure), 12
(`ScanBench` benchmark target, `CleanerTestKit`/`VirtualFileSystem`), 16 (getattrlistbulk batching,
allocated-size measurement, per-volume concurrency, clones/sparse semantics the fixtures model).

**Feeds:** 31 (shares `FixtureFS`/manifest; correctness-under-load assertions cross into the test
suite), 34 (the `benchmark-regression` status check, PR-gate vs. nightly split, self-hosted runners),
37 (signpost phase contract; each optimization cites a benchmark defined here as its guard).
