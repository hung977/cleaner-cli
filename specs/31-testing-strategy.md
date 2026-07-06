# 31 — Testing Strategy

> **Phase G · Depends on:** 00-constitution (Art. 4 safety invariants, Art. 5 deny-list, Art. 7 exit
> codes, Art. 9 traceability, CC-9), 07-nonfunctional (every `T-*` verification token), 12-module
> (test targets, `CleanerTestKit`, `VirtualFileSystem`), 13 (plugin contract), 16 (FS semantics under
> test), 30 (shared `FixtureFS`) ·
> **Depended on by:** 34 (CI runs & gates these), 33 (release checklist references coverage gates),
> every engine/plugin spec (their acceptance tests live here).

## 1. Purpose & the highest-priority principle

This spec defines *how we prove the tool is correct and — above all — safe*. Constitution Principle 1
("a byte wrongly deleted is worse than a gigabyte wrongly kept") makes the **Safety Test Suite** (§8)
the single most important asset in the repo. It is the one suite that must be **100 % green** for any
merge or release; a flaky safety test is a P0 bug, never a retry.

Every `T-*` token in spec 07's Verification column and every FR/SR acceptance criterion (spec 06) is
realised as a concrete test here, with a traceability map (§13). "Ambiguity is a defect" (Art. 11);
"an untested requirement is unimplemented."

## 2. The test pyramid

```
        ▲  fewer, slower, higher-fidelity
        │   e2e / integration      CleanerIntegrationTests  — full `clean` on a synthetic volume
        │   snapshot (golden)      TUI frames · JSON · reports
        │   property-based         idempotence · dry-run==real · rollback byte-identity
        │   contract               plugin harness · adapter contract
        │   unit (per module)      Core · Config · Engine · Plugins · TUI · Report · App
        ▼  many, fast, isolated              ── all on the VirtualFileSystem, no real user data ──
   cross-cutting, always-on: ┌ Safety suite (§8) ┐ ┌ Stress/perf (§9) ┐  (gate: safety = 100 %)
```

- **Framework:** **Swift Testing** (`@Test`, `#expect`, `#require`, `@Suite`, parameterized `arguments:`,
  `.tags`, `.timeLimit`) is primary (CC-9). **XCTest** is used only via the bridge where a capability is
  XCTest-only (e.g. `XCTAttachment` for snapshot diffs, `measure`-style microbench glue, or async main-
  actor UI harnesses); those live behind a thin adapter so the suite reads uniformly.
- **Speed budget:** unit + integration (excluding stress/scale) run **< 5 min** on CI (NFR-103).
  Stress/scale (§9) and benches (spec 30) run in separate, longer nightly jobs.
- **Tag taxonomy** (Swift Testing `.tags`) drives selective runs and CI gates:
  `.safety`, `.unit`, `.integration`, `.snapshot`, `.property`, `.contract`, `.stress`, `.perf`,
  `.a11y`, `.security`, `.slow`, `.requiresFDA` (skipped unless Full Disk Access present).

## 3. The Virtual Filesystem fixture layer (critical)

> This is the linchpin that lets us test scan/detection/cleanup **exhaustively without ever touching
> real user data** (Constitution Principle 1). It lives in `CleanerTestKit` (spec 12 §4) and comes in
> two interchangeable flavours behind the same provider protocols the engine already depends on
> (`FileSystemReading`, `MetadataReading`, plus the platform `FilesystemService` façade, spec 16 §1).

### 3.1 Two backends, one protocol

1. **`VirtualFileSystem` (in-memory).** A pure Swift model of a tree: nodes carry the *same* fields as
   `FSNode` (spec 16 §2.3) — type, inode, `sizeLogical`, `sizeOnDisk`, `mtimeNs`, `st_flags` (incl.
   `SF_DATALESS`, `UF_COMPRESSED`), `nlink`, mode, owner, xattrs, symlink target, clone/hardlink cluster
   membership, `VolumeInfo`. It answers enumeration, measurement, evidence, canonicalization, and
   **simulated disposition** entirely in memory. Fast (no syscalls), deterministic, and able to model
   things a real FS makes hard to stage on demand: symlink loops, dataless placeholders, a fake sealed
   *system volume*, a Time-Machine-snapshot mount, cross-volume `Item`s, `ENOTSUP` from
   `getattrlistbulk`, a vanishing file mid-scan, a permission-denied directory.
