# 04 — User Stories

> **Phase A · Depends on:** 00-constitution, 01-product-vision, 02-problem-statement,
> 03-personas · **Depended on by:** 05, 06 (traceability matrix), 08, 31.
>
> **Status:** Draft · **Version:** 1.0 · **Owner:** Product

> **v0.6 note.** `cleaner` is a line-based CLI. There are no risk tiers (no 🟢🟡🔴 /
> Safe·Medium·Dangerous) in v0.6 — selection is `Clean all / select each (y/N) / cancel`, and
> safety comes from staging + `cleaner undo` + the protected-path guard, not risk grading. The
> user stories below are reconciled to what shipped; retained risk vocabulary is vestigial
> internal metadata only.

## 1. Purpose

Express the required behaviour of cleaner-cli as user stories in the canonical form
**"As a `<persona>`, I want `<goal>`, so that `<benefit>`"**, grouped by epic, each with a
stable ID (`US-###`) and Given/When/Then acceptance criteria. These IDs are the anchor rows of
the traceability matrix (spec 06): every Functional Requirement MUST trace to ≥ 1 story here,
and every story SHOULD trace forward to ≥ 1 use case (spec 05) and ≥ 1 test (spec 31).

RFC-2119 keywords in acceptance criteria are normative. Personas are P1–P6 from spec 03.
Commands, exit codes, and staging/rollback terms are used exactly as fixed in the Constitution
(Articles 4, 7, 8; glossary Article 3). Risk levels (🟢/🟡/🔴) are **not** surfaced in v0.6 (see
the v0.6 note above) and survive only as vestigial internal metadata that no longer governs
selection, gating, or display.

### 1.1 Story ID map (by epic)

| Epic | ID range |
|---|---|
| A. Analyze | US-001 … US-006 |
| B. Clean | US-007 … US-014 |
| C. Safety | US-015 … US-022 |
| D. Automation / CI | US-023 … US-028 |
| E. Config & Profiles | US-029 … US-033 |
| F. Reporting | US-034 … US-038 |
| G. Plugins | US-039 … US-042 |

Total: **42 stories.**

### 1.2 Acceptance-criteria conventions

- **Given** = precondition/state; **When** = the triggering action; **Then** = the required,
  observable outcome (including exit code where relevant).
- Where a story implies a destructive path, its criteria MUST reference the preview→confirm→
  execute sequence and the default `stage` disposition (Constitution principles 1–2).

---

## Epic A — Analyze (read-only understanding)

### US-001 — See where my space went
*As Diego (P2), I want to run a read-only analysis of my disk that groups reclaimable space by
category, so that I understand what is consuming my disk before deleting anything.*

- **Given** a machine with developer junk present,
- **When** I run `cleaner analyze`,
- **Then** the tool MUST perform a read-only Scan (no filesystem mutation) and present findings
  grouped by category with per-category and total reclaimable size, sorted by size descending,
  and MUST exit `0`.
- **And** re-running it on an unchanged filesystem MUST produce the same totals (determinism,
  principle 5).

### US-002 — Trust the reclaim numbers
*As Mai (P1), I want the reported reclaimable size to reflect actual on-disk allocation, so
that the number I see matches the space I'll actually get back.*

- **Given** findings that include APFS-cloned or sparse files,
- **When** analysis reports sizes,
- **Then** sizes MUST be computed as actual allocated size (CC-10), not naive logical size,
- **And** the same measurement code MUST be used for analyze, dry-run, and real clean
  (principle 3).

### US-003 — Drill into a category
*As Sam (P4), I want to expand a category in a tree view to see the individual items and their
paths, so that I can judge them item by item.*

- **Given** an interactive TTY,
- **When** I expand a category in the `analyze`/`clean` tree,
- **Then** the tool MUST show each Item's path(s), size, and a one-line rationale/evidence
  summary. (No risk level is shown in v0.6.)

### US-004 — Analyze a specific scope
*As Priya (P3), I want to analyze only selected categories or roots, so that I can measure a
target area without a full-disk scan.*

