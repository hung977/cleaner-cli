# Implementation Plan: MVP v0.1 — Prove the Safety Spine

**Branch**: `001-mvp-v0-1` | **Date**: 2026-07-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-mvp-v0-1/spec.md`

## Summary

Deliver the safety spine of cleaner-cli: `analyze` (read-only scan + honest storage report),
`clean` (preview → confirm → stage), and `staging list|restore` (rollback), backed by three
provably-🟢 plugins (Trash, Xcode DerivedData, npm cache), allocated-size truth, an NDJSON audit
trail, JSON output, and the exit-code contract — with a basic **linear** TUI (progress lines +
summary table), not the full-screen TUI.

Technical approach: a streaming scan pipeline (`BulkEnumerator`/`FileManager.enumerator` →
per-plugin `Finding` streams → `SafetyFunnel` → `ScanAccumulator` actor) produces a `ScanResult`.
Selection + confirmation builds a `CleanPlan`; the `CleanupEngine` pre-flights each action
(TOCTOU identity re-check + `ProtectedPathGuard`), stages via atomic same-volume `rename` or
cross-volume copy-then-verify-then-remove, and measures realized reclaim against `statfs`,
producing a `CleanReport`. Staging writes an append-only NDJSON manifest per session under
`~/.cleaner/staging/<session-uuid>/`; `RollbackEngine` reduces the manifest and restores items
byte-for-byte. Every mutation appends an audit NDJSON event.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), `swift-tools-version: 6.0`.

**Primary Dependencies**: swift-argument-parser (CLI, CC-2), Swift Concurrency
(actors/`TaskGroup`/`AsyncThrowingStream`, CC-3), swift-log + custom NDJSON audit sink (CC-6),
swift-system (`System.FilePath`), swift-collections (`Deque`/`OrderedDictionary`), Yams (minimal
config, CC-5). Native frameworks (Foundation, DiskArbitration, CoreServices) are isolated behind
`CleanerPlatform` provider protocols.

**Storage**: `~/.cleaner/` (overridable via `CLEANER_HOME`, Constitution Article 8):
`staging/<session-uuid>/` (quarantine + `manifest.ndjson`), `logs/cleaner.log`,
`logs/audit/<date>.ndjson`, `reports/`. No database; append-only NDJSON + on-disk payload
mirroring the original path.

**Testing**: Swift Testing (`@Test`/`#expect`/`#require`/`@Suite`, parameterized, `.tags`), with
`CleanerTestKit` providing `VirtualFileSystem` (in-memory) + `TempDirFileSystem` (real sandbox) +
`FixedClock` + `FakeProviders`. Safety suite is a 100% merge-blocking gate.

**Target Platform**: macOS 13 (Ventura) and newer; universal (arm64 + x86_64). Unsupported OS
exits `10`.

**Project Type**: CLI / desktop tool (single SPM package, multi-target library graph + one
executable). No server, no web, no mobile.

**Performance Goals** (subset of spec 07 relevant to v0.1): scan ≥ 250K files/min on reference
Apple-silicon hardware (NFR-001); `analyze` on a small dev tree < 20 s cold / < 5 s warm
(NFR-003); disposal ≥ 10K items/min, intra-volume `rename`-based O(1) (NFR-005); reclaim
measurement < 5% overhead vs enumeration (NFR-008); cold startup < 150 ms (NFR-120).

**Constraints**: RSS < 300 MB for scan, independent of tree size — streaming, not
materialization (NFR-002/010); no network I/O in the core cleaning path (NFR-060, Principle 10);
Swift 6 strict concurrency, zero `@unchecked Sendable` without a `// SAFETY:` note (NFR-033);
cancellation at directory boundary < 200 ms → exit `5` (NFR-040); crash-consistent staging —
SIGKILL leaves items fully staged or untouched (NFR-032).

**Scale/Scope**: Correct up to 4 TB / ≥ 10M files without OOM (NFR-010); v0.1 fixtures are small
synthesized trees but the pipeline is built streaming so scale is not retrofitted.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

