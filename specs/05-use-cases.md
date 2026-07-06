# 05 — Use Cases

> **Phase A · Depends on:** 00-constitution, 01-product-vision, 03-personas, 04-user-stories ·
> **Depended on by:** 06 (traceability matrix), 08, 20, 21, 23, 31.
>
> **Status:** Draft · **Version:** 1.0 · **Owner:** Product / UX

## 1. Purpose

Elaborate the highest-value user stories (spec 04) into detailed, step-by-step **use cases**
(`UC-###`) with actor, preconditions, main flow, alternate flows, exception flows, and
postconditions. Where stories say *what* the user wants, use cases fix *how the interaction
unfolds*, including error and edge behaviour. Each UC MUST trace to ≥ 1 user story and is a
row in the traceability matrix (spec 06). RFC-2119 keywords are normative.

Conventions: exit codes per Constitution Article 7; risk levels 🟢/🟡/🔴 per Article 4;
staging/rollback/purge/disposition per the glossary (Article 3); protected paths per Article 5.
"The engine" = the safety-enforcing core; "a plugin" = a category cleaner (spec 13).

### 1.1 Use-case index

| ID | Title | Primary actor | Traces to stories |
|---|---|---|---|
| UC-001 | Interactive full clean | Mai (P1) | US-007, 003, 011, 012, 034 |
| UC-002 | Quick clean `--yes` | Diego (P2) | US-008, 013 |
| UC-003 | Dry-run preview | Rosa (P5) | US-009, 019 |
| UC-004 | Analyze-only | Diego (P2) | US-001, 002, 004, 005 |
| UC-005 | Doctor in CI | Priya (P3) | US-023, 026 |
| UC-006 | JSON report for automation | Priya (P3) | US-006, 035, 037 |
| UC-007 | Rollback after regret | Diego (P2) | US-015, 018 |
| UC-008 | First-run Full Disk Access grant | Mai (P1) | US-026 (exit 4), permission |
| UC-009 | Config-driven ignore | Diego (P2) | US-029, 030 |
| UC-010 | Duplicate finder | Sam (P4) | US-041 |
| UC-011 | Large/old-file finder | Sam (P4) | US-042 |
| UC-012 | Governed unattended clean (policy) | Priya (P3) | US-024, 025, 027, 028 |
| UC-013 | Cancel a running scan | Sam (P4) | US-005, 018 |
| UC-014 | Purge staging (permanent) | Rosa (P5) | US-022 |
| UC-015 | Export shareable report | Tomás (P6) | US-036, 038 |

---

## UC-001 — Interactive full clean

- **Primary actor:** Mai (P1). **Goal:** reclaim safe junk with per-item control.
- **Preconditions:** Interactive TTY; Full Disk Access granted (else UC-008); tool home exists.
- **Trigger:** `cleaner clean`.

**Main flow**
1. The engine loads config and enabled plugins; validates config (fail → E1).
2. The engine runs a read-only Scan across plugin roots, streaming progress to the TUI.
3. The tool renders findings as a tree grouped by category, each Item showing size, risk badge
   (🟢/🟡/🔴), and one-line evidence.
4. The engine pre-selects all 🟢 items; leaves 🟡 shown-but-unselected; shows 🔴 unselected.
5. Mai expands a category (US-003), reviews items, uses "select all safe" (US-011) and
   deselects a named simulator she wants to keep (US-012).
6. Mai confirms. The tool shows a final preview: item count, total reclaim, dispositions.
7. Mai confirms execution. The engine moves each selected Item to Staging (`stage`
   disposition), one atomically at a time, appending an audit event per mutation.
8. The tool prints a summary: per-category and total reclaimed bytes, cleaned/skipped counts,
   and the staging path for rollback. Exit `0`.

**Alternate flows**
- **A1 (medium included):** Mai also selects 🟡 items; the tool includes them; behaviour
  otherwise identical.
- **A2 (dangerous selected):** Mai selects a 🔴 item; before execution the tool requires a
  typed confirmation for it (US-020); on non-match it is skipped.
- **A3 (trash routing):** Mai passed `--trash`; step 7 routes to macOS Trash instead of Staging.