- **Given** a scope flag (e.g. `--only xcode,docker` or a path),
- **When** I run `cleaner analyze --only <categories>`,
- **Then** the tool MUST scan only the requested plugins/roots and report only those,
- **And** an unknown category MUST fail with exit `2` (usage) and a helpful message.

### US-005 — Progress on a big disk
*As Sam (P4), I want live progress while a large scan runs, so that I know it's working and can
estimate completion.*

- **Given** a multi-gigabyte, millions-of-files scan on a TTY,
- **When** the scan is running,
- **Then** the TUI MUST show live progress (items/bytes scanned, current root) and MUST remain
  responsive and memory-bounded (principle 9),
- **And** the scan MUST be cancellable (see US-018).

### US-006 — Machine-readable analysis
*As Priya (P3), I want analysis output as JSON, so that I can feed it into dashboards without
scraping human text.*

- **Given** `--json` (or a non-TTY stdout),
- **When** I run `cleaner analyze --json`,
- **Then** the tool MUST emit a stable, documented JSON schema of categories, items, and sizes
  to stdout, emit no decorative output to stdout, and exit `0`. (Risk levels are not part of the
  v0.6 output.)

---

## Epic B — Clean (reclaim space)

### US-007 — Interactive full clean
*As Mai (P1), I want to interactively review findings and select what to clean, so that I
reclaim space with full control over each item.*

- **Given** a completed scan on a TTY,
- **When** I run `cleaner clean`,
- **Then** the tool MUST print a preview grouped by source and prompt `Clean all X? [Y = all ·
  s = select each · n = cancel]`; `Y` MUST select everything found, `s` MUST offer every source
  individually via a `y/N` prompt, and `n` MUST cancel without mutation (there is no risk-based
  pre-selection in v0.6),
- **And** the tool MUST NOT mutate the filesystem until I confirm,
- **And** on confirmation it MUST move selected items to Staging by default (recoverable via
  `cleaner undo`) and report actual reclaimed bytes, exiting `0` (or `3` if some items were
  skipped/failed).

### US-008 — Quick non-interactive clean
*As Diego (P2), I want a one-command clean of safe junk without prompts, so that I can do a
fast weekly sweep.*

- **Given** `--yes`,
- **When** I run `cleaner clean --yes`,
- **Then** the tool MUST clean everything found without prompting; there is no risk filter in
  v0.6 (no `--include medium` gate), because every action is staged and reversible via `cleaner
  undo` and the protected-path guard still applies,
- **And** it MUST require no interactive input and MUST exit `0`/`3`.

### US-009 — Preview without touching anything (dry-run)
*As Rosa (P5), I want a dry-run that shows exactly what would be deleted and how much would be
reclaimed, without changing anything, so that I can verify before trusting a real run.*

- **Given** `--dry-run`,
- **When** I run `cleaner clean --dry-run`,
- **Then** the tool MUST perform no filesystem mutation, MUST list every item it *would* act on
  with its disposition, and MUST report a reclaim total using the same measurement as a real
  run (principle 3), exiting `0`.

### US-010 — Clean a single category
*As Diego (P2), I want to clean just Docker (or just node_modules), so that I can target my
biggest hog without reviewing everything.*

- **Given** `--only docker`,
- **When** I run `cleaner clean --only docker`,
- **Then** only that plugin's items MUST be in scope, with the same preview/confirm/stage rules.

### US-011 — Bulk select found items
*As Sam (P4), I want to select everything found at once instead of ticking each one, so that I
don't answer dozens of prompts by hand.*

- **Given** the interactive selection prompt,
- **When** I answer `Y` (`Clean all`),
- **Then** the tool MUST select every reclaimable item found in one action, while `s` (`select
  each`) MUST instead walk items individually via `y/N`. (v0.6 surfaces no risk tiers, so
  risk-based bulk selection is not shipped.)

### US-012 — Deselect an item I care about
*As Mai (P1), I want to exclude a specific item before confirming, so that a named simulator or
profile I recognize is never touched.*

- **Given** an item offered in `select each` mode,
- **When** I answer `N` at its `y/N` prompt and confirm the rest,
- **Then** that item MUST NOT be acted on, and the report MUST record it as `skip`.