2. **`TempDirFileSystem` (real, sandboxed).** Materializes a `FixtureSpec` (shared with spec 30's
   `FixtureFS`, §5 there) into a temp dir / disk image and runs the *production* `FilesystemService`
   against it. Proves the real Darwin adapter (getattrlistbulk decoding, allocated-size, xattr, TOCTOU
   `openat`/`fstat` identity checks) behaves as the in-memory model claims.

```swift
public protocol TestFileSystem: FileSystemReading, MetadataReading, Sendable {
    @discardableResult func make(_ spec: FixtureSpec) -> MaterializedFixture
    func inject(_ fault: FSFault, at path: FilePath)   // .vanish, .permissionDenied, .symlinkLoop,
                                                       // .enotsup, .dataless, .lockedOpen, .raceSwap
    var disposed: [DispositionRecord] { get }          // what a clean *would have* moved (dry model)
}
```

**Rule (enforced in review + a lint, §11):** unit tests for `CleanerEngine`, `CleanerApp`, and
`CleanerPlugins` **must** use a `TestFileSystem`; a unit test that reaches a real path outside
`$TMPDIR`/`CLEANER_HOME` fails a guard `#require(!path.escapesSandbox)`. Only `CleanerPlatformTests`
and `CleanerIntegrationTests` touch a real (sandboxed, temp) filesystem, and never a user directory.

### 3.2 Deterministic clock & providers

`FixedClock` (spec 12 §4) supplies mtime/atime/now so recency-based detection and idempotence are
reproducible. `FakeProviders` fake Spotlight (`kMDItemLastUsedDate`, `whereFroms`), Launch Services
(is-app-installed), DiskArbitration (`VolumeMedium`), Authorization (grant/deny), and the process
adapter (fake `simctl`/`docker system df` output) so plugins are tested without those subsystems.

## 4. Unit tests (per module)

One test target per library (spec 12 §2 table). Highlights:

- **`CleanerCoreTests`** (pure, sub-second, no disk): value semantics & `Hashable`/`Codable`
  round-trips of `Item`/`Finding`/`Evidence`; the risk↔score mapping (Art. 4.2: `≥85→safe`,
  `50–84→medium`, `<50→dangerous`) as a parameterized boundary table; `ExitCode` raw values match
  Art. 7; a plugin may lower but not raise a score (invariant).

```swift
@Suite("Safety score → risk mapping", .tags(.unit))
struct ScoreRiskMappingTests {
    @Test(arguments: [(0,.dangerous),(49,.dangerous),(50,.medium),
                      (84,.medium),(85,.safe),(100,.safe)])
    func mapsAtBoundaries(_ score: Int, _ expected: RiskLevel) {
        #expect(RiskLevel(for: SafetyScore(value: score)) == expected)   // Art. 4.2
    }
}
```

- **`CleanerConfigTests`:** YAML parse/merge precedence (defaults < config.yml < profile < env <
  flags), schema validation, and **bad config ⇒ exit 6** (parameterized over a corpus of malformed
  YAMLs). Round-trip: load→serialize→load is stable.
- **`CleanerEngineTests`:** `ScanEngine` over `VirtualFileSystem` (counts, streaming, cancellation
  checkpoints); `SafetyScorer` weightings; `ProtectedPathGuard` (feeds §8); `StagingManager` rename vs
  copy path; `RollbackEngine` restore. Uses `FixedClock`.
- **`CleanerPluginsTests`:** each bundled plugin scanned against a synthesized tree with a fake
  `PluginContext`; asserts declared-roots respected, findings' risk defaults, evidence populated.
- **`CleanerReportTests` / `CleanerTUITests`:** snapshot (§6).
- **`CleanerAppTests`:** run-mode policy, confirmation policy, **dry-run == real numbers** (§7),
  error aggregation → exit 3/7.
- **`CleanerPlatformTests`:** the *only* unit target hitting a real temp FS — adapter contract tests
  (getattrlistbulk decode == FileManager cross-check; allocated-size truthfulness on a clone/sparse
  file; xattr round-trip; `renameatx_np` atomicity; TOCTOU identity re-check).

## 5. Integration tests (full command flows)

`CleanerIntegrationTests` drives the assembled app (composition root wired with real engine + real
platform against a **sandboxed temp volume/disk image**, never `$HOME`). Each flow asserts stdout/
stderr separation (spec 08 contract), the `--json` schema, the audit NDJSON, staging contents, and the
**exit code** (Art. 7):

