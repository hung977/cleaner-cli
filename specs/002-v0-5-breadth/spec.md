# Feature Specification: v0.5 Beta — Breadth & Hardening

**Feature Branch**: `002-v0-5-breadth`
**Created**: 2026-07-06
**Status**: Draft
**Input**: Roadmap (specs/38) v0.5 milestone — expand plugins, add doctor/report, config, weighted safety scorer.

## Scope (from roadmap §, obeys Constitution Art. 2)

v0.5 broadens v0.1's proven safety spine without changing it. Everything routes through the
same ScanEngine → CleanupEngine → StagingManager path; no new deletion mechanics.

**In scope:**
- More Safe (🟢) developer-cache plugins: SwiftPM, CocoaPods, pip + `__pycache__`,
  Gradle/Maven, Homebrew download cache.
- `cleaner doctor` — environment & health check, `--ci` exit-code contract.
- `cleaner report` — export a storage report (`--json`, `--md`).
- Configuration: `~/.cleaner/config.yml` `ignore`/`whitelist` honored by scan + guard.
- Weighted `SafetyScorer` (specs/22 signals) producing the SafetyScore plugins pass today by hand.

**Out of scope (deferred):** Docker/Simulator shell-adapter plugins, browser plugins,
duplicate/large-file detectors, profiles, full-screen TUI, any Pro/licensing.

## User Scenarios

### User Story 1 — Broader safe cleanup (Priority: P1)
As a polyglot developer, I want cleaner to also reclaim SwiftPM/CocoaPods/pip/Gradle/Homebrew
caches so one run frees more space, all still 🟢 and staged.
**Independent Test**: synthesize each cache dir under a fake home; `analyze` lists them 🟢;
`clean --yes` stages them; protected paths still untouched.
**Acceptance**:
1. **Given** a `~/Library/Caches/org.swift.swiftpm` dir, **When** `analyze`, **Then** it appears as 🟢 Developer Cache.
2. **Given** those caches, **When** `clean --yes`, **Then** they are staged and restorable.

### User Story 2 — Health check for CI (Priority: P2)
As a DevOps engineer, I want `cleaner doctor --ci` to report environment health with a stable
exit code (0 healthy / 3 warnings / 1 critical) so I can gate pipelines.
**Independent Test**: run `doctor --ci` in a sandbox; assert JSON shape + exit code.
**Acceptance**:
1. **Given** a supported OS and reachable tool home, **When** `doctor --ci`, **Then** exit 0 with a checks list.

### User Story 3 — Config-driven ignore (Priority: P3)
As a cautious user, I want paths in `config.yml` `ignore:` to be excluded from findings so I can
protect project-specific locations.
**Acceptance**:
1. **Given** `ignore: ["*Keep*"]`, **When** `analyze`, **Then** matching items are absent.

## Functional Requirements
- Reuses FR-021/025/030/033/041 (dev caches), FR-070 (doctor), FR-071 (report), FR-090 (config ignore),
  FR-084 (safety scoring). New plugins follow specs/13 contract; config follows specs/24; scorer specs/22.

## Success Criteria
- SC-1: ≥5 new Safe plugins, each passing the plugin contract test.
- SC-2: `doctor --ci` exit-code contract holds (0/3/1).
- SC-3: `ignore` from config demonstrably removes findings.
- SC-4: SafetyScorer reproduces v0.1 hand-scores within band and is unit-tested.
- SC-5: full safety gate still 100%; integration smoke still green.

## Out of Scope
Docker/Simulator/browser plugins, detectors (dup/large/old), profiles, TUI, Pro/licensing.

## Open Questions
- OQ: Homebrew cache path when `HOMEBREW_CACHE` unset — default `~/Library/Caches/Homebrew`.

## Dependencies
Consumes v0.1 (001-mvp-v0-1) engine/plugins/CLI; specs 13, 22, 24, 38.