**Exception flows**
- **E1 (bad config):** config invalid → abort before scanning, exit `6`.
- **E2 (protected path selected):** a selection resolves to a protected path → engine refuses,
  logs it, and if it cannot be silently excluded, aborts with exit `8`.
- **E3 (item in use):** a selected item is open/locked → skipped, recorded, reported (US-021).
- **E4 (partial failure):** some items fail to stage → completed items kept, failures listed,
  exit `3`.
- **E5 (cancel):** Mai presses `q`/Ctrl-C → see UC-013; exit `5`.

**Postconditions**
- **Success:** selected non-protected items are in Staging; disk reclaimed; audit + report
  written; filesystem otherwise unchanged. **Failure:** no partial/half-deleted item exists
  (per-item atomicity); report explains what happened.

---

## UC-002 — Quick clean `--yes`

- **Primary actor:** Diego (P2). **Goal:** fast safe sweep, no prompts.
- **Preconditions:** Full Disk Access granted; may be TTY or not.
- **Trigger:** `cleaner clean --yes` (optionally `--include medium`, `--only <cat>`).

**Main flow**
1. Engine loads config/plugins, scans.
2. Engine auto-selects **only** 🟢 items (🟡 only if `--include medium`; 🔴 never — Article 4.1).
3. Without prompting, engine stages selected items, writing audit events.
4. Tool prints a concise summary; exit `0`.

**Alternate flows**
- **A1 (nothing to do / idempotent re-run):** no 🟢 items found → report 0 bytes, exit `0`
  (US-013).
- **A2 (scoped):** `--only docker` limits scope to one plugin.

**Exception flows**
- **E1 (missing permission):** Full Disk Access not granted → no destructive action, print
  guidance, exit `4`.
- **E2 (partial):** some items fail → exit `3`, failures listed.
- **E3 (protected path):** engine invariant refuses → exit `8`.

**Postconditions:** only 🟢 (and opted 🟡) non-protected items staged; deterministic exit code;
never blocked on input.

---

## UC-003 — Dry-run preview

- **Primary actor:** Rosa (P5). **Goal:** see exactly what *would* happen, mutate nothing.
- **Preconditions:** none beyond read access; permission gaps are reported, not fatal.
- **Trigger:** `cleaner clean --dry-run` (optionally `--json`).

**Main flow**
1. Engine scans read-only.
2. Engine computes dispositions for every candidate Item exactly as a real run would, using the
   same measurement code (principle 3).
3. Tool lists each Item with path, risk, disposition (`stage`/`trash`/`skip`), and reclaim
   size; prints a reclaim total.
4. Engine performs **no** filesystem mutation and writes **no** audit deletion events; exit `0`.

**Alternate flows**
- **A1 (JSON):** `--json` emits the machine-readable preview (schema = real report minus
  execution results).
- **A2 (permission gap):** items requiring access Rosa lacks are shown as "would require Full
  Disk Access", still non-fatal in dry-run.

**Exception flows**
- **E1 (bad config):** exit `6`. **E2 (bad flags):** exit `2`.

**Postconditions:** filesystem unchanged; the printed reclaim total MUST equal what a real run
would achieve for the same selection (US-009; KPI K5).

---

## UC-004 — Analyze-only

- **Primary actor:** Diego (P2). **Goal:** understand disk usage before deciding.
- **Preconditions:** read access to roots.
- **Trigger:** `cleaner analyze` (optionally `--only`, `--json`).

**Main flow**
1. Engine scans read-only, streaming progress (US-005).
2. Tool presents categories with reclaimable size, sorted descending, expandable to items
   (US-003), each with risk and evidence.
3. Exit `0`. No mutation, no staging.

**Alternate flows**
- **A1 (scoped):** `--only xcode,docker` restricts plugins.
- **A2 (JSON):** `--json` emits the analysis schema; no TUI on stdout.

**Exception flows**
- **E1 (unknown category):** exit `2`. **E2 (permission gap):** categories needing access not
  granted are marked "not measured (needs Full Disk Access)"; exit `0` or `4` per policy in
  spec 23.

