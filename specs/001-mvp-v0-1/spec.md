# Feature Specification: MVP v0.1 — Prove the Safety Spine

**Feature Branch**: `001-mvp-v0-1`

**Created**: 2026-07-06

**Status**: Draft

**Input**: User description: "First feature (v0.1 MVP) of cleaner-cli — analyze + clean-with-staging + rollback, three provably-safe plugins, honest allocated-size measurement, JSON + exit-code contract, basic linear TUI. Scope fixed by specs/38-future-roadmap.md §3."

## Overview

cleaner-cli is a plugin-based macOS command-line disk cleaner. This first feature proves the
product's central, differentiating promise end-to-end: **the tool reclaims space and can always
give it back.** A user (or an automated test) can analyze a disk, clean three low-risk
categories, see an *honest* reclaim number, and roll every byte back. This is the "safety spine"
milestone (roadmap §3): if we cannot do this flawlessly, no amount of breadth matters.

Scope is deliberately minimal and provably safe: three 🟢-baseline plugins (Trash, Xcode
DerivedData, npm cache), the full `preview → confirm → stage → rollback` loop, allocated-size
truth, an NDJSON audit trail, JSON output, and the exit-code contract — with a *basic linear*
TUI only (no full-screen TUI; that is v1.0).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Analyze disk usage read-only (Priority: P1)

As a developer worried about a full SSD, I run `cleaner analyze` to see, without touching
anything, how much space each supported junk category is occupying and how much is truthfully
reclaimable — as a human summary or as machine-readable JSON I can pipe into `jq`.

**Why this priority**: This is the safe, read-only entry point and the foundation every other
story builds on (it produces the `ScanResult`/`Finding`s that `clean` consumes). It is the
minimum shippable, independently valuable slice: a user gets an honest storage picture with zero
risk of data loss. It also exercises the whole scan pipeline and the allocated-size measurement
that cannot be retrofitted honestly later.

**Independent Test**: Point the tool at a synthesized fixture tree containing DerivedData, an
`~/.npm/_cacache`, and a Trash directory; run `cleaner analyze <root> --json`; assert the JSON
validates against schema `1.0.0`, reports the correct per-category `allocatedBytes`, exits `0`,
and mutates nothing (fixture checksum unchanged before/after).

**Acceptance Scenarios**:

1. **Given** a home tree with reclaimable junk in the three supported categories, **When** I run
   `cleaner analyze ~`, **Then** stdout shows a summary table of capacity/used/free/reclaimable
   plus a per-category and per-plugin breakdown, and the process exits `0`.
2. **Given** the same tree, **When** I run `cleaner analyze ~ --json`, **Then** stdout carries
   **exactly one** JSON document with `schemaVersion: "1.0.0"`, `command: "analyze"`, an
   `exitCode`/`exitReason` of `0`/`ok`, and no log/progress chrome (progress went to stderr), so
   `cleaner analyze ~ --json | jq .` is byte-clean.
3. **Given** a directory the user cannot read (permission denied), **When** analyze encounters
   it, **Then** the path is recorded in `skipped` with reason `permissionDenied`, the rest of
   the scan completes, and the exit code is `3` (partial) — never a crash.
4. **Given** a category with no junk present, **When** I analyze, **Then** that category reports
   0 findings / 0 bytes (never omitted-as-error), and analyze still exits `0`.
5. **Given** `--include plugin:derived-data`, **When** I analyze, **Then** only DerivedData
   findings are produced and other plugins are not run.

---

### User Story 2 - Clean with preview, confirm, and staging (Priority: P2)

As a developer who has decided to reclaim space, I run `cleaner clean` to preview exactly what
will be removed (paths, sizes, risk, disposition, projected reclaim), confirm, and have the
items moved to a tool-managed **staging** area — never permanently deleted by default — so I can
change my mind afterward.

