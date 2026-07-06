---
description: "Task list for cleaner-cli MVP v0.1 — the safety spine"
---

# Tasks: MVP v0.1 — Prove the Safety Spine

**Input**: Design documents from `/specs/001-mvp-v0-1/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Tests are REQUIRED for this feature — the Constitution makes the safety test suite a
100% merge gate, and no deletion-path code lands without a safety test. Test tasks are therefore
first-class, not optional.

**Organization**: Grouped by phase, then by user story (US1 analyze, US2 clean-with-staging, US3
rollback), so each story is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on another unfinished task)
- **[Story]**: US1 / US2 / US3 (or blank for setup/foundational/polish)
- 🔒 marks **safety-critical gate** tasks (must be green before merge; Constitution + SC-006)
- All paths are under the repo root; Sources/Tests layout per plan.md

## Path Conventions

Single SPM package. Library code in `Sources/<Module>/`, tests in `Tests/<Module>Tests/`, shared
fixtures in `Sources/CleanerTestKit/` (test-support target).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: SPM skeleton, module dirs, tooling, CI.

- [ ] T001 Create `Package.swift` (swift-tools-version:6.0, `platforms: [.macOS(.v13)]`,
  strict-concurrency), declaring the v0.1 targets from plan.md (`CleanerCore`, `CleanerPlatform`,
  `CleanerPluginAPI`, `CleanerEngine`, `CleanerPlugins`, `CleanerConfig`, `CleanerReport`,
  `CleanerLogging`, `CleanerLicenseStub`, `cleaner` exe, `CleanerTestKit`) and pinned deps
  (swift-argument-parser, swift-log, swift-system, swift-collections, Yams). Encode the
  DAG so `CleanerPlugins` depends ONLY on `CleanerPluginAPI` + `CleanerCore` (no engine edge).
- [ ] T002 [P] Create the `Sources/<Module>/` directory tree and one placeholder file per target
  so the package compiles empty; add `.gitignore` entries for `.build/` (repo already ignores).
- [ ] T003 [P] Add `.swift-format` config + a `Makefile`/`scripts/format.sh` running
  `swift format` and `swift build` at repo root.
- [ ] T004 [P] Add CI stub `.github/workflows/ci.yml` (spec 34 subset): `swift build`,
  `swift test`, `swift format lint`, and a `swift test --filter Safety` gate step on macOS 13
  runners (arm64 + x86_64).
- [ ] T005 [P] Scaffold `Sources/CleanerTestKit/` target skeleton (empty `VirtualFileSystem`,
  `TempDirFileSystem`, `FixedClock`, `FakeProviders` types) so test targets can link it.

**Checkpoint**: `swift build` and `swift test` succeed on an empty package.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Domain types, platform filesystem service, safety guard, staging + audit, plugin
API, minimal config, report/JSON, logging. **No user story can begin until this is complete.**

### Domain (CleanerCore) — pure value types, no I/O

- [ ] T006 [P] Implement identifiers + `ExitCode`/`CleanerError` in `Sources/CleanerCore/Ids.swift`
  and `Sources/CleanerCore/ExitCode.swift` (per data-model.md §1, §14).
- [ ] T007 [P] Implement safety enums (`RiskLevel`, `SafetyScore`, `Recoverability`,
  `Disposition`) in `Sources/CleanerCore/{RiskLevel,SafetyScore,Recoverability,Disposition}.swift`
  with the risk mapping and `Comparable`/icon (data-model.md §2).
- [ ] T008 [P] Implement `Evidence` (v0.1 subset) + `Category` in
  `Sources/CleanerCore/{Evidence,Category}.swift` (data-model.md §3–4).
- [ ] T009 [P] Implement `Item`/`ItemKind`, `Finding`, reclaim types (`ReclaimEstimate`,
  `ReclaimActual`, `ReclaimConfidence`) in `Sources/CleanerCore/{Item,Finding,Reclaim}.swift`
  (data-model.md §5–7). Encode DM-1 (`.none ⇒ .dangerous`) at construction.
- [ ] T010 [P] Implement `ScanResult`/`ScanTotals`/`SkippedPath`/`SkipReason`/`PluginRunSummary`,
  `CleanPlan`/`PlannedAction`/`ConfirmationState`, `CleanReport`/`ActionOutcome`/`ActionResult`/
  `StagedRef`, and `Session` in `Sources/CleanerCore/` (data-model.md §8–12).
- [ ] T011 [P] Unit tests in `Tests/CleanerCoreTests/`: value semantics, `Codable` round-trips,
  `SafetyScore.riskLevel` mapping (≥85/50–84/<50), `ExitCode` raw values, DM-1 invariant.

### Platform (CleanerPlatform) — native adapters behind Sendable protocols

- [ ] T012 Define the `FilesystemService` protocol + `FSNode`/`SizePair`/`EnumerationOptions`/
  `VolumeID`/`VolumeInfo`/`DispositionResult` types in
  `Sources/CleanerPlatform/FilesystemService.swift` (research.md R1–R3, spec 16 names).
- [ ] T013 [P] Implement `FileManager.enumerator`-based enumeration returning
  `AsyncThrowingStream<FSNode, Error>` in `Sources/CleanerPlatform/BulkEnumerator.swift`
  (R1 — getattrlistbulk left as a documented perf follow-up behind the same protocol).
- [ ] T014 [P] Implement allocated-size measurement via
  `URLResourceValues.totalFileAllocatedSize`/`fileAllocatedSize` → `SizePair` in
  `Sources/CleanerPlatform/AllocatedSize.swift` (R2, CC-10), incl. sparse/clone/hardlink flags.
- [ ] T015 [P] Implement `VolumeProvider` (DiskArbitration → `VolumeID`/`VolumeInfo`) in
  `Sources/CleanerPlatform/VolumeProvider.swift`; detect same-volume vs cross-volume.
- [ ] T016 [P] Implement path canonicalization (expand `~`, resolve `.`/`..`, `realpath`,
  NFC) and fd-relative TOCTOU-safe open/mutate helpers (`openat`+`O_NOFOLLOW`, `unlinkat`,
  `renameat`) in `Sources/CleanerPlatform/{PathCanon,FdOps}.swift` (R3, spec 16 path safety).
- [ ] T017 [P] Implement `Clock`/`ProcessInfoProvider`/`TrashProvider`
  (`FileManager.trashItem`) minimal adapters in `Sources/CleanerPlatform/`.
- [ ] T018 [P] `Tests/CleanerPlatformTests/` (real temp-FS only): enumeration correctness,
  allocated-size vs logical on a sparse + a cloned file, TOCTOU identity re-check, cross-volume
  detection via a temp disk image. Sandbox-guarded to `$TMPDIR`.

### Plugin API (CleanerPluginAPI) — the stable SDK boundary

- [ ] T019 [P] Define `CleanerPlugin` protocol (`scan(_:) -> AsyncThrowingStream<Finding,Error>`,
  `clean(_:_:) async throws -> [CleanDirective]`, lifecycle), `PluginContext`,
  `PluginManifest`/`PluginDescriptor`, `RootSpec`/`RootBase`, `PluginCapabilities`,
  `SemanticVersion`, and read-only provider protocols (`FileSystemReading`, `MetadataReading`) in
  `Sources/CleanerPluginAPI/` (data-model.md §13, spec 13).
- [ ] T020 [P] `Tests/CleanerPluginAPITests/`: manifest validation (declaredRoots ⊆ allow-space),
  capability negotiation, provider protocols expose **no** mutation.

### Engine foundations (CleanerEngine) — safety, staging, audit

- [ ] T021 🔒 Implement the Article 5 deny-list in `Sources/CleanerEngine/DenyList.swift`
  (protected roots + user content roots + credentials + snapshots + tool's own `~/.cleaner`).
- [ ] T022 🔒 Implement `ProtectedPathGuard` in `Sources/CleanerEngine/ProtectedPathGuard.swift`:
  the `allowed(path)` algorithm (canonicalize → deny-list → allow-space → plugin roots →
  mount-root/system-volume → symlink-escape), boundary-anchored prefix matching; violation →
  `ExitCode.safety` (spec 22 §7). **Depends on** T016, T021.
- [ ] T023 [P] Implement the coarse `SafetyScorer` (six weighted signals + monotonic-downward
  gates + risk mapping; plugins may lower not raise — DM-2) in
  `Sources/CleanerEngine/SafetyScorer.swift` (research.md R7, spec 22 §4).
- [ ] T024 Implement `StagingManager` actor in `Sources/CleanerEngine/StagingManager.swift`:
  same-volume atomic `renameat`; cross-volume copy → checksum-verify → `unlinkat` source;
  capture metadata before move; append `StagingManifestEntry` to `manifest.ndjson` under
  `~/.cleaner/staging/<session-uuid>/`, `fsync` + `flock`. **Depends on** T016, T012.
- [ ] T025 Implement `StagingManifestEntry`/`StagingSessionSummary`/`RestoreTarget`/
  `RestoreOptions`/`CollisionPolicy`/`RestoreReport`/`RestoreWarning`/`WarningKind` in
  `Sources/CleanerEngine/StagingModel.swift` (data-model.md §11).
- [ ] T026 [P] Implement `CleanerLogging`: swift-log bootstrap + append-only NDJSON `AuditSink`
  (`~/.cleaner/logs/audit/<date>.ndjson`, `fsync`-per-record) in `Sources/CleanerLogging/`
  (FR-099, R4).
- [ ] T027 [P] Implement minimal `CleanerConfig`: `EffectiveConfig` + `ConfigLoader` resolving
  `CLEANER_HOME` and built-in defaults (staging retention 14d, no YAML surface yet) in
  `Sources/CleanerConfig/`.
- [ ] T028 [P] Implement `CleanerLicenseStub` always returning Community (gates nothing) in
  `Sources/CleanerLicenseStub/License.swift` (Principle 11).
- [ ] T029 [P] Implement `CleanerReport`: `JSONReport` (envelope `schemaVersion "1.0.0"` +
  `exitCode`/`exitReason`), `HumanSummary` (summary table), and `LinearPresenter` (progress lines
  + confirm prompts to **stderr**) in `Sources/CleanerReport/` (spec 08 §3, §9).
- [ ] T030 [P] Flesh out `CleanerTestKit`: in-memory `VirtualFileSystem` (FSNode fields, clone/
  hardlink clusters, fault injection `.vanish/.permissionDenied/.symlinkLoop/.dataless/
  .lockedOpen/.raceSwap`), `TempDirFileSystem`, `FixedClock`, `FakeProviders`
  (spec 31 §3). **Depends on** T012, T019.

**Checkpoint**: Domain compiles and is tested; the guard, staging, audit, scorer, report, and
test fixtures exist. User-story work can begin.

---

## Phase 3: User Story 1 - Analyze (Priority: P1) 🎯 MVP

**Goal**: Read-only scan → honest storage report (human + JSON), exit 0/3/4.

**Independent Test**: `cleaner analyze <fixture> --json` validates against schema `1.0.0`,
reports correct per-category `allocatedBytes`, exits `0`, mutates nothing.

### Tests for US1 (write first, ensure they FAIL)

- [ ] T031 [P] [US1] Plugin scan tests in `Tests/CleanerPluginsTests/` for `DerivedDataPlugin`
  and `NpmCachePlugin` against synthesized trees (correct findings, allocated size, 🟢 risk).
- [ ] T032 [P] [US1] `TrashPlugin` scan/report test (enumerate `~/.Trash`, size, 🟡 baseline).
- [ ] T033 [P] [US1] Scan-engine test in `Tests/CleanerEngineTests/` (VFS + FixedClock):
  streaming findings, `ScanAccumulator` totals, `SkippedPath(permissionDenied)` → exit 3,
  empty-result → exit 0, deterministic order (NFR-031).
- [ ] T034 [P] [US1] Report tests in `Tests/CleanerReportTests/`: JSON `analyze` result golden +
  human summary snapshot; assert stdout is a single JSON doc (chrome-free).

### Implementation for US1

- [ ] T035 [P] [US1] Implement `DerivedDataPlugin` (`dev.cleaner.xcode`, FR-021) in
  `Sources/CleanerPlugins/Xcode/DerivedDataPlugin.swift`.
- [ ] T036 [P] [US1] Implement `NpmCachePlugin` (`dev.cleaner.npm`, FR-025 cache slice) in
  `Sources/CleanerPlugins/Npm/NpmCachePlugin.swift`.
- [ ] T037 [P] [US1] Implement `TrashPlugin` (`dev.cleaner.trash`, FR-037, 🟡, disposition
  `purge`) in `Sources/CleanerPlugins/Trash/TrashPlugin.swift`.
- [ ] T038 [US1] Implement the static `PluginRegistry` (`BuiltinPlugins.all`) in
  `Sources/CleanerEngine/PluginRegistry.swift` (research.md R5). Depends on T035–T037.
- [ ] T039 [US1] Implement `ScanEngine` + `ScanAccumulator` actor + `SafetyFunnel` (scorer clamp,
  ProtectedPathGuard, volume-split normalization) in
  `Sources/CleanerEngine/{ScanEngine,ScanAccumulator,SafetyFunnel}.swift` → `ScanResult`
  (FR-001, FR-070, FR-111). Depends on T022, T023, T013–T015.
- [ ] T040 [US1] Implement the `analyze` command + `GlobalOptions`/`Selectors`
  (`--include`/`--exclude`/`--plugins`, `--json`, `--no-color`, `-v`) and the root `Cleaner`
  ArgumentParser tree in `Sources/cleaner/{Cleaner,AnalyzeCommand,GlobalOptions,Selectors}.swift`
  (research.md R6, spec 08 §4.1). Wire scan → `ReportBuilder`.
- [ ] T041 [US1] Wire storage report (capacity/used/free/purgeable/reclaimable) from
  `VolumeProvider` into the analyze output (FR-002).

**Checkpoint**: `swift run cleaner analyze [--json]` works end-to-end and is independently
testable. **This is the shippable MVP slice.**

---

## Phase 4: User Story 2 - Clean with staging (Priority: P2)

**Goal**: preview → confirm → stage, with dry-run, `--yes` risk rules, idempotence, audit.

**Independent Test**: `cleaner clean --plugins dev.cleaner.xcode,dev.cleaner.npm --yes` stages
items under `~/.cleaner/staging/<uuid>/`, `totalReclaimBytes` == measured freed bytes, audit
event per item, exit 0; re-run finds nothing new (exit 0).

### Tests for US2 (write first, ensure they FAIL)

- [ ] T042 [P] [US2] Cleanup-engine tests in `Tests/CleanerEngineTests/`: dry-run == real
  measurement (SC-002/FR-082), same-volume `rename` staging, cross-volume copy-verify-remove,
  idempotence (FR-112), `--yes` risk rules (🟢 auto, 🟡 skipped w/o `--include medium`, 🔴 never).
- [ ] T043 [P] [US2] 🔒 Safety tests in `Tests/CleanerEngineTests/Safety/` `.tags(.safety)`:
  the **deny-list × disposition matrix** (every protected path class × {stage,trash,purge} →
  abort exit 8, mutate nothing), symlink-escape → exit 8, TOCTOU `.raceSwap` skip → exit 3,
  dataless → 0 reclaim / never materialized, no-purge-without-stage.
- [ ] T044 [P] [US2] Audit-completeness test: every mutation appends a matching NDJSON event
  (FR-099); crash-consistency (`SIGKILL` sim) leaves items fully staged or untouched (NFR-032).

### Implementation for US2

- [ ] T045 [US2] Implement `PreflightGate` (TOCTOU identity re-check: dev/inode/nlink/type/mtime,
  `!isOpenOrLocked`, `!isDataless`, `snapshotRef == nil`, writable) in
  `Sources/CleanerEngine/PreflightGate.swift`. Depends on T016, T022.
- [ ] T046 [US2] Implement `CleanupEngine` + `ReclaimTally` actor in
  `Sources/CleanerEngine/{CleanupEngine,ReclaimTally}.swift`: order actions (children→parents,
  safe→risky), pre-flight, dispatch to `StagingManager`, measure realized reclaim vs `statfs`,
  enforce DM-5 (typed/automation confirm for purge/dangerous), produce `CleanReport`
  (FR-075, FR-111, FR-112). Depends on T024, T045, T023.
- [ ] T047 [US2] Implement plan building + confirmation policy (🟢 preselected, 🟡 shown not
  preselected, 🔴 typed-confirm scaffold; `--yes` rules; no-TTY without `--yes` → exit 2) in
  `Sources/cleaner/RunCoordinator.swift` + `LinearPresenter` preview/prompt (FR-083, spec 08).
- [ ] T048 [US2] Implement the `clean` command (`--dry-run`, `--yes`, `--stage` default,
  disposition flags, `--include/--exclude/--plugins`) in `Sources/cleaner/CleanCommand.swift`,
  wiring scan → plan → confirm → execute → report (human + `--json` result shape spec 08 §9.3).
- [ ] T049 [US2] Wire `AuditSink` calls into every `StagingManager`/`CleanupEngine` mutation
  (stage/purge/skip/blocked) so FR-099 holds for the clean path.

**Checkpoint**: US1 and US2 both work independently; `clean` stages reversibly with an audit
trail and honest reclaim.

---

## Phase 5: User Story 3 - Rollback (Priority: P3)

**Goal**: `staging list` and `staging restore` return staged items byte-for-byte.

**Independent Test**: stage a fixture (US2), checksum original; `cleaner staging restore <uuid>`;
assert byte-identical content + metadata, a `restored` audit event, exit 0.

### Tests for US3 (write first, ensure they FAIL)

- [ ] T050 [P] [US3] 🔒 Round-trip restore test in `Tests/CleanerEngineTests/` (`.tags(.safety)`):
  hash(tree) → clean → restore → hash(tree) identical (content, mode, owner, xattrs, mtimes,
  symlink targets), across same-volume AND cross-volume staging (SC-001).
- [ ] T051 [P] [US3] Restore edge tests: occupied destination → skip / exit 3 (or `--force`
  overwrite), checksum-mismatch → refuse, unknown id → exit 2, protected-target breach → exit 8.

### Implementation for US3

- [ ] T052 [US3] Implement `RollbackEngine` (`listSessions`, `restore`, `purge`, `gc`) in
  `Sources/CleanerEngine/RollbackEngine.swift`: reduce `manifest.ndjson`, verify checksum before
  move-back, collision policy (fail/rename/overwrite), re-apply metadata in order
  (owner→mode→ACL→xattrs→flags→timestamps), append `restored` events + audit (FR-088). Depends
  on T024, T025.
- [ ] T053 [US3] Implement the `staging` command tree (`list`, `restore <id> [--force]`, plus
  `purge` for retention/Trash-disposition plumbing) in `Sources/cleaner/StagingCommand.swift`,
  human + `--json` output (spec 08 §7).
- [ ] T054 [US3] Implement retention `gc` (default 14d, never within 24h of creation) invoked at
  CLI start; wire `staging purge` audit events.

**Checkpoint**: The full preview → confirm → stage → rollback loop is demonstrable end-to-end.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Prove the exit-code contract, the safety gate, integration, and observability.

- [ ] T055 🔒 [P] Exit-code contract integration tests in `Tests/CleanerIntegrationTests/`:
  analyze → 0/3/4; clean --yes → 0/3; protected-path → 8; plugin failure → 3/7 (FR-113); no-TTY
  clean → 2; unsupported-OS gate → 10 (spec 31 §5, Article 7).
- [ ] T056 🔒 [P] Red-team fixture suite (`.tags(.safety)`): symlink loops, escaping symlinks,
  vanishing files mid-scan, permission-denied dirs, pathological depth — all handled without
  escaping roots or losing data (SC-003).
- [ ] T057 [P] Full-flow integration test: `analyze → clean → staging list → staging restore` on
  a synthesized volume, asserting JSON schema `1.0.0` at each step and audit NDJSON completeness.
- [ ] T058 [P] JSON schema snapshot/golden tests for `analyze`/`clean`/`staging` envelopes in
  `Tests/CleanerReportTests/` (spec 08 §9); assert forward-compat fields and `schemaVersion`.
- [ ] T059 [P] Idempotence + determinism tests (`T-idempotent-*`, `T-determinism`): re-run
  analyze/clean unchanged → byte-identical results, no new findings (FR-112, NFR-030/031).
- [ ] T060 [P] Verbose/debug behavior: `-v/--verbose` increases human detail; `--debug` traces to
  stderr only, never polluting `--json` stdout (FR-086, NFR-112) — test in
  `Tests/CleanerIntegrationTests/`.
- [ ] T061 [P] Cancellation: Ctrl-C at a directory boundary → exit 5, FS consistent, terminal
  restored (NFR-040/043).
- [ ] T062 [P] `version` output + unsupported-OS precondition gate (< macOS 13 → exit 10) in
  `Sources/cleaner/`.
- [ ] T063 Run `quickstart.md` end-to-end against a sandbox `CLEANER_HOME` and reconcile any
  output drift; confirm all exit-code, JSON, and round-trip claims hold.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies — start immediately.
- **Foundational (Phase 2)**: depends on Setup — **BLOCKS all user stories**. Within it: domain
  (T006–T011) and platform/API (T012–T020) can proceed in parallel; the guard (T022) needs the
  deny-list (T021) + path ops (T016); staging (T024) needs platform FS (T012, T016); the report,
  logging, config, license, and test-kit tasks are largely independent.
- **US1 (Phase 3)**: depends on Foundational. The MVP slice.
- **US2 (Phase 4)**: depends on Foundational; reuses US1's scan output but is independently
  testable (can stage directly from a synthesized plan).
- **US3 (Phase 5)**: depends on Foundational (staging) + at least one staged session from US2 (or
  a fixture-seeded staging session in tests).
- **Polish (Phase 6)**: depends on the user stories it exercises.

### Safety-gate ordering (🔒)

T021, T022 (guard) precede any disposition code. The 🔒 test tasks (T043, T044, T050, T055,
T056) collectively form the **100% merge gate** (SC-006) — no clean/rollback implementation is
"done" until its safety tests are green. Deletion-path code (T024, T046, T052) MUST NOT merge
without its paired safety test.

### Within each user story

Tests (T031–T034, T042–T044, T050–T051) are written first and must fail before implementation.
Models before services; services before commands; core before integration.

### Parallel opportunities

- All of Phase 1 (T002–T005) after T001.
- Domain tasks T006–T010 in parallel; platform T013–T017 in parallel; API T019.
- Foundational cross-cutting: T026 (logging), T027 (config), T028 (license), T029 (report), T030
  (test-kit) in parallel.
- The three plugins T035/T036/T037 in parallel; their tests T031/T032 in parallel.
- Phase 6 polish tasks T055–T062 are largely parallel.

---

## Parallel Example: User Story 1

```bash
# Tests first (must fail):
Task: "DerivedData/Npm plugin scan tests in Tests/CleanerPluginsTests/"        # T031
Task: "TrashPlugin scan/report test in Tests/CleanerPluginsTests/"             # T032
Task: "ScanEngine + accumulator test in Tests/CleanerEngineTests/"            # T033
Task: "analyze JSON + human snapshot in Tests/CleanerReportTests/"           # T034