**Postconditions:** filesystem unchanged; determinism holds on re-run (principle 5).

---

## UC-005 — Doctor in CI

- **Primary actor:** Priya (P3). **Goal:** gate a pipeline on environment/tool health.
- **Preconditions:** non-interactive CI shell.
- **Trigger:** `cleaner doctor --ci`.

**Main flow**
1. Tool checks environment: OS version/support, permissions status, tool-home integrity, plugin
   availability (e.g. is Docker present), disk pressure, staging health.
2. Tool prints a concise, non-interactive health summary.
3. Tool maps overall health to exit `0` (healthy), `3` (warnings), `1` (critical) per Article 7.

**Alternate flows**
- **A1 (warnings only):** e.g. Docker not running → warning, exit `3`; pipeline may proceed.

**Exception flows**
- **E1 (unsupported OS):** exit `10` (precondition). **E2 (bad flags):** exit `2`.

**Postconditions:** no mutation; exit code usable as a CI gate; no prompt emitted.

---

## UC-006 — JSON report for automation

- **Primary actor:** Priya (P3). **Goal:** feed run results into dashboards/archive.
- **Preconditions:** a run occurred (or is run now with `--json`).
- **Trigger:** `cleaner report --json [--last | --session <uuid>]` or `cleaner clean --yes --json`.

**Main flow**
1. Tool loads (or produces) the session record.
2. Tool emits a documented, stable JSON schema to stdout: session UUID, per-item paths/sizes/
   risk/disposition/result, per-category and total reclaim, timings, exit status (US-035).
3. Decorative TUI is suppressed on stdout; exit reflects the run (`0`/`3`/…).

**Alternate flows**
- **A1 (from stored session):** `--session <uuid>`/`--last` reproduces a past report without
  rescanning (US-038).

**Exception flows**
- **E1 (unknown session):** exit `2` with message. **E2 (corrupt session store):** exit `1`,
  logged.

**Postconditions:** valid JSON on stdout conforming to the published schema; audit trail
unchanged (reporting is read-only).

---

## UC-007 — Rollback after regret

- **Primary actor:** Diego (P2). **Goal:** restore a just-cleaned set to original locations.
- **Preconditions:** a prior clean whose items are still in Staging (not purged).
- **Trigger:** `cleaner rollback --last` (or `--session <uuid>`).

**Main flow**
1. Tool locates the session's staging set and its recorded original paths.
2. For each staged Item, the engine restores it to its exact original path with original
   metadata (mtime, xattrs), one atomically at a time, appending a rollback audit event.
3. Tool reports restored counts and location; exit `0`.

**Alternate flows**
- **A1 (selective):** user restores only certain categories/items; the rest stay staged.

**Exception flows**
- **E1 (original path now occupied):** a file exists at the target → engine MUST NOT overwrite;
  it restores to a sibling safe path or skips with a clear message; such items counted; exit
  `3`.
- **E2 (already purged):** staging set no longer exists → exit `1` with explanation (recovery
  impossible; this is why purge is deliberate, UC-014).
- **E3 (partial):** some items fail to restore → others restored, failures listed, exit `3`.

**Postconditions:** restored items are back at (or safely beside) their origins; audit records
the rollback; staging entries for restored items are cleared.

---

## UC-008 — First-run Full Disk Access grant

- **Primary actor:** Mai (P1). **Goal:** grant the access the tool needs, understanding why.
- **Preconditions:** first run (or FDA not yet granted); many dev-junk paths under
  `~/Library` require Full Disk Access to enumerate reliably.
- **Trigger:** any command needing access it lacks (e.g. `cleaner analyze`).

**Main flow**
1. Engine detects it cannot fully read required roots (permission probe).
2. Tool explains, in plain language, *what* access is needed and *why* (least privilege,
   principle 6; spec 23), and that it will not escalate silently.
3. Tool shows the exact steps to grant Full Disk Access (System Settings → Privacy & Security →
   Full Disk Access), and how to re-run.
4. Mai grants access and re-runs; the command proceeds normally.

**Alternate flows**
- **A1 (partial access acceptable):** for a scoped command that doesn't need FDA, the tool
  proceeds with a note that some categories are unmeasured.