Verified against the six principles (`.specify/memory/constitution.md`; full text
`specs/00-constitution.md`):

| Principle | v0.1 compliance | Evidence in this plan |
|---|---|---|
| **I. Safety over savings (NON-NEGOTIABLE)** | PASS | `clean` is strictly preview → confirm → execute; no code path disposes without interactive confirm or `--yes`; 🔴 never auto-cleaned; 🟡 (Trash) shown but not pre-selected; ProtectedPathGuard + hard invariants enforced centrally (FR-110), abort → exit `8`. |
| **II. Reversibility by default (NON-NEGOTIABLE)** | PASS | Default disposition `stage`; `unlink` is never a default. `purge` only via explicit escalation. US3 restore proves byte-exact rollback (SC-001). Losing a license cannot endanger data — license is a stub, gates nothing. |
| **III. Native-first & truthful reporting** | PASS | Native Foundation/DiskArbitration/CoreServices behind `CleanerPlatform`; **no shell-outs** in v0.1 (adapters deferred to v0.5). Reclaim = allocated on-disk size; dry-run and real-run share one measurement path (FR-082/111, SC-002). |
| **IV. Extensibility without core edits** | PASS | Plugins implement `CleanerPlugin` and link **only** `CleanerPluginAPI` + `CleanerCore` — the compiler forbids `CleanerPlugins → CleanerEngine`. Plugins *propose*; the engine *disposes* and owns all safety invariants. |
| **V. Least privilege, privacy, observability** | PASS | Runs as invoking user; no elevation needed for the three home-rooted plugins (FDA merely detected). No network in the cleaning path. Every mutation is audited to NDJSON (FR-099); structured logs to `~/.cleaner/logs`. |
| **VI. Safety is never behind a paywall** | PASS | `CleanerLicenseStub` always returns Community; **every** safety feature (preview, confirm, staging, rollback, protected-path enforcement, audit) is present and ungated. No Pro/licensing code. |

**Fixed cross-cutting decisions honored**: CC-1 (Swift 6/SPM), CC-2 (ArgumentParser), CC-3 (Swift
Concurrency), CC-6 (swift-log + audit sink), CC-7 (stage-then-purge), CC-8 (in-process static
plugins), CC-9 (Swift Testing), CC-10 (`URLResourceValues` allocated size). CC-4 (full TUI) is
intentionally *not* exercised — linear output only, which is a permitted subset. No new exit
codes, risk levels, or type names are invented.

**Result: PASS — no violations, Complexity Tracking not required.**

## Project Structure

### Documentation (this feature)

```text
specs/001-mvp-v0-1/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

Single SPM package `cleaner-cli`. v0.1 builds the subset of the spec-12 target graph needed for
the safety spine (no `CleanerTUI`, no `CleanerApp` split — thin orchestration lives in the
executable; the linear presenter lives in `CleanerReport`).

```text
Package.swift                              # swift-tools-version:6.0, platforms [.macOS(.v13)]