# Then implement the three plugins together:
Task: "DerivedDataPlugin in Sources/CleanerPlugins/Xcode/DerivedDataPlugin.swift"  # T035
Task: "NpmCachePlugin in Sources/CleanerPlugins/Npm/NpmCachePlugin.swift"          # T036
Task: "TrashPlugin in Sources/CleanerPlugins/Trash/TrashPlugin.swift"              # T037
```

---

## Implementation Strategy

### MVP first (US1 only)

1. Phase 1 Setup → 2. Phase 2 Foundational (CRITICAL, blocks all) → 3. Phase 3 US1 →
4. **STOP and VALIDATE**: `cleaner analyze` delivers an honest read-only report independently.

### Incremental delivery

- Foundation ready → add US1 (analyze) → demo (read-only value, zero risk).
- Add US2 (clean+stage) → demo reversible cleaning with audit + honest reclaim.
- Add US3 (rollback) → demo the full round-trip; the safety spine is proven (roadmap §3 exit
  criteria: round-trip proof, truth check, invariant check, idempotence, contract).

---

## Notes

- **[P]** = different files, no dependency on an unfinished task.
- **🔒** = safety-critical; part of the 100% merge gate. Deletion-path code needs a paired safety
  test before merge (Constitution governance).
- No new exit codes, risk levels, or type names — reuse Article 7 / spec 14 exactly.
- Reclaim uses allocated size everywhere; dry-run and real-run share one measurement path.
- Commit after each task or logical group; stop at any checkpoint to validate a story
  independently.
- **Task count: 63** (T001–T063). Phase breakdown: Setup 5 (T001–T005), Foundational 25
  (T006–T030), US1 11 (T031–T041), US2 8 (T042–T049), US3 5 (T050–T054), Polish 9 (T055–T063).