**Exception flows**
- **E1 (declines):** Mai does not grant access → the tool does not perform destructive actions,
  reports what it could/couldn't do, exit `4` (permission).
- **E2 (admin-owned path later):** a specific action needs admin authorization → the tool
  requests it lazily and scoped via Authorization Services (spec 23), explaining the single
  operation; never a blanket sudo.

**Postconditions:** access is granted explicitly and scoped, or the tool declined to act;
nothing was escalated silently; the decision is logged.

---

## UC-009 — Config-driven ignore

- **Primary actor:** Diego (P2). **Goal:** guarantee certain paths are never touched, and add
  extra targets.
- **Preconditions:** `~/.cleaner/config.yml` present (or created); valid.
- **Trigger:** any scan/clean after editing config.

**Main flow**
1. Engine loads and validates config (invalid → E1, exit `6`).
2. Engine intersects plugin roots with the allow-space, subtracts protected paths (Article 5),
   then applies the user **whitelist/ignore** (removes matches) and **target rules** (adds
   matches within allow-space only) (US-029, US-030).
3. Scan produces findings excluding ignored paths; user-added targets appear with a
   conservative default risk (never 🟢 without evidence).
4. Clean proceeds as UC-001/UC-002 over the filtered set.

**Alternate flows**
- **A1 (glob rules):** ignore/target entries use globs; matching is deterministic and
  documented (spec 24).
- **A2 (profile carries the config):** running with `--profile` applies that profile's
  ignore/target set.

**Exception flows**
- **E1 (invalid config):** exit `6` with the offending key/line.
- **E2 (target rule hits a protected path):** the protected path wins; the rule is ignored for
  that path and a warning is logged (Article 5 is non-overridable except by signed policy).

**Postconditions:** ignored paths are provably absent from findings; targets included only
within allow-space; behaviour reproducible across machines with the same config (US-032).

---

## UC-010 — Duplicate finder

- **Primary actor:** Sam (P4). **Goal:** reclaim space from exact-duplicate files, keeping one.
- **Preconditions:** duplicate-finder plugin enabled; read access to scanned roots.
- **Trigger:** `cleaner analyze --only duplicates` then `cleaner clean --only duplicates` (or a
  combined interactive flow).

**Main flow**
1. Plugin enumerates candidate files, prefilters by size (and a fast rolling/`xxHash`), then
   **confirms** duplicates by SHA-256 content hash (spec 10) — never by name/size alone.
2. Plugin groups confirmed duplicate sets; for each set it designates one copy to **retain**
   (by a documented rule, e.g. oldest/most-referenced path) and marks the rest cleanable.
3. Tool presents sets in the TUI, clearly indicating the retained copy; nothing is
   pre-selected among user-content locations (conservative).
4. Sam selects sets to clean; on confirmation the extra copies are staged (retained copy
   untouched); summary + exit `0`.

**Alternate flows**
- **A1 (choose which to keep):** Sam overrides which copy is retained per set.

**Exception flows**
- **E1 (hash collision guard):** if two files match the prefilter but differ on full hash, they
  MUST NOT be grouped as duplicates.
- **E2 (all copies in protected paths):** the set is reported but not actionable; nothing
  staged.
- **E3 (file changed mid-scan):** a candidate whose content changed between hash and action is
  re-verified or skipped (never delete on stale hash).

**Postconditions:** at least one copy of every set is always retained; only surplus copies
staged; determinism on re-run.

---

## UC-011 — Large / old-file finder

- **Primary actor:** Sam (P4). **Goal:** surface big/stale files the category plugins don't own.
- **Preconditions:** large/old-file plugin enabled with size and age thresholds (config/flags).
- **Trigger:** `cleaner analyze --only large-old` (optionally `--min-size`, `--older-than`).

**Main flow**
1. Plugin enumerates within allow-space, collecting files above the size threshold and/or with
   last-access older than the age threshold.
2. For each, it records size, last-access date, and Spotlight kind as evidence (US-019).
3. Files under user-content roots are classified 🔴 (or excluded per Article 5); none are
   pre-selected.