**Why this priority**: This is the primary destructive verb and the reason the tool exists, but
it depends on US1's scan output. It proves preview-first / confirm-second / execute-third
(Constitution Principle 1) and reversibility-by-default (Principle 2). Staging (not `unlink`) is
what makes US3 possible.

**Independent Test**: On the synthesized fixture, run `cleaner clean --plugins derived-data,npm
--yes`; assert the DerivedData and npm-cache items are moved under
`~/.cleaner/staging/<session-uuid>/`, the reported `totalReclaimBytes` equals the summed
allocated size actually freed (verified against `statfs`), an audit NDJSON event was appended per
item, and exit is `0`. Re-run the same command and assert it finds nothing new (idempotent,
exit `0`).

**Acceptance Scenarios**:

1. **Given** reclaimable 🟢 items, **When** I run `cleaner clean` interactively, **Then** I see a
   preview listing each item's path, allocated size, risk icon, recoverability, and disposition
   `stage`, with a projected total; nothing is disposed until I confirm.
2. **Given** the preview, **When** I run `cleaner clean --dry-run --json`, **Then** the tool
   prints the full plan and projected reclaim using the **same measurement code** as a real run,
   disposes of nothing, and exits `0`.
3. **Given** `--yes`, **When** I run `cleaner clean --include risk:safe --yes`, **Then** all 🟢
   items are staged automatically, 🟡 items (the Trash plugin) are **not** auto-cleaned unless
   `--include medium` is added, and 🔴 items are never auto-cleaned.