Sources/
├── CleanerCore/                           # L3 domain — pure value types, no I/O
│   ├── Ids.swift                          # FindingID, ItemID, PluginID, SessionID, CategoryID
│   ├── RiskLevel.swift                    # 🟢🟡🔴 + icon + Comparable
│   ├── SafetyScore.swift                  # 0…100 + riskLevel mapping
│   ├── Recoverability.swift Disposition.swift Category.swift
│   ├── Evidence.swift                     # v0.1 subset of fields
│   ├── Item.swift Finding.swift Reclaim.swift
│   ├── ScanResult.swift CleanPlan.swift CleanReport.swift Session.swift
│   ├── CleanerError.swift ExitCode.swift  # ExitCode: Int32 (0..8,10)
│   └── PluginDescriptor.swift SemanticVersion.swift
├── CleanerPlatform/                       # L5 — native adapters behind Sendable protocols
│   ├── FilesystemService.swift            # enumerate/measure/evidence/volume/canonicalize/dispose
│   ├── BulkEnumerator.swift               # getattrlistbulk hot path (+ FileManager fallback)
│   ├── AllocatedSize.swift                # URLResourceValues.totalFileAllocatedSize
│   ├── VolumeProvider.swift               # DiskArbitration → VolumeInfo/VolumeID
│   ├── MetadataProvider.swift             # xattr/Spotlight (minimal)
│   ├── TrashProvider.swift                # FileManager.trashItem / NSWorkspace.recycle
│   └── Clock.swift ProcessInfoProvider.swift
├── CleanerPluginAPI/                      # L4 SDK — the stable third-party contract
│   ├── CleanerPlugin.swift                # protocol: scan/clean lifecycle
│   ├── PluginContext.swift PluginManifest.swift RootSpec.swift
│   ├── Capabilities.swift                 # CapabilitySet
│   └── Providers.swift                    # FileSystemReading, MetadataReading, ... (read-only)
├── CleanerEngine/                         # L3 — algorithms; hands out behaviors, hides internals
│   ├── ScanEngine.swift ScanAccumulator.swift SafetyFunnel.swift
│   ├── SafetyScorer.swift                 # coarse v0.1 scorer (signals + gates)
│   ├── ProtectedPathGuard.swift           # allow ∩ roots − deny; symlink-escape refusal
│   ├── DenyList.swift                     # Article 5 protected paths
│   ├── CleanupEngine.swift PreflightGate.swift
│   ├── StagingManager.swift               # actor; atomic move + manifest journal
│   ├── RollbackEngine.swift ReclaimTally.swift
│   └── PluginRegistry.swift               # BuiltinPlugins.all (static)
├── CleanerPlugins/                        # L4 — bundled plugins (SDK only, NOT the engine)
│   ├── Trash/TrashPlugin.swift            # dev.cleaner.trash (FR-037, 🟡, purge)
│   ├── Xcode/DerivedDataPlugin.swift      # dev.cleaner.xcode (FR-021, 🟢)
│   └── Npm/NpmCachePlugin.swift           # dev.cleaner.npm  (FR-025 cache slice, 🟢)
├── CleanerConfig/                         # L2/L3 — minimal: CLEANER_HOME + defaults
│   └── EffectiveConfig.swift ConfigLoader.swift
├── CleanerReport/                         # L2 — assemble + render (human table, JSON, linear UI)
│   ├── ReportBuilder.swift
│   ├── JSONReport.swift                   # schemaVersion "1.0.0", envelope + per-command result
│   ├── HumanSummary.swift                 # summary table
│   └── LinearPresenter.swift              # progress lines + prompts to stderr
├── CleanerLogging/                        # cross-cut — swift-log bootstrap + NDJSON audit sink
│   ├── LoggingBootstrap.swift
│   └── AuditSink.swift                    # append-only ~/.cleaner/logs/audit/<date>.ndjson
├── CleanerLicenseStub/                    # always Community; gates nothing (Principle 11)
│   └── License.swift
└── cleaner/                               # L1 executable — composition root + command tree
    ├── Cleaner.swift                      # @main root command + global flags
    ├── AnalyzeCommand.swift CleanCommand.swift
    ├── StagingCommand.swift               # list | restore (+ purge plumbing)
    ├── GlobalOptions.swift Selectors.swift
    └── RunCoordinator.swift               # thin orchestration (scan→plan→confirm→execute→report)