### US-013 — Idempotent re-run
*As Priya (P3), I want a second `clean` immediately after the first to find nothing new, so
that cleanup is safe to run repeatedly (e.g. in a loop or CI).*

- **Given** a `clean` just completed,
- **When** I run `cleaner clean --yes` again on the unchanged tree,
- **Then** the tool MUST find no new reclaimable items and MUST exit `0` reporting 0 bytes
  reclaimed (idempotence, principle 5).

### US-014 — Send to macOS Trash instead of staging
*As Sam (P4), I want the option to route deletions to the macOS Trash, so that I can recover
via Finder in my usual workflow.*

- **Given** `--trash`,
- **When** I clean with `--trash`,
- **Then** eligible items MUST be moved to the macOS Trash (via the native recycle API) instead
  of tool Staging, and the report MUST record disposition `trash`.

---

## Epic C — Safety (trust & reversibility)

### US-015 — Roll back a regretted clean
*As Diego (P2), I want to undo the last clean and restore everything to its original location,
so that a mistake costs me one command, not my afternoon.*

- **Given** a completed clean whose items are in Staging,
- **When** I run `cleaner clean --rollback` (or the documented rollback command) for that
  session,
- **Then** every staged Item MUST be restored to its exact original path with original
  metadata, the operation MUST report success per item, and exit `0` (or `3` if any item could
  not be restored, listing them).

### US-016 — Credentials are untouchable
*As Rosa (P5), I want a hard guarantee that keys, credentials, and user-content roots are never
deleted, so that no configuration or plugin bug can lose them.*

- **Given** any scan or clean, with any config or plugin,
- **When** an item resolves to a protected path (`~/.ssh`, `~/.gnupg`, Keychains, `*.pem`,
  `*.key`, `~/Documents`, etc. — Constitution Article 5),
- **Then** the engine MUST refuse to act on it regardless of risk score or user selection, MUST
  log the refusal, and if such an action was explicitly requested MUST abort with exit `8`
  (safety).

### US-017 — No symlink escapes
*As Rosa (P5), I want the tool to never follow a symlink out of an allowed root to delete its
target, so that a crafted or accidental link can't redirect a deletion.*

- **Given** a symlink inside an allowed root pointing outside it,
- **When** cleaning encounters it,
- **Then** the engine MUST NOT delete the symlink's target outside the allowed root (Article
  4.4); it MAY remove the link entry itself only if that entry is within scope.

### US-018 — Cancel mid-run safely
*As Sam (P4), I want to cancel a scan or clean with `q`/Ctrl-C and have the tool stop cleanly,
so that I'm never left in an inconsistent state.*

- **Given** a scan or clean in progress,
- **When** I press `q` or Ctrl-C,
- **Then** the tool MUST stop at the next safe checkpoint, leave no partially-deleted item
  (staging is atomic per item), report what was completed, and exit `5` (cancelled).

### US-019 — Understand why an item is flagged
*As Rosa (P5), I want each finding to explain the evidence behind its risk assessment, so that
I can judge the tool's reasoning rather than trust it blindly.*

- **Given** any finding,
- **When** I inspect it (TUI detail or `--json`),
- **Then** the tool MUST expose the evidence (e.g. mtime/last-access, regenerability, path
  confidence, lock/in-use state). (Risk level and safety score are internal-only in v0.6 and are
  not surfaced to the user.)

### US-020 — Stray-keypress mistakes are recoverable
*As Mai (P1), I want to never lose something irreplaceable to a stray keypress, so that any
mistake can be undone.*

- **Given** any item selected for cleaning,
- **When** I confirm,
- **Then** the tool MUST move it to Staging (never hard-delete) so it can be restored
  byte-for-byte via `cleaner undo`, and the protected-path guard MUST still refuse untouchable
  paths (US-016).

> **Not shipped in v0.6.** The original intent — a typed-confirmation gate for 🔴 dangerous
> items — was dropped with the risk tiers. v0.6 has no dangerous tier and no typed-confirm
> prompt; reversibility (staging + `cleaner undo`) plus the protected-path guard is the safety
> mechanism instead.