4. Tool lists results sorted by size/age; Sam explicitly selects any to clean; selected items
   follow the standard preview→confirm→stage path.

**Alternate flows**
- **A1 (report-only):** Sam only analyzes and exports (UC-015), deleting nothing.

**Exception flows**
- **E1 (protected path):** big files under protected roots are shown for awareness but never
  actionable.
- **E2 (in-use):** an open large file is marked and not auto-actionable (US-021).

**Postconditions:** no large/old file is ever cleaned without explicit selection; user-content
never staged without a typed 🔴 confirmation (US-020).

---

## UC-012 — Governed unattended clean (signed policy)

- **Primary actor:** Priya (P3). **Goal:** run cleanup in CI within a bounded, signed mandate.
- **Preconditions:** a signed automation policy at `~/.cleaner/policy/` (spec 23); non-TTY CI.
- **Trigger:** `cleaner clean --yes --policy <name>` (with `--timeout`, `--json`).

**Main flow**
1. Engine loads and verifies the policy signature (invalid/unsigned → E1).
2. Engine scopes the run to the policy's allowed categories/paths and risk ceiling (e.g. 🟢
   only), refusing anything outside it.
3. Engine scans (respecting `--timeout`) and stages in-scope 🟢 items without prompting.
4. Engine records the policy identity in the audit trail (principle 8); emits JSON (UC-006);
   exit `0`/`3`.

**Alternate flows**
- **A1 (resume):** an interrupted prior scan resumes from checkpoint (US-028; spec 17).
- **A2 (timeout hit):** run stops cleanly at a checkpoint, reports partial work, exit `5`.

**Exception flows**
- **E1 (bad/unsigned policy):** refuse to run; exit `6` (config). **E2 (out-of-scope action
  attempted by a plugin):** engine refuses, exit `8`. **E3 (no network guarantee):** telemetry
  stays off; no network I/O in the path (US-027).

**Postconditions:** only policy-permitted items staged; audit names the policy; deterministic
exit; safe to run every job (idempotent).

---

## UC-013 — Cancel a running scan/clean

- **Primary actor:** Sam (P4). **Goal:** stop safely without an inconsistent state.
- **Preconditions:** a scan or clean is in progress on a TTY.
- **Trigger:** Sam presses `q` or Ctrl-C.

**Main flow**
1. Engine receives the cancel signal and sets cooperative cancellation.
2. Work stops at the next safe checkpoint (directory boundary for scan; between per-item atomic
   stages for clean).
3. Tool reports what completed (bytes staged so far, items done) and where staging lives.
4. Exit `5` (cancelled).

**Alternate flows**
- **A1 (during scan only):** no mutation had occurred → nothing to undo; exit `5`.

**Exception flows**
- **E1 (second Ctrl-C / SIGINT):** honored as immediate interrupt; POSIX exit `130`; already-
  staged items remain valid and recoverable.

**Postconditions:** no partially-deleted item exists; any already-staged items are fully staged
and rollback-able; state is consistent.

---

## UC-014 — Purge staging (permanent, irreversible)

- **Primary actor:** Rosa (P5). **Goal:** permanently free space held by staged items she's sure
  about — deliberately.
- **Preconditions:** items exist in Staging; Rosa has reviewed them.
- **Trigger:** `cleaner clean --purge` / `cleaner staging purge` (explicit; wording spec-08).

**Main flow**
1. Tool lists staged sessions/items and the space they hold.
2. Tool requires an explicit confirmation that purge is **irreversible** (the only irreversible
   operation, Article 3/4.4).
3. On confirmation, the engine permanently deletes the staged items, appending audit events;
   space is reclaimed; exit `0`.

**Alternate flows**
- **A1 (scoped purge):** purge only a chosen session (`--session <uuid>`) or age (`--older-than`).
- **A2 (automatic retention policy):** staging older than a configured TTL MAY be purged, but
  only when the user has enabled that policy (never a silent default).

**Exception flows**
- **E1 (no confirmation):** abort, nothing purged, exit `5`.
- **E2 (`--no-stage` path):** a direct permanent delete still requires confirmation (Article
  4.4); without it, exit `5`.