Tests/
├── CleanerCoreTests/                      # value semantics, Codable, risk↔score mapping, ExitCode
├── CleanerPlatformTests/                  # real temp-FS adapter contract (getattrlistbulk, alloc size, TOCTOU)
├── CleanerConfigTests/                    # CLEANER_HOME resolution, defaults
├── CleanerPluginAPITests/                 # manifest validation, capability negotiation
├── CleanerEngineTests/                    # scan/scorer/guard/staging/rollback (VFS + FixedClock)
│   └── Safety/                            # .tags(.safety) — deny-list × disposition matrix (100% gate)
├── CleanerPluginsTests/                   # each plugin vs synthesized tree
├── CleanerReportTests/                    # JSON schema + human snapshot goldens
├── CleanerIntegrationTests/               # full analyze/clean/rollback flows + exit-code + audit
└── CleanerTestKit/                        # target: VirtualFileSystem, TempDirFileSystem, FixedClock, FakeProviders
```

**Structure Decision**: Single SPM package, spec-12 layered target graph reduced to the v0.1
subset. The load-bearing missing edge `CleanerPlugins ─X→ CleanerEngine` is enforced by
`Package.swift` (plugins can only `import CleanerPluginAPI`/`CleanerCore`). `CleanerCore` is the
DAG sink (stdlib + `System` only). Orchestration and the linear presenter are folded into the
`cleaner` executable and `CleanerReport` respectively for v0.1 (no separate `CleanerApp`/
`CleanerTUI` targets yet — added in v0.5/v1.0 when the full TUI arrives).

## Approach (pipeline)

1. **Scan** (US1): `RunCoordinator` resolves selected plugins from the static `PluginRegistry`,
   intersects each plugin's `declaredRoots` with the allow-space minus the deny-list, and runs
   `ScanEngine`. Enumeration streams `FSNode`s; each plugin emits `AsyncThrowingStream<Finding>`;
   the `SafetyFunnel` clamps scores, applies `ProtectedPathGuard`, and normalizes (split
   cross-volume groups). The `ScanAccumulator` actor folds into a `ScanResult`.
2. **Report** (US1): `ReportBuilder` renders `ScanResult` to a human summary table (stdout) or a
   `schemaVersion 1.0.0` JSON document; progress lines go to stderr via `LinearPresenter`.
3. **Plan + confirm** (US2): selection (`--include`/`--exclude`/`--plugins`, risk defaults)
   builds a `CleanPlan` (actions ordered children-before-parents, safe-before-risky). The
   `LinearPresenter` shows the preview; confirmation obtained interactively, via `--yes` (🟢, 🟡
   only with `--include medium`), or refused (exit `2`) with no TTY.
4. **Stage** (US2): `CleanupEngine` pre-flights each action (`PreflightGate` TOCTOU identity
   re-check + `ProtectedPathGuard`), then `StagingManager` moves it — same-volume atomic
   `renameat`, cross-volume copy → checksum-verify → remove-source — appending a
   `StagingManifestEntry` and an audit event per item. `ReclaimTally` measures realized reclaim
   against `statfs`; `ReportBuilder` emits the `CleanReport`.
5. **Rollback** (US3): `RollbackEngine.listSessions()` backs `staging list`;
   `RollbackEngine.restore()` reduces the manifest, verifies each staged payload's checksum,
   moves it back (collision policy: fail/rename/overwrite), re-applies metadata in the correct
   order, and appends `restored` events to the manifest + audit trail.

## Phase 0 — Research topics (→ research.md)

1. Enumeration API for v0.1: `FileManager.enumerator` vs `getattrlistbulk`.
2. Allocated-size measurement API (`URLResourceValues.totalFileAllocatedSize`) and clone/sparse
   accounting.
3. Atomic staging move: same-volume `rename` vs cross-volume copy-then-verify-then-remove.
4. Audit + staging manifest NDJSON format.
5. Plugin registration: static compile-time registry for v1.
6. `swift-argument-parser` command tree for the v0.1 command subset.
7. Coarse safety scorer sufficient for three 🟢 plugins.

## Phase 1 — Design outputs

- **data-model.md** — the concrete Swift value types for v0.1 (subset of spec 14) with fields,
  types, and invariants.
- **quickstart.md** — build/run/test walkthrough with expected output snippets.
- **contracts/** — the JSON `schemaVersion 1.0.0` envelope + `analyze`/`clean`/`staging` result
  shapes are captured inline in data-model.md / spec 08 §9 (no separate OpenAPI-style contracts
  for a CLI); JSON goldens live under `Tests/CleanerReportTests`.
- Re-run the Constitution Check above after design — expected to remain PASS.

## Complexity Tracking

No Constitution violations — this section is intentionally empty.