### US-021 — Warn on in-use / locked files
*As Diego (P2), I want the tool to detect and skip files that are currently open or locked
(e.g. a running Docker container's data), so that cleanup never corrupts a live process.*

- **Given** an item that is open/locked/in-use,
- **When** cleaning would touch it,
- **Then** the tool MUST NOT delete it without an explicit override, MUST mark it skipped in
  the report, and MUST NOT auto-clean it under `--yes` (Article 4.4).

### US-022 — Purge is deliberate and irreversible-by-design
*As Rosa (P5), I want permanent deletion (purge) to be a separate, explicit step, so that
"empty the staging" can never happen by accident during a normal clean.*

- **Given** items in Staging,
- **When** I run a clean normally,
- **Then** the tool MUST NOT purge automatically; purge MUST be a distinct, explicitly-invoked
  operation with confirmation, and `--no-stage` MUST require confirmation (Article 4.4).

---

## Epic D — Automation / CI

### US-023 — Health gate in CI
*As Priya (P3), I want `cleaner doctor` to return a CI-mapped exit code, so that my pipeline can
gate on disk/tool health.*

- **Given** `--ci`,
- **When** I run `cleaner doctor --ci`,
- **Then** the tool MUST map health to exit `0` (healthy), `3` (warnings), or `1` (critical)
  per Article 7, and MUST print a concise, non-interactive summary.

### US-024 — Unattended clean in a pipeline
*As Priya (P3), I want a fully non-interactive clean that never blocks on a prompt, so that CI
jobs don't hang.*

- **Given** `--yes` (and/or `--ci`) with no TTY,
- **When** `cleaner clean --yes` runs in CI,
- **Then** the tool MUST never prompt, MUST proceed non-interactively cleaning everything found
  (v0.6 has no risk filter; all actions are staged and reversible), and MUST exit with a
  deterministic code (`0`/`3`/`4`/…) usable in pipeline logic.

### US-025 — Governed automation policy
*As Priya (P3), I want unattended runs to be governed by a signed policy that scopes what may be
cleaned, so that automation can't exceed its mandate.*

- **Given** a signed automation policy file (Article 5 / spec 23),
- **When** an unattended `clean` runs under that policy,
- **Then** the tool MUST honor the policy's category/path scope, MUST refuse actions outside it,
  and MUST record the policy identity in the audit trail (principle 8).

### US-026 — Exit codes drive pipeline logic
*As Priya (P3), I want documented, stable exit codes, so that I can branch my CI on the result
without parsing text.*

- **Given** any invocation,
- **When** it completes,
- **Then** the exit code MUST conform exactly to Constitution Article 7 (e.g. `4` when Full Disk
  Access is missing, `6` for bad config, `2` for bad flags), and MUST be documented in the
  command reference (spec 08).

### US-027 — No network in the clean path
*As Rosa (P5) and Priya (P3), I want assurance the cleaning path makes no network calls, so that
it's safe to run on locked-down/air-gapped CI.*

- **Given** telemetry off (the default),
- **When** any scan/clean/report runs,
- **Then** the core cleaning path MUST make no network I/O (principle 10); any opt-in telemetry
  MUST be off by default and clearly separable.

### US-028 — Timeout / resume for long jobs
*As Priya (P3), I want long scans to respect a timeout and be resumable, so that CI jobs stay
bounded and interrupted scans don't restart from zero.*

- **Given** `--timeout <d>` and/or an interrupted prior scan,
- **When** the timeout elapses or a scan resumes,
- **Then** on timeout the tool MUST stop cleanly and exit `5`; on resume it MUST continue from
  the last checkpoint rather than rescanning everything (spec 17).

---

## Epic E — Config & Profiles

### US-029 — Ignore paths I always want kept
*As Diego (P2), I want to configure paths/globs the tool must never touch, so that my active
project's `node_modules` and volumes are always safe.*

- **Given** a whitelist/ignore section in `~/.cleaner/config.yml` (spec 24),
- **When** any scan/clean runs,
- **Then** matching items MUST be excluded from findings and never acted on, and the config
  MUST be validated (invalid config → exit `6`).

### US-030 — Add extra targets
*As Sam (P4), I want to add my own cleanable paths/rules (a blacklist/target rule), so that the
tool also reclaims junk it doesn't know about by default.*

- **Given** a user target rule in config (Article 3 glossary),
- **When** scanning,
- **Then** the tool MUST include matching paths as findings **only** within the allow-space
  (never overriding protected paths, Article 5). (User target rules carry no user-facing risk in
  v0.6; the internal classifier stays conservative.)

### US-031 — Save and reuse a profile
*As Sam (P4), I want to save my plugin selection and options as a named profile, so that my
monthly ritual is one command.*

- **Given** a configured selection,
- **When** I save it as a profile and later run `cleaner clean --profile prosumer-monthly`,
- **Then** the tool MUST apply exactly that profile's plugin selection and options.

### US-032 — Share a team config
*As Tomás (P6), I want to distribute one config/profile to the team, so that everyone cleans the
same safe way.*

- **Given** a shared `config.yml`/profile provided to team machines,
- **When** a team member runs `cleaner clean --profile team-safe`,
- **Then** the behaviour MUST be identical across machines given identical config (determinism,
  principle 5), and the config location MUST be overridable via `CLEANER_HOME` (Article 8).

### US-033 — Override tool home / staging location
*As Priya (P3), I want to point the tool's home (config, staging, logs) at a specific path, so
that CI runners can place them on scratch volumes.*

- **Given** `CLEANER_HOME` set,
- **When** the tool runs,
- **Then** config, staging, logs, cache, and reports MUST all live under that path (Article 8).

---

## Epic F — Reporting

### US-034 — Human-readable run summary
*As Mai (P1), I want a clear summary after a clean (what was cleaned, reclaimed, skipped), so
that I know exactly what happened.*

- **Given** a completed clean,
- **When** it finishes,
- **Then** the tool MUST print a summary with per-category and total reclaimed bytes, counts of
  cleaned/skipped/failed items, and the staging location for rollback.

### US-035 — JSON report for automation
*As Priya (P3), I want a machine-readable report of a run, so that I can archive and dashboard
it.*

- **Given** `cleaner report --json` (or `clean --json`),
- **When** invoked,
- **Then** the tool MUST emit a documented, stable JSON schema including session UUID, items,
  dispositions, sizes, timings, and exit status. (Risk levels are not part of the v0.6 schema.)

### US-036 — Export a shareable report
*As Sam (P4), I want to export a report as Markdown/HTML, so that I can save or share it.*

- **Given** `cleaner report --format html` (or `md`),
- **When** invoked,
- **Then** the tool MUST write the report to `~/.cleaner/reports/` (Article 8) in the requested
  format and print its path.

### US-037 — Audit trail of every file touched
*As Rosa (P5), I want an append-only audit log of every filesystem mutation, so that I can
answer "why was this deleted?" after the fact.*

- **Given** any clean/purge/rollback,
- **When** files are mutated,
- **Then** the tool MUST append one NDJSON event per mutation to `~/.cleaner/logs/audit/`
  (Article 8), including path, disposition, size, session UUID, and evidence reference
  (principle 8).

### US-038 — Report on the last session
*As Tomás (P6), I want to retrieve the report of a past session without re-running, so that I
can review outcomes in a retro.*

- **Given** a prior session with a stored report,
- **When** I run `cleaner report --session <uuid>` (or `--last`),
- **Then** the tool MUST reproduce that session's report from stored data, without re-scanning.

---

## Epic G — Plugins

### US-039 — Xcode/simulator cleanup
*As Mai (P1), I want a plugin that understands Xcode DerivedData, archives, device support, and
stale simulators/runtimes, so that my #1 junk source is handled safely.*

- **Given** the Xcode plugin enabled,
- **When** scanning,
- **Then** it MUST offer DerivedData for cleaning, and MUST conservatively exclude
  booted/named/in-use simulators by default (not offer them), exposing evidence (US-019). (v0.6
  surfaces no risk colors; the classifier is internal-only.)

### US-040 — Docker cleanup without losing data
*As Diego (P2), I want a Docker plugin that reclaims images/build-cache/dangling layers but
conservatively excludes volumes with data, so that I never lose a database volume.*

- **Given** the Docker plugin enabled,
- **When** scanning,
- **Then** dangling images/build cache MUST be offered for cleaning, named volumes with data
  MUST be conservatively excluded (not offered by default) and never auto-cleaned, and a running
  container's resources MUST be treated as in-use (US-021). If Docker is not installed/running,
  the plugin MUST be skipped gracefully (reported, exit unaffected). (v0.6 surfaces no risk
  colors; classification is internal-only.)

### US-041 — Duplicate finder
*As Sam (P4), I want to find and remove duplicate files, keeping one copy, so that I reclaim
space wasted on exact copies.*

- **Given** the duplicate-finder plugin,
- **When** it reports a duplicate set,
- **Then** duplicates MUST be confirmed by content hash (SHA-256, spec 10) — not name/size
  alone — the tool MUST clearly mark which copy is retained, and MUST default to keeping one
  copy (never deleting an entire set).

### US-042 — Large / old-file finder
*As Sam (P4), I want to list the largest and oldest files above thresholds, so that I can
decide on big items the category plugins don't cover.*

- **Given** the large/old-file plugin with size/age thresholds,
- **When** scanning,
- **Then** it MUST list qualifying files with size, last-access date, and Spotlight kind, MUST
  conservatively exclude user-content-root files (per Article 5), and MUST require explicit
  selection before any file is acted on.

---

## 2. Coverage summary

| Epic | Stories | Primary personas | Primary KPIs (spec 01) |
|---|---|---|---|
| A Analyze | US-001–006 | P2, P4, P3 | K3, K5 |
| B Clean | US-007–014 | P1, P2, P4 | K2, K8 |
| C Safety | US-015–022 | P1, P5, P2 | K1, K4, K6 |
| D Automation/CI | US-023–028 | P3 | K8, K10 |
| E Config/Profiles | US-029–033 | P2, P4, P6, P3 | K8, K9 |
| F Reporting | US-034–038 | P3, P5, P6 | K5, and audit for K1 |
| G Plugins | US-039–042 | P1, P2, P4 | K2, K6 |

## Open Questions

- **OQ-04.1** Should rollback be a top-level command (`cleaner rollback`) or a `clean
  --rollback` flag (US-015)? This affects the command reference (spec 08). *Leaning: a
  first-class `cleaner rollback` with `--last`/`--session`; keep wording spec-08-final.*
- **OQ-04.2** Is `--trash` (US-014) worth the extra disposition path in v1, given staging
  already provides reversibility? *Leaning: yes, low cost, matches Sam's Finder workflow.*
- **OQ-04.3** ~~Do user target rules (US-030) need their own risk-scoring, or do they default to
  a most-conservative tier pending user override?~~ **Resolved:** v0.6 ships without user-facing
  risk tiers; user target rules carry no risk color, the internal classifier stays conservative,
  and matching paths are never acted on without explicit selection.
- **OQ-04.4** Should `analyze` and `clean` share one scan (analyze = clean's preview phase) to
  avoid double-scanning (US-001 vs US-007)? *Leaning: yes; formalize in spec 17/20.*
- **OQ-04.5** How granular is per-item deselection in the TUI for very large sets (US-012) —
  individual items, or only sub-groups, for performance? Decide in spec 25.

## Dependencies

**Consumes:** 00-constitution (Article 4 risk defaults, Article 7 exit codes, Article 8 layout,
principles 1/2/5/8/10), 01-product-vision (KPIs stories serve), 02-problem-statement (jobs),
03-personas (the `<persona>` referents).

**Feeds:** 05-use-cases (elaborates key stories into flows), 06-functional-requirements (each FR
traces to stories here; traceability matrix consumes these IDs), 08-command-reference (commands/
flags implied), 22-safety-model (safety epic), 21-rollback-design (US-015/022), 24-configuration
(Epic E), 31-testing-strategy (each acceptance criterion becomes a test).