- `analyze` → findings + report persisted (NFR-111) + exit 0.
- `clean --dry-run` → nothing moved, report matches a later real `clean` (§7).
- `clean --yes` → safe items staged, medium skipped (Art. 4.1), audit complete (NFR-110), exit 0/3.
- `clean` then `rollback` → tree byte-identical to pre-clean (§7).
- protected-path attempt → exit 8, nothing touched (§8).
- plugin failure injected → session survives, exit 3/7, other plugins complete (NFR-035).
- `doctor --ci` → exit 0/3/1 per health (Art. 7 CI mapping, §12).

## 6. Snapshot tests (golden files)

Golden-file comparison for anything rendered. Goldens live in `Tests/…/__snapshots__/` and are updated
only via `SNAPSHOT_UPDATE=1 swift test` with the diff reviewed in the PR.

- **TUI frames:** the double-buffered renderer (spec 25/ADR-0004) is driven with a **synthetic terminal**
  (fixed cols×rows, capability profile) and its emitted escape/cell buffer captured as a golden. Covers:
  progress bar, tree, select prompt, summary; `NO_COLOR`/`--no-color` (NFR-071); CVD-safe theme
  (NFR-072); East-Asian/emoji width alignment (NFR-082, `T-width-tables`); **resize** reflow (NFR-024,
  `T-resize`); plain/non-TTY linear output (NFR-070, `T-plain-output`).
- **JSON output:** `--json` for each command validated against the committed JSON Schema
  (`schemaVersion`) and byte-compared to a golden (stable key order, deterministic — NFR-031).
- **Reports:** text / Markdown / HTML exports (`CleanerReport`) byte-compared to goldens.

```swift
@Test("multiselect frame renders CVD-safe output", .tags(.snapshot, .a11y))
func multiSelectFrame() throws {
    let term = SyntheticTerminal(cols: 100, rows: 30, profile: .noColor)   // NFR-071
    let frame = MultiSelect(findings: Fixtures.mixedRisk).render(into: term)
    assertSnapshot(frame, named: "multiselect-nocolor")   // sources with reclaim sizes, no color
}
```

## 7. Property-based tests (invariants)

Randomized `FixtureSpec`s (seeded, shrinking on failure) assert engine invariants across thousands of
generated trees — the strongest guarantee of the reversibility/determinism principles.

- **Idempotence (NFR-030, FR-112, `T-idempotent-*`):** `clean` then `clean` again on the result → the
  second run's actionable set is empty. `scan` twice on an unchanged VFS → byte-identical findings.
- **Dry-run == real (NFR-030, Principle 3):** for any tree, `clean --dry-run` predicted reclaim bytes,
  item set, and per-item disposition **equal** the real `clean`'s actuals (same measurement code).
- **Rollback byte-identity (Principle 2):** `hash(tree)`; `clean`; `rollback`; `hash(tree)` — equal,
  including xattrs, mode, owner, mtimes, symlink targets (restore fidelity, spec 21).
- **Determinism (NFR-031, `T-determinism`):** shuffling the FS enumeration order (VFS can randomize
  yield order) yields identical sorted output/totals — no dependence on enumeration or hash-map order.
- **Reclaim never overstated (Principle 3):** summed credited reclaim ≤ actual freed on-disk bytes for
  any tree including clones/hardlinks/sparse (spec 16 §3–4); clone/hardlink shared bytes excluded.

```swift
@Test("dry-run equals real for arbitrary trees", .tags(.property),
      arguments: Seeds.property(count: 500))
func dryRunEqualsReal(seed: UInt64) async throws {
    let vfs = VirtualFileSystem(FixtureSpec.random(seed: seed))
    let plan = try await app.clean(vfs, mode: .dryRun)
    let real = try await app.clean(vfs, mode: .execute)
    #expect(plan.reclaimBytes == real.reclaimBytes)          // NFR-030
    #expect(plan.dispositions == real.dispositions)
}
```

## 8. Safety tests — the highest-priority suite (`.tags(.safety)`)

**Gate: 100 % pass, no skips, zero flake tolerated. This suite blocks every merge and every release
(spec 34, spec 33).** It maps to Constitution Articles 4 & 5 and the SR-### safety requirements
(spec 22). It is **exhaustive by construction**, not sampled.

Coverage:

- **Deny-list is inviolable (Art. 5, NFR-051, `T-denylist`):** parameterized over *every* protected
  path class — `/`, `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, system `/Library`, the
  `.app` bundles, `~/Documents|Desktop|Pictures|Movies|Music`, `~/.ssh`, `~/.gnupg`, Keychains,
  `~/.config` credentials, `*.key`/`*.pem`, Time-Machine-snapshot mounts, the tool's own
  `~/.cleaner`. For each: constructing an `Item` that targets it and attempting every disposition
  (`stage`/`trash`/`purge`) must abort with **exit 8** and mutate nothing. Includes attempts *via*
  config, *via* a malicious plugin, *via* a target rule, and *via* a `--flag` — none may override
  (only a signed policy with explicit ack, tested separately, `T-policy-verify`, NFR-055).
- **Never delete outside declared roots ∩ allow-space (Art. 4.4):** an `Item` whose canonical path is
  outside the union of plugin roots is refused.
- **Symlink/TOCTOU (Art. 4.4, NFR-053, `T-toctou`):** a symlink pointing out of an allowed root deletes
  only the link, never the target; a mid-operation swap of the target (fault `.raceSwap`) is caught by
  the `openat`+`fstat` identity re-check and aborts that item, never acts on the wrong inode.
- **Dataless/snapshot/system-volume (spec 16 §4):** dataless placeholders never opened/deleted (0
  reclaim, skip reason `dataless`); nothing under a snapshot mount deleted; writes to the sealed system
  volume refused.
- **Locked/in-use (Art. 4.4):** an open/locked file is skipped unless explicit override.
- **Stage-before-purge (Art. 4.4):** no `purge` code path reachable without prior stage unless
  `--no-stage` **and** confirmation; asserted by exhausting the disposition state machine.
- **Confirmation gates (Art. 4.1):** the default run prompts before cleaning (`Y` = all, `s` = select
  each, `n` = cancel); `--yes` cleans all staged items non-interactively, every clean recoverable via `cleaner undo`.
- **No escalation (NFR-050, `T-no-escalation`):** no setuid, no persistent helper; elevation only per-op
  via Authorization (faked grant/deny).
- **Adapter injection (NFR-052, `T-adapter-injection`):** shell-out adapters use argv exec, absolute
  allow-listed binaries, timeouts, output caps; a path containing `; rm -rf ~` is passed inertly.
- **No network egress in core path (NFR-060, `T-no-egress`):** run under a network-blocking harness
  (a `URLProtocol` interceptor + a `Sendable` "no sockets" guard); any connect attempt fails the test.
- **Crash consistency (NFR-032, `T-crash-consistency`):** fault-inject `SIGKILL`/abort mid-disposal via
  the journaling seam; recovery leaves each item fully staged or untouched — never half-moved.
- **Terminal restore (NFR-043, `T-terminal-restore`):** any exit path (normal/cancel/crash) restores
  cooked mode and leaves no orphan FDs/temp files.

The safety suite runs on **both** the `VirtualFileSystem` (exhaustive, fast) **and** `TempDirFileSystem`
(real Darwin adapter, the deny-list/TOCTOU checks against actual `openat`/`renameatx_np`), so a model/
reality divergence is caught.

## 9. Performance / stress tests (`.tags(.stress)`)

Correctness-under-adversity (distinct from spec 30's *timing* benchmarks — these assert *it doesn't
break*, not *how fast*):

- **Millions of files (NFR-010, `scale-4tb` fixture):** `W-huge` (10 M) completes, bounded RSS, no OOM.
- **Pathological trees (NFR-011, `T-scale-pathological`):** depth ≥ 64, a dir with ≥ 1 M direct
  children, `PATH_MAX` paths — iterative traversal, no stack overflow.
- **Symlink loops:** a cycle is detected (visited-inode set) and does not hang or infinite-loop.
- **Permission-denied dirs:** enumeration skips + reports, never aborts the session (NFR-035, exit 3).
- **Vanishing files mid-scan (`.vanish` fault):** a file removed between enumerate and measure is
  handled (skip + note), not a crash.
- **Cancellation latency (NFR-040, `T-cancel-latency`):** cancel takes effect < 200 ms at the next
  directory boundary; FS consistent; exit 5.
- **Resume (NFR-041, `T-resume`):** interrupted scan resumes from checkpoint, re-scanning < 10 %.
- **Multi-volume (NFR-012, `T-multi-volume`):** concurrent volumes with per-volume caps.
- **Large result streaming (NFR-013, `T-large-result-stream`):** ≥ 1 M findings paged, never fully
  materialized.

## 10. Plugin contract tests — the reusable harness (`.tags(.contract)`)

> Every plugin — bundled *and* third-party (spec 13) — MUST pass one shared harness. This is how
> "extensibility without core edits" (Principle 7, NFR-100) stays safe.

`CleanerTestKit` ships `PluginContractTests<P: CleanerPlugin>` — a generic conformance suite a plugin
author instantiates with their plugin type and a set of fixture trees. It asserts the contract from
spec 13:

- **Manifest validity:** `id`, `apiVersion` (semver-compatible with the SDK), `category`,
  `declaredRoots`, `defaultRisk`, `capabilities` all present and well-formed.
- **Read-only scan (Principle 3 / glossary "Scan"):** running `scan` against the VFS mutates nothing
  (the VFS asserts zero disposition/writes occurred).
- **Roots respected:** every finding's path is within the plugin's `declaredRoots` ∩ allow-space; a
  plugin proposing a path outside its roots is a contract violation (exit 7 in situ).
- **Determinism/idempotence:** two scans of the same tree → identical findings (NFR-030/031).
- **Risk discipline (Art. 4.2):** a plugin may lower a score with evidence but never raise it above the
  scorer ceiling; defaults obey its manifest `defaultRisk`.
- **Cancellation:** respects `Task.checkCancellation()` at boundaries.
- **Isolation (NFR-035):** a thrown error/`fatalError`-free failure is surfaced, doesn't corrupt shared
  state, maps to exit 7.
- **Additivity (NFR-100, `T-plugin-additive`):** a reference "hello" plugin is added in a test and the
  engine/CLI compile and run **unchanged** — proving zero core edits.

```swift
@Suite("Xcode plugin conforms to contract", .tags(.contract))
struct XcodePluginContract {
    let harness = PluginContractTests(XcodeDerivedDataPlugin.self,
                                      fixtures: [.xcodeDerivedData, .empty, .hostile])
    @Test func passesFullContract() async throws { try await harness.runAll() }
}
```

Third-party authors get the harness from the `CleanerPluginAPI` product (spec 12 §7) and their CI runs
it; the tool refuses to load a plugin at runtime whose manifest/apiVersion fails the same checks
(spec 13).

## 11. CI gates & coverage targets

Enforced by the workflows in spec 34:

| Gate | Requirement |
|---|---|
| **Safety suite** | **100 %** pass, no skips, no retries. Blocks merge & release. |
| Unit + integration + property + snapshot + contract | 100 % pass. |
| **Coverage — safety-critical paths** | Staging, deny-list/`ProtectedPathGuard`, invariants: **≥ 95 % line + branch** (NFR-034). Enforced per-file, not just aggregate. |
| **Coverage — overall** | ≥ 85 % line (target; warn below, fail below a hard floor of 80 %). |
| Strict-concurrency build | Swift 6 strict concurrency clean; **zero** `@unchecked Sendable` without a `// SAFETY:` note (NFR-033). |
| Sandbox lint | No unit test reaches outside `$TMPDIR`/`CLEANER_HOME` (§3.1 guard). |
| i18n lint | Zero hard-coded user-facing literals in view code (NFR-080, `T-i18n-externalized`). |
| Suite wall time | Unit+integration < 5 min (NFR-103); stress/perf in nightly. |
| Module acyclicity | No import cycles (NFR-101) — checked from the `Package.swift` DAG (spec 12 §3). |