**Postconditions:** purged items are gone irrecoverably; staging entries cleared; audit records
the purge; no rollback is possible for purged items (by design).

---

## UC-015 — Export a shareable report

- **Primary actor:** Tomás (P6). **Goal:** produce a report to review/share without re-running.
- **Preconditions:** a stored session exists.
- **Trigger:** `cleaner report --last --format html` (or `md`, `--session <uuid>`).

**Main flow**
1. Tool loads the session record.
2. Tool renders the report in the requested format and writes it to `~/.cleaner/reports/`
   (Article 8).
3. Tool prints the output file path; exit `0`.

**Alternate flows**
- **A1 (JSON):** `--format json` / `--json` for machine consumption (UC-006).
- **A2 (stdout):** with `-` as output, the report streams to stdout instead of a file.

**Exception flows**
- **E1 (unknown session):** exit `2`. **E2 (unwritable reports dir):** exit `1`, logged.

**Postconditions:** a report file exists at a printed path; no filesystem cleaning occurred
(read-only operation).

---

## 2. Traceability preview (UC → stories → KPIs)

| UC | Stories | KPIs (spec 01) | Personas |
|---|---|---|---|
| UC-001 | US-007,003,011,012,034 | K2,K3,K6 | P1 |
| UC-002 | US-008,013 | K2,K8 | P2 |
| UC-003 | US-009,019 | K5 | P5 |
| UC-004 | US-001,002,004,005 | K3,K5 | P2 |
| UC-005 | US-023,026 | K10 | P3 |
| UC-006 | US-006,035,037 | K5 (audit for K1) | P3 |
| UC-007 | US-015,018 | K4 | P2 |
| UC-008 | US-026 (exit 4) | K1 (least privilege) | P1 |
| UC-009 | US-029,030 | K6 | P2 |
| UC-010 | US-041 | K2,K6 | P4 |
| UC-011 | US-042 | K2,K6 | P4 |
| UC-012 | US-024,025,027,028 | K8,K1 | P3 |
| UC-013 | US-005,018 | K1 (consistency) | P4 |
| UC-014 | US-022 | K1 (deliberate purge) | P5 |
| UC-015 | US-036,038 | K5 | P6 |

## Open Questions

- **OQ-05.1** Command surface for rollback/purge/report: flags on `clean` vs first-class
  subcommands (`cleaner rollback`, `cleaner staging purge`, `cleaner report`). This spec
  assumes first-class subcommands; spec 08 is authoritative. *Leaning: subcommands.*
- **OQ-05.2** In UC-004/UC-008, does a partial-permission analyze exit `0` (with "unmeasured"
  notes) or `4`? Decide the exact rule in spec 23. *Leaning: `0` for analyze if it produced
  useful output, `4` only when access is strictly required for the requested action.*
- **OQ-05.3** UC-007 E1 (original path occupied on rollback): restore-beside vs prompt vs skip.
  Finalize in spec 21. *Leaning: never overwrite; restore-beside with a clear note, count as
  partial (exit 3).*
- **OQ-05.4** UC-010 retained-copy selection rule (which duplicate to keep) — needs a precise,
  deterministic default in the duplicate plugin spec (`specs/plugins/`).
- **OQ-05.5** UC-014 staging retention TTL and any auto-purge: opt-in only; define defaults and
  config keys in spec 21/24. *Leaning: no auto-purge by default.*

## Dependencies

**Consumes:** 00-constitution (Article 4 risk/confirmation rules, Article 5 protected paths,
Article 7 exit codes, Article 8 layout, principles 1/2/5/6/8/10), 01-product-vision (KPIs),
03-personas (actors), 04-user-stories (each UC elaborates specific US-###).

**Feeds:** 06-functional-requirements (FRs trace through these UCs; § 2 preview),
08-command-reference (concrete commands/flags/exit codes per flow), 20-cleanup-engine and
21-rollback-design (main/exception flows for stage/rollback/purge), 23-permission-model
(UC-008/UC-012), 31-testing-strategy (each flow becomes an acceptance/integration test).