4. **Given** the Trash plugin (🟡, disposition `purge` — items are already in the user's Trash),
   **When** I select it, **Then** it is shown but not pre-selected and requires explicit
   confirmation before emptying; under `--yes` it is skipped unless `--include medium`.
5. **Given** a plugin whose declared root resolves onto a protected path or tries to escape via
   a symlink, **When** clean runs, **Then** the engine's ProtectedPathGuard aborts that action
   with exit `8` (safety) and mutates nothing.
6. **Given** a completed clean, **When** I run the identical command again, **Then** the second
   run finds nothing new to do and exits `0` (idempotence).
7. **Given** no TTY and no `--yes`, **When** I run `cleaner clean`, **Then** it refuses (cannot
   prompt) and exits `2` (usage).
8. **Given** a cross-volume staging move, **When** an item is staged, **Then** the tool copies
   then **verifies** (checksum) before removing the source, so a crash before removal leaves the
   source intact.

---

### User Story 3 - Roll every byte back (Priority: P3)

As a user who cleaned and then realized I need something back, I run `cleaner staging list` to
see what is quarantined and `cleaner staging restore <session>` to put items back byte-for-byte
at their original locations, with the restore recorded in the audit trail.

**Why this priority**: Rollback is the payoff that makes staging trustworthy and closes the
safety loop, but it can only be demonstrated once US2 has staged something. It is the concrete
proof of Principle 2 (reversibility by default).

**Independent Test**: Stage a fixture via US2, checksum the original tree beforehand; run
`cleaner staging restore <session-uuid>`; assert every item is back at its original path with
identical content checksum, mode, owner, xattrs, and mtimes; assert a `restored` event was
appended to the manifest and the audit log; exit `0`.

**Acceptance Scenarios**:

1. **Given** a prior clean produced a staging session, **When** I run `cleaner staging list`,
   **Then** I see the session UUID, date, item count, total staged bytes, and original paths;
   `--json` emits the same as a versioned document.
2. **Given** a staged session, **When** I run `cleaner staging restore <session-uuid>`, **Then**
   each staged item is moved back to its original location, verified against its stored checksum
   first, and the restore is recorded in the audit trail; exit `0`.
3. **Given** a destination that is now occupied, **When** I restore without `--force`, **Then**
   that item is skipped (collision) and the run exits `3` (partial); with `--force` the item is
   restored over the occupant.
4. **Given** a restored tree, **When** I checksum it, **Then** it is byte-for-byte identical to
   the pre-clean tree (content + preserved metadata), across same-volume and cross-volume
   staging.
5. **Given** an unknown session/item id, **When** I restore, **Then** the tool exits `2`
   (usage) with a clear message and mutates nothing.

---

### Edge Cases

- **Permission denied** on a directory during scan → recorded as `SkippedPath(reason:
  .permissionDenied)`, scan continues, exit `3`; on clean it is skipped per-item (exit `3`),
  never a hard failure.
- **Path vanished** between scan and clean (TOCTOU) → the pre-flight identity re-check
  (`dev`/`inode`/`nlink`/`type`/`mtime`) detects the drift and skips the item (exit `3`); the
  action is never applied to a re-resolved path.
- **Empty results** (nothing reclaimable) → analyze and clean both exit `0` with zero findings;
  clean prints "nothing to do".
- **Clone-shared / hardlinked blocks** → reclaim credits only *unshared* blocks;
  `ReclaimEstimate.sharedBytesExcluded` records the excluded bytes so totals never overstate
  savings; deleting a clone that still shares extents frees little/nothing and is reported so.
- **Sparse files** → contribute only their allocated blocks to reclaim.
- **Dataless / iCloud placeholders** → contribute `0` reclaim and are never actioned in a way
  that would trigger a download (`SkipReason.dataless`).
- **Local Time Machine snapshots** → reported for context, contribute `0`, never deleted.
- **Symlink escaping an allowed root** → the guard refuses (exit `8`); the link is removed, never
  its target.
- **Cross-volume staging interrupted** → copy-then-verify-then-remove ordering guarantees the
  source survives a crash before removal.
- **No TTY** for a command that needs confirmation → exit `2` (cannot prompt) unless `--yes`.
- **SIGKILL mid-clean** → staging's append-only manifest journal leaves each item either fully
  staged or untouched — never half-moved.

## Requirements *(mandatory)*

### Functional Requirements

Requirements reuse the stable FR-### IDs from `specs/06-functional-requirements.md`; only the
subset in v0.1 scope (roadmap §3) is in force for this feature.

**Analyze / reporting (US1)**

- **FR-001**: The tool MUST perform disk-usage analysis of one or more roots, producing per-node
  logical size **and** allocated on-disk size (APFS clone/sparse aware, CC-10).
- **FR-002**: The tool MUST produce a storage report (capacity/used/free/purgeable/reclaimable),
  broken down by category and by plugin.
- **FR-070**: `analyze` MUST run a read-only scan and present the report + Findings without
  proposing deletion, exiting `0`.
- **FR-084**: `--json` MUST emit a single versioned (`schemaVersion`) document to stdout with all
  human chrome suppressed; logs/progress go to stderr.
- **FR-111**: Reclaim reporting MUST use allocated on-disk size and MUST subtract shared storage
  for clones/hardlinks so totals never overstate savings.

**Clean / staging (US2)**

- **FR-075**: `clean` MUST execute the preview → confirm → dispose pipeline for selected plugins
  (default disposition `stage`) and is the primary destructive verb.
- **FR-082**: `--dry-run` MUST compute and display the full plan and projected reclaim using the
  *same* measurement code as a real run and dispose of nothing, exiting `0`.
- **FR-083**: `--yes` MUST auto-confirm 🟢 (and 🟡 only with `--include medium`) and MUST NEVER
  auto-clean 🔴; absent a TTY, `clean` without `--yes` (or a signed policy) MUST refuse and exit
  `2`.
- **FR-087**: The default disposition MUST be move-to-staging
  (`~/.cleaner/staging/<session-uuid>`), preserving original path + metadata; cross-volume moves
  MUST copy-then-remove and MUST verify before removing the source.
- **FR-094**: `--include`/`--exclude` MUST filter by plugin id, category, risk level, or path
  glob, with documented precedence (spec 08).
- **FR-112**: Running a destructive command twice MUST be safe and idempotent (the second run
  finds nothing new).

**Rollback (US3)**

- **FR-088**: The tool MUST restore staged Items to their original locations (`staging restore`),
  refusing an occupied destination unless `--force`, and MUST record restores in the audit trail.
- **FR-089**: Permanent deletion MUST be an explicit escalation (`staging purge` or `--no-stage`
  with confirmation) and is the only irreversible operation. *(v0.1 exposes `staging list` and
  `staging restore`; `staging purge` exists for retention and for the Trash plugin's `purge`
  disposition but is not a headline user story.)*

**Plugins (cross-story)**

- **FR-021**: DerivedData plugin — `~/Library/Developer/Xcode/DerivedData/<proj-hash>`, fully
  regenerable (🟢). Provided by `DerivedDataPlugin` (`dev.cleaner.xcode`).
- **FR-025** (cache slice only): npm cache plugin — `~/.npm/_cacache` (🟢). Provided by the npm
  slice of `NodePlugin` (`dev.cleaner.npm`). `node_modules` is 🟡 and **deferred to v0.5**.
- **FR-037**: Trash plugin — enumerate `~/.Trash` and per-volume `.Trashes`, report size;
  emptying is 🟡 (user-visible) with disposition `purge` (already the user's Trash — no
  re-staging). Provided by `TrashPlugin` (`dev.cleaner.trash`).
- **FR-041**: Each plugin MUST expose the same lifecycle via the `CleanerPlugin` protocol
  (scan/clean), registered in the v1 static registry.

**Cross-cutting safety / observability (all stories)**

- **FR-086**: `-v/--verbose` MUST increase human detail; `--debug` MUST emit diagnostics to
  stderr without polluting `--json` stdout.
- **FR-099**: Every filesystem mutation MUST append a structured NDJSON audit event
  (`~/.cleaner/logs/audit/<date>.ndjson`) recording path, size, disposition, session, evidence.
- **FR-110**: The engine MUST enforce the Article 4.4 hard invariants centrally (never trust
  plugins): refuse action outside allowed roots, on the deny-list, across escaping symlinks, on
  mount roots / `/` / system volumes, and purge-without-stage without confirmation. Violation
  aborts with exit `8`.
- **FR-113**: Plugin failures MUST be isolated: one failing plugin MUST NOT abort the session; it
  is reported and the run exits `3` or `7` as appropriate.

### Key Entities *(see `data-model.md` and `specs/14-domain-model.md` for full field lists)*

- **Item** — the atomic unit acted on (file/directory/group); carries `primaryPath`, `paths`,
  `size` (logical) and `allocatedSize` (on-disk), `volumeID`.
- **Finding** — an `Item` + a plugin's assessment: `RiskLevel`, `SafetyScore`, `Recoverability`,
  `rationale`, `Evidence`, `ReclaimEstimate`, `suggestedDisposition`, `isProtected`.
- **RiskLevel** — 🟢 `safe` / 🟡 `medium` / 🔴 `dangerous`.
- **SafetyScore** — 0–100 confidence; maps to risk (≥85 safe, 50–84 medium, <50 dangerous).
- **Recoverability** — `instant` / `manual` / `hard` / `none` (`none` forces `dangerous`).
- **Disposition** — `stage` (default) / `trash` / `purge` / `skip`.
- **Evidence** — metadata bag (v0.1 subset: `mtime`, `size`, `allocatedSize`, `isSymlink`,
  `isClone`, `isSparse`, `isDataless`, `isHardlink`).
- **ScanResult / CleanPlan / CleanReport** — the read-only scan output, the confirmed ordered
  action set, and the measured record of what actually happened.
- **StagingManifestEntry / StagedRef** — the per-item quarantine record enabling byte-exact
  rollback.
- **Session** — one invocation, with UUID, logs, and a report.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001** (Round-trip proof): For each of the 3 plugins, an automated test cleans a
  synthesized tree and `staging restore` returns it **byte-for-byte identical** (content
  checksum + preserved metadata), across same-volume **and** cross-volume staging.
- **SC-002** (Truth check): Dry-run projected reclaim equals real-run measured reclaim on the
  fixture set — within **0 bytes** for non-clone data, and correctly discounted for APFS clones.
- **SC-003** (Invariant check): A red-team fixture that makes a plugin try to escape its roots /
  hit the deny-list / follow an escaping symlink is aborted with exit **`8`** and mutates
  nothing.
- **SC-004** (Idempotence): `clean` run twice finds nothing new the second time and exits `0`.
- **SC-005** (Contract): `cleaner analyze --json | jq` is byte-clean (no chrome on stdout); every
  command's `--json` validates against schema `1.0.0`; exit codes match Constitution Article 7
  (0/2/3/4/5/6/7/8).
- **SC-006** (Safety gate): The safety test suite — every protected-path class × every
  disposition (`stage`/`trash`/`purge`) — passes at **100%** with zero flake (merge-blocking).
- **SC-007** (Honest measurement): Reclaim uses `URLResourceValues` allocated size and never
  reports more than the on-disk blocks actually freed (verified against `statfs` before/after).
- **SC-008** (Audit completeness): Every filesystem mutation (stage, purge, restore) produces a
  matching NDJSON audit event; no mutation is unlogged.

## Out of Scope *(everything beyond v0.1 — see roadmap §5–§10)*

Deferred to v0.5+ and explicitly **not** part of this feature:

- All commands except `analyze`, `clean`, `staging list`, `staging restore` (and the supporting
  `staging purge`/retention plumbing). No `audit`, `optimize`, `doctor`, `report`, `plugins`,
  `config` CLI, `profile`, `completion`, `self-update` surfaces in v0.1.
- Any plugin beyond the three named (Trash, DerivedData, npm cache). No `node_modules`, browser,
  Docker, Simulators, Logs, Duplicates, Large/Old, Homebrew, Python, Ruby, JVM, etc.
- Shell-out adapters (`xcrun simctl`, `docker`, `brew`) — native-only in v0.1 (threat surface).
- 🟡/🔴 cleaning categories beyond keeping Trash as a confirm-required 🟡 report/empty.
- The **full-screen** alternate-screen TUI (widgets, double-buffered renderer, `SIGWINCH`
  resize, navigation tree). v0.1 ships **basic linear** output only (progress lines to stderr +
  a summary table).
- The full weighted safety scorer with evidence-driven per-signal scoring at production breadth
  — v0.1 uses a **coarse** scorer sufficient for the three 🟢 plugins (risk mapping and gates
  still enforced).
- Duplicate/large/old-file detection, incremental scan cache, resume checkpoints,
  cancellation-resume, config files/profiles, whitelist/target user rules, Full Disk Access
  elevation flows, Markdown/HTML report export, notarized Homebrew distribution, telemetry, any
  Pro/licensing feature (the license layer is a stub that always reports Community).
- Network I/O of any kind in the cleaning path (Principle 10).

## Assumptions

- Single macOS machine, single user session, macOS 13 (Ventura) or newer; unsupported OS exits
  `10`.
- The three v0.1 plugins operate within the user's home; Full Disk Access is *detected* but not
  required for the DerivedData/npm/Trash paths (they live under `$HOME`). Where a root is
  unreadable, the tool degrades to exit `3`, never crashes.
- `~/.cleaner/` (overridable via `CLEANER_HOME`) is writable and hosts staging, logs, and the
  audit trail per Constitution Article 8.
- Reclaim numbers are authoritative from allocated size; logical size is shown for context only.
- Dev builds are sufficient to validate the spine (no notarized distribution needed in v0.1).
- The license layer is `CleanerLicenseStub`, hard-coded to the Community (free) edition; **no**
  safety feature is gated (Principle 11).