Coverage measured via `swift test --enable-code-coverage` + `llvm-cov`; the safety-critical file set is
an explicit allow-list in `Tests/coverage-critical.txt` so its threshold can't be diluted by adding
easy-to-cover files elsewhere.

## 12. CI-mode / `doctor --ci` self-test contract

`cleaner doctor --ci` runs a fast self-check (permissions probe, config validity, staging writable,
plugin manifests load, deny-list intact) and maps health to exit codes per Constitution Art. 7:
**0 healthy · 3 warnings · 1 critical**. Spec 34's PR job runs it as a smoke gate; a test
(`T-doctor-ci-exit`) asserts each health state produces the mapped code. The full `--ci` exit-code
contract for all commands is enumerated in spec 34 §CI-mode.

## 13. Traceability (FR / SR / NFR → test)

Every requirement maps to ≥ 1 test (Art. 9). The authoritative matrix is generated from test `.tags`
and a `// @traces: NFR-032, FR-093` annotation on each test, then diffed in CI against spec 06/07 so a
**new requirement without a test fails the build** and a **test citing a non-existent ID fails**.
Representative rows:

| Requirement | Test(s) | Suite |
|---|---|---|
| Art. 5 deny-list / NFR-051 | `T-denylist` (parameterized, all classes) | Safety §8 |
| Art. 4.4 TOCTOU / NFR-053 | `T-toctou` | Safety §8 (VFS + TempDir) |
| NFR-030 idempotence / FR-112 | `T-idempotent-*`, `dryRunEqualsReal` | Property §7 |
| NFR-032 crash consistency | `T-crash-consistency` | Safety §8 |
| NFR-001 throughput | `scan-throughput` | Bench (spec 30) + `T-scale-*` §9 |
| NFR-035 plugin isolation | `T-plugin-isolation`, contract §10 | Integration/Contract |
| NFR-100 additivity | `T-plugin-additive` | Contract §10 |
| NFR-070/071/072 a11y | `T-plain-output`,`T-no-color`,`T-theme-cvd` | Snapshot §6 |
| NFR-110/111 observability | `T-audit-completeness`,`T-report-persist` | Integration §5 |
| Art. 7 exit codes / `--ci` | `T-doctor-ci-exit`, per-flow exit asserts | Integration §5/§12 |

(The complete matrix is the CI-generated `traceability.md` artifact, spec 34.)

## 14. Test data & fixture management

- **Source of truth:** `FixtureSpec` (declarative, seeded) from spec 30 §5 — shared, so a tree a bench
  stresses is the same a test asserts on. No opaque binary fixtures checked into git except **goldens**
  (§6) and small malformed-YAML corpora.
- **Goldens** live beside their tests in `__snapshots__/`, updated only via `SNAPSHOT_UPDATE=1` with the
  diff human-reviewed. A stale/uncommitted golden fails CI.
- **Big trees** are generated on demand into `$TMPDIR`/disk image and torn down in the suite's
  `deinit`/`.serialized` teardown; never committed, never under a user dir.
- **`CLEANER_HOME`** is redirected to a per-test temp dir so staging/config/logs/cache never touch the
  developer's real `~/.cleaner`.
- **Secrets/PII:** fixtures use synthetic paths only; the deny-list decoys (`id_rsa`, `*.pem`) are empty
  dummies. No real credentials, ever.

## Open Questions

- **OQ-31.1** Do we invest in a shrinking property-test library (SwiftCheck-style) or hand-roll seeded
  shrinking in `CleanerTestKit`? *Leaning: hand-roll minimal shrinking to avoid a heavy test dep
  (dependency policy, spec 10 §11).*
- **OQ-31.2** Snapshot terminal fidelity: is a synthetic cell-buffer capture enough, or do we need a pty
  round-trip test to catch real escape-sequence bugs (cursor save/restore, altscreen)? *Leaning:
  synthetic for the gate + a small nightly pty smoke set.*
- **OQ-31.3** Can the full safety suite (VFS × all deny classes × all dispositions × injection vectors)
  stay under the 5-min budget, or does it need its own parallel job? *Leaning: its own fast parallel
  job so it never competes with the unit budget and can be the first to report.*
- **OQ-31.4** `TempDirFileSystem` needs a real APFS volume for clone/allocated-size fidelity; is a
  disk image (spec 30 §5.1) reliable enough on ephemeral runners, or gate those to self-hosted?
  *Leaning: disk image on ephemeral for basic, self-hosted for clone-exactness.*
- **OQ-31.5** How do we test VoiceOver compatibility (NFR-073) automatically vs. a manual checklist?
  *Leaning: manual a11y checklist per release (spec 25) + automated plain-output linearity in snapshot.*

## Dependencies

**Consumes:** 00 (Art. 4/5 invariants the safety suite enforces, Art. 7 exit codes, Art. 9
traceability, CC-9 Swift Testing), 07 (every `T-*` verification token), 12 (test targets,
`CleanerTestKit`, `VirtualFileSystem`, module DAG for acyclicity), 13 (the plugin contract these tests
enforce), 16 (FS semantics the VFS models and the adapter tests verify), 30 (`FixtureSpec`/`FixtureFS`
and the manifest ground truth reused here).

**Feeds:** 33 (release checklist consumes the safety + coverage gates), 34 (CI wires and enforces every
gate here, generates the traceability artifact), and provides the acceptance-test home that every
engine/plugin/UX spec's requirements point to (Art. 9 traceability rule).
