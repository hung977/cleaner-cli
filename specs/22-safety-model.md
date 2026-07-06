# 22 — Safety Model

> **Phase E · Depends on:** 00-constitution (Articles 1, 4, 5, 7 exit codes), 10-tech-stack,
> 14-domain-model (`Recoverability`, `Disposition`, `Finding`, `Evidence`, `CleanPlan`,
> `ConfirmationState`), 16-filesystem-strategy (canonicalization, allow/deny enforcement,
> TOCTOU-safe mutation, dataless/snapshot rules) ·
> **Depended on by:** 17 (scan), 18 (rules), 19 (detection), 20 (cleanup), 21 (rollback),
> 23 (permissions), 25 (TUI surfacing), 26 (CLI UX), 27 (errors), 28 (audit), 35 (security
> review), 36 (threat model), 39 (risk register).

## 1. Purpose & scope

This is **the most important specification in the suite**. Constitution Principle 1 ("safety
over savings") and Principle 2 ("reversibility by default") are ranked above every other
concern; this spec is where those principles become an enforceable, testable mechanism.

**As-built note (v0.6).** Earlier drafts governed cleaning with a three-tier *risk system*
(🟢/🟡/🔴) and a weighted `SafetyScorer` that decided what could be auto-selected. That machinery
has been **removed from the product**: there are no user-facing Safe/Medium/Dangerous tiers, no
risk icons, no `--all`, no risk-based default selection, and nothing is "never auto-cleaned"
because it scored dangerous. The `RiskLevel`, `SafetyScore`, and `SafetyScorer` types still exist
in the domain/engine code as **vestigial internal metadata** (a plugin may still attach a risk),
but they **do not gate selection, cleaning, or display** — see § 10. This spec now defines safety
as **three concrete guarantees** rather than a scoring model.

The safety of cleaner-cli rests on **three guarantees**:

1. **You choose** (§ 4). Nothing is removed without explicit consent. After a scan, `cleaner`
   asks `Clean all X? [Y = all · s = select each · n = cancel]`; `--yes` cleans everything for
   automation; `--dry-run` changes nothing.
2. **Everything is recoverable** (§ 5). The default disposition is move-to-staging under
   `~/.cleaner/staging/`; `cleaner undo` restores byte-for-byte. Even the Trash is *staged*, not
   purged.
3. **Protected paths can never be touched** (§ 6). The engine's `ProtectedPathGuard` refuses,
   independently of any plugin, to act on system and user-content locations, credential material,
   snapshots, and the tool's own directories — via `allow ∩ roots − deny`.

Supporting these are the **execute-time re-validation** (TOCTOU close-out, § 7), the **exit-code
contract** (§ 8), and **truthful surfacing** (§ 9).

Every normative safety requirement in this spec carries an `SR-###` id. `SR-###` ids are the
anchor that the Threat Model (spec 36) and Security Review (spec 35) mitigations cross-reference.
Where a requirement described the removed risk tiers, its id is retained and reworded to the new
model, or explicitly marked removed, so cross-references do not dangle.

**Design axiom.** *Plugins advise; the engine decides.* No plugin can widen what is deletable,
bypass a confirmation, or reach a protected path. Every safety decision is re-derivable from
recorded `Evidence` and re-checked at the last possible moment against the live filesystem.

## 2. Threat-to-requirement framing

The safety model defends against two distinct failure families, both of which end in the
existential failure — **irreversible loss of data the user needed** (see RISK-001 in spec 39):

- **F1 — False positive:** the tool proposes something as junk that is not (a plugin bug, a
  crafted repository, an ambiguous path, a stale heuristic).
- **F2 — Escape / confused deputy:** an action that *was* correctly scoped is redirected to a
  different target between decision and execution (symlink swap, path race, protected-path
  smuggling, a plugin returning an out-of-root path).

The v0.6 model defeats **F1** not by scoring an item's danger but by (a) requiring **explicit
consent** for every removal (§ 4) and (b) making every removal **reversible** by default (§ 5), so
a wrong proposal is a recoverable inconvenience, never data loss. The engine invariants and
protected-path algebra (§ 6) plus the TOCTOU close-out (§ 7) defend against **F2**. The model is
layered so that no single bug is sufficient (defense in depth).

## 3. What a `Finding` carries (and what no longer gates)

A `Finding` (spec 14 § 4.9) still records an `Item`, the producing plugin, a `Category`, a
`Recoverability`, a human `rationale`, and the reclaim estimate. It also still carries a
vestigial `risk`/`safetyScore` (§ 10). **None of these fields select, order, gate, or colour a
finding in v0.6.** Selection is entirely **user-driven** (§ 4). The engine's only hard safety
inputs are:

- **`Recoverability`** — informational; the default disposition is always `.stage` (§ 5), so every
  actioned item is recoverable regardless of its content-level recoverability class.
- **`isProtected` / the `ProtectedPathGuard` decision** — the single hard gate (§ 6). A protected
  path is never actionable, independent of any plugin or metadata.

`Category` (spec 14 § 4.6) remains a **taxonomy for presentation and bulk selection**, never a
safety authority. **SR-011** The engine MUST NOT treat any plugin-supplied label (category or
vestigial risk) as authorization to act; the `ProtectedPathGuard` (§ 6) and the consent flow
(§ 4) are the only authorities.

## 4. Guarantee 1 — You choose (preview → confirm → execute)

Constitution Principle 1: every destructive action is *preview-first, confirm-second,
execute-third*. In v0.6 the confirmation is **uniform** (no per-item risk escalation); the user
decides at the granularity they want.

### 4.1 Preview (always)

- **SR-044** No disposition executes before a **preview** is produced: the `ScanResult`'s
  `Finding`s grouped by source, with rationale, recoverability, and per-source and total reclaim
  (on-disk, shared-block-corrected; spec 14 § 6). In non-interactive/JSON mode the preview is the
  emitted plan; in the interactive flow it is the list the user confirms or selects over. Dry-run
  and real-run use identical measurement code (Principle 3, DM-9).

### 4.2 The confirmation contract

After the preview, the interactive `clean` flow asks a single question:

```
Clean all <reclaim>? [Y = all · s = select each · n = cancel]
```

- **`Y` / Enter** → clean everything found.
- **`s`** → per-source prompt `clean? [y/N]` for each source; only sources the user answers `y`
  are cleaned.
- **`n` / Ctrl-C / `q`** → cancel; nothing is touched (exit code 5).

- **SR-045** Nothing is removed without **explicit consent** obtained through this flow (or the
  non-interactive equivalents below). There is no pre-selected, silently-cleaned set. *(Reworded
  from the removed "🔴 never pre-selected" rule: in v0.6 nothing is pre-selected at all — the
  user always opts in.)*
- **SR-046** A `CleanPlan` records how consent was obtained on each `PlannedAction` via
  `ConfirmationState` (spec 14 § 4.13: `.explicitInteractive` for per-source selection,
  `.preselected` for a bulk "clean all", `.automationPolicy`/`--yes` for automation). The cleanup
  engine refuses to execute an action whose consent is unrecorded.

### 4.3 Non-interactive consent

- **SR-057** `--yes` grants non-interactive consent to clean **everything found** (for scripts and
  CI); it is the automation equivalent of answering `Y`. It does not skip any of the § 5–§ 7
  guarantees: staging is still the default, the `ProtectedPathGuard` still applies, and
  execute-time re-validation still runs. *(Reworded: `--yes` no longer authorizes "only 🟢"; there
  are no tiers. It authorizes the scanned set, minus anything the guard blocks.)*
- **SR-051** In a **non-TTY** context with no `--yes` (e.g. piped, CI without consent), the tool
  cannot obtain interactive consent and therefore **cleans nothing**; it prints guidance to re-run
  with `--yes` and exits without acting. *(Reworded from the removed "🔴 cannot be typed-confirmed"
  rule.)*
- **SR-058** A signed automation policy (spec 23) may pre-authorize a specific, enumerated set of
  plugins/categories/paths. It sets `ConfirmationState.automationPolicy`, and the cleanup engine
  still applies every § 6 invariant and § 7 re-validation. *(Reworded: policies no longer carry a
  per-risk-tier authorization matrix.)*
- **SR-059** Automation never escalates disposition: a policy or `--yes` authorizes `.stage`
  (default) / `.trash`; reaching `.purge` still requires the explicit escalation in § 5.3, even
  under automation.
- **SR-060** `--yes` and policy consent are **recorded in the audit log** (spec 28) with the exact
  set of authorized findings, so consent is reconstructable after the fact (Principle 8).

### 4.4 Dry-run

- **SR-047** `--dry-run` produces the full preview and plan and **changes nothing on disk**. It
  uses the identical measurement code as a real run (Principle 3, DM-9), so the reported reclaim is
  the reclaim a real run would achieve. *(Reworded from the removed "execute ordered safe→risky":
  there is no risk ordering; dry-run vs real is the distinction that matters.)*
- **SR-048** Every executed action passes the **execute-time re-validation** (§ 7) immediately
  before the syscall. Passing at plan time is necessary but not sufficient.

*(Requirements SR-049 and SR-050 — typed-`delete` confirmation and per-🔴-batch escalation — are
**removed with the risk tiers**. v0.6 has no typed-token gate; consent is the uniform Y/s/n flow
above, and reversibility (§ 5) — not extra friction — is what protects the user from a wrong
proposal. The ids are retired to avoid re-use.)*

## 5. Guarantee 2 — Everything is recoverable (staging by default)

### 5.1 Staging is the universal default (Principle 2, CC-7)

- **SR-052** The **default `Disposition` is `.stage`** for every actioned item (spec 14 § 4.5).
  Staging moves the item into the session staging tree under `~/.cleaner/staging/<session>/`
  (spec 15) via atomic same-volume `rename` where possible (spec 16 § 11), capturing full restore
  metadata (owner/mode/ACL/xattrs/flags/timestamps/symlink target) **before** the move.
- **SR-053** Nothing is `unlink()`-ed outright when a recoverable path exists. `.purge` is an
  explicit escalation, never a default and never selected by a plugin or the planner.
- **SR-053a** Even the macOS Trash cleaner **stages** rather than empties: the Trash plugin uses
  disposition `.stage` (not `.purge`), so "cleaning the Trash" is itself reversible via
  `cleaner undo` until the staging session is purged. The tool never empties the Trash
  irreversibly on the user's behalf.

### 5.2 Undo

- **SR-054** `cleaner undo` restores staged items **byte-for-byte** to their original paths,
  replaying the captured restore metadata. `cleaner undo --list` shows recoverable staged sessions
  by id; `cleaner undo <id>` restores a specific session. Restore is available until the staging
  session is explicitly purged (spec 21).

### 5.3 Escalation to permanent deletion

- **SR-055** `.purge` (permanent) is reachable only via: (a) purging **already-staged** items
  through an explicit purge/cleanup of the staging area, or (b) `--no-stage` **with** consent
  (interactive confirmation, or an automation policy that explicitly grants `--no-stage`). There is
  no other path to irreversible deletion (DM-5).
- **SR-056** `--no-stage` composes with, and never bypasses, the `ProtectedPathGuard` (§ 6) and the
  execute-time re-validation (§ 7). Turning off staging turns off *reversibility*, not the
  protected-path or TOCTOU guarantees.

*(The `Recoverability` classes — `.instant`/`.manual`/`.hard`/`.none` — are retained on `Finding`
as descriptive metadata for the "why" text and reports. Because staging overlays instant tool-level
rollback on **every** actioned item, an item's content-level recoverability no longer changes
whether or how it is cleaned. `Recoverability.none` still exists in the model but no longer forces a
risk tier, because tiers are gone.)*

## 6. Guarantee 3 — Protected paths can never be touched (ProtectedPathGuard)

This is the **one hard gate** in v0.6, enforced **in the engine** (`ProtectedPathGuard`,
`CleanerPlatform`), *not* delegated to plugins, and re-checked at execute time (§ 7). It fires even
if a plugin, the planner, and the user all agreed.

### 6.1 The three sets

- **`allowedRoots`** — the union of every enabled plugin's declared roots, resolved and normalized.
  A candidate path must be **within** one of these to be actionable.
- **`denyList`** — the compiled-in, non-overridable protected set (Constitution Article 5):
  `/System`, `/bin`, `/sbin`, `/private/var/db`, `/usr` (with `/usr/local` re-admitted only via an
  `allowedRoots` declaration, never by the deny check), the system `/Library`, the `.app` bundles
  under `/Applications`, `/.vol`, `/cores`; the user-content roots `~/Documents`, `~/Desktop`,
  `~/Pictures`, `~/Movies`, `~/Music`; the credential roots `~/.ssh`, `~/.gnupg`, `~/.aws`,
  `~/.config/gcloud`, `~/Library/Keychains`; and the tool's own home `~/.cleaner`
  (staging/config/logs/audit).
- **Volume/mount roots** — `/`, an empty path, and `/Volumes/<Name>` mount roots are refused
  outright (paths *inside* an external volume are allowed).
- **Sensitive suffixes** — files that look like key/credential material are refused by name:
  `id_rsa`, `id_ed25519`, `id_dsa`, and any `*.key`, `*.pem`, `*.p12`, `*.keychain`,
  `*.keychain-db`.

### 6.2 The algorithm

```
validateForDeletion(path, allowedRoots) :=
    p := normalize(path)                        // tilde-expanded, `..`-resolved, trailing-slash-stripped
    if isRootOrVolume(p)          → BLOCKED  ("volume root or /")
    if p is within any denyList   → BLOCKED  ("under a protected location")
    if hasSensitiveSuffix(p)      → BLOCKED  ("credential/key material")
    if p is NOT within any allowedRoot → BLOCKED  ("outside every allowed plugin root")
    else                          → ALLOWED
```

`isWithin(path, prefix)` uses **component-boundary** matching: `path == prefix`, or `path` begins
with `prefix + "/"` (so `~/.sshx` does **not** match `~/.ssh`, and `/usr/localx` does **not** match
`/usr/local`). Matching is never a raw string `hasPrefix` on unnormalized paths.

- **SR-033** *Never delete outside the allow-space.* Every candidate action path must be within
  some `allowedRoot` and not under the deny-list. Enforced at plan build **and** at execute time.
  A violation blocks that item (`ActionResult.blockedBySafety`, exit code 8).
- **SR-034** *Never delete a protected path* (Article 5 deny-list). A protected path never yields
  a `PlannedAction` (`Finding.isProtected == true`, DM-4).
- **SR-035** *Never follow a symlink out of an allowed root to delete the target.* Normalization
  resolves `..` and tilde; disposition operates on the resolved path, and the resolved path is
  re-checked against the guard before action.
- **SR-036** *Never delete a currently-open/locked/immutable file* without an explicit override
  (`--force-locked`), re-checked at execute time (spec 20).
- **SR-037** *Never purge without staging first,* unless `--no-stage` **and** consent (SR-055).
  `.purge` is unreachable as a default (DM-5).
- **SR-038** *Refuse to operate on a mount root, a system/read-only volume, or `/`* (`isRootOrVolume`
  above; DiskArbitration `VolumeInfo` at execute time, spec 16 § 7). Violation ⇒ exit code 8.

### 6.3 Non-overridability and precedence

- **SR-040** The set algebra is computed on **normalized** paths and applied to the target (and, at
  execute time, re-derived on the live path). A `..` or symlink component cannot smuggle a path past
  the check.
- **SR-041** Plugin roots are resolved from declared anchors; a plugin cannot declare a root that
  lands in the deny-list — the intersection can never widen the allow-space.
- **SR-042** The deny-list is **compiled in and non-overridable** except by a signed policy file
  (spec 23) naming a specific path with explicit acknowledgement; even then the absolute roots
  (`/`, `/System`, system volume, snapshots, keychains, private-key material) are **never**
  unlockable. **Deny always wins.**
- **SR-043** User `extraProtected` entries (spec 14 § 4.16) are **added** to the deny-list for that
  session; user `extraTargets` are added to `allowedRoots` **only after** passing the same
  guard (a user target rule can never point into the deny-list).

### 6.4 Result

A path failing `validateForDeletion` produces a **display-only** `Finding` with
`isProtected == true` (shown so the user understands why the tool won't touch it) and **no**
`PlannedAction` (DM-4). An action somehow reaching execute time against such a path aborts with
`ActionResult.blockedBySafety` and exit code 8 (`safety`).

- **SR-039** Each guard invariant has a **dedicated test** (spec 31 / `ProtectedPathGuardTests`,
  `SafetyGateTests`) that attempts the violation through the *public* plan/execute API and asserts
  the engine blocks it with the right exit code. Defense in depth is only real if it is tested at
  the boundary.

## 7. Safety re-validation at cleanup time (TOCTOU close-out)

The scan→confirm→execute pipeline spans time; the filesystem can change under it. The engine
re-derives safety **immediately before each mutating syscall**.

- **SR-061** Before disposing of an item, the cleanup engine re-checks the live target:
  1. **Existence/identity** — the path may have vanished or changed since the scan; a drifted or
     missing target is skipped and reported, never acted on blindly.
  2. **Protected-path** — the live path is re-run through `ProtectedPathGuard.validateForDeletion`
     (§ 6). Passing at plan time is not sufficient.
  3. **Volume** — still not a system/read-only volume / mount root (SR-038).
  4. **In-use** — re-check open/locked/immutable state (SR-036).
- **SR-062** Any re-validation failure yields `ActionResult.blockedBySafety` (exit 8) for that item
  and does **not** abort the whole run; other items proceed, and the report lists the block
  (Principle 3). The run's overall exit is `partial` (3) if some items failed/blocked while others
  succeeded.
- **SR-063** Actual on-disk size is **measured at execute time** (spec 20) so the reported reclaim
  reflects what was really freed, not a stale scan estimate.
- **SR-064** A large **estimate-vs-actual reclaim gap** discovered during execution (measured delta
  vs `projectedReclaim` beyond a tolerance — **10%** relative or 100 MB absolute, whichever is
  larger) is surfaced in the report, not hidden (spec 14 § 6). This detects clone/hardlink
  mis-accounting after the fact.

## 8. Exit-code contract (safety-relevant)

The tool's exit codes (Constitution Article 7) let scripts distinguish a safe no-op from a real
problem:

| Code | Name | Meaning |
|---|---|---|
| 0 | `ok` | Completed; requested work done. |
| 2 | `usage` | Bad invocation. |
| 3 | `partial` | Some items skipped/failed/blocked while others succeeded. |
| 4 | `permission` | Needed access (Full Disk Access / admin) not granted. |
| 5 | `cancelled` | User cancelled (`n`/Ctrl-C/`q`) or timed out. |
| 6 | `config` | Invalid configuration. |
| 7 | `plugin` | A plugin failed to load or violated its contract. |
| **8** | **`safety`** | **Aborted by a safety invariant — a protected path or volume was blocked.** |
| 10 | `precondition` | Environment unmet (unsupported OS, no TTY where required). |
| 11 | `entitlement` | Pro-only feature invoked without a valid license. |

- **SR-062a** A `ProtectedPathGuard` block (§ 6) or execute-time re-validation failure (§ 7) is
  reported as `ActionResult.blockedBySafety` and drives exit code **8** (`safety`) when it is the
  dominant outcome, or contributes to exit **3** (`partial`) when mixed with successes.

## 9. Surfacing (UI / CLI / JSON)

- **SR-065** Every `Finding` surfaces its **source/category, rationale, recoverability, and reclaim
  (on-disk, shared-block-corrected)** in all presentation modes: the interactive list, plain CLI,
  and JSON (`--json`). The renderer does **not** colour or icon findings by risk — there are no
  🟢/🟡/🔴 markers. *(Reworded from the removed "surface RiskLevel.icon and SafetyScore".)*
- **SR-066** A "**why**" explanation is available per finding: the `rationale` string plus the
  `Evidence` basis. The audit log records it for every actioned item (spec 28). "Why did you (want
  to) delete this?" always has an answer (Principle 8).
- **SR-067** The JSON export is a stable, versioned contract (spec 15). It reports the finding's
  reclaim, recoverability, rationale, and `protected` flag. `risk`/`score` may still appear as
  **internal, non-authoritative** fields (§ 10) but MUST NOT be relied on by consumers for
  selection semantics.
- **SR-068** Totals surface **counts and reclaim per source/category** so the user sees, before
  confirming, how much each source represents. There is no per-risk-tier breakdown.
  *(`ScanTotals.byRisk` may still be populated from vestigial metadata but is not shown as a safety
  affordance.)*
- **SR-069** The tool **never overstates** what it did: dry-run reports what a real run would free
  (same measurement code), and the report surfaces any estimate-vs-actual gap (SR-064). Truth in
  reporting is preserved without a confidence-of-risk-judgment claim.

## 10. Vestigial risk metadata (retained, non-governing)

`RiskLevel`, `SafetyScore`, and the weighted `SafetyScorer` remain in the codebase but are **not
part of the v0.6 product**:

- **`RiskLevel` / `SafetyScore` (spec 14 § 4.2/§ 4.3).** Still defined; a `Finding` still carries a
  `risk` and `safetyScore`, and a plugin may attach a (tightened) risk. These are **internal
  metadata** only — they do **not** drive selection, ordering, confirmation strength, disposition,
  gating, or display.
- **`SafetyScorer` (engine).** The old six-signal weighted scorer with its fixed weights, gates,
  and score→risk mapping **still compiles but is not invoked by the scan/clean flow**. It is
  retained for reference and potential future reuse, not as a governing mechanism. The former § 3
  risk criteria (🟢/🟡/🔴), the § 4 weights/formula/signals/gates table, and the worked scoring
  examples are **removed** as normative content.
- **SR-012** (scorer determinism) and the former SR-001…SR-032 (risk criteria, signals, weights,
  gates, mapping) are **retired as governing requirements**. They no longer bind behavior because
  no risk tier gates cleaning. Their ids are not re-used.
- **Rationale for keeping the types.** Removing them would ripple through `Finding`, JSON schemas,
  and plugin signatures; keeping them as inert metadata is lower-risk than a wide type change. The
  contract is simply that **nothing in the cleaning path reads them for a decision** — enforced by
  the fact that selection is user-driven (§ 4) and the only hard gate is the `ProtectedPathGuard`
  (§ 6).

## 11. Decision table (path × consent → action)

Selection is user-driven; the governing dimensions are the protected-path decision and how consent
was obtained.

| `isProtected` | Consent context | Confirmation | Default disposition | Executes? |
|---|---|---|---|---|
| false | interactive, `Y` | bulk "clean all" | `.stage` | Yes |
| false | interactive, `s` | per-source `y/N` | `.stage` | Only selected sources |
| false | interactive, `n`/Ctrl-C | — | — | **No** (exit 5) |
| false | `--yes` | consent given | `.stage` | Yes |
| false | signed policy | policy | `.stage` | Yes (policy-named set) |
| false | non-TTY, no `--yes` | impossible | — | **No** (prints guidance) |
| false | `--dry-run` | — | (measured only) | **No** (nothing changes) |
| false | `.purge`/`--no-stage` requested | consent (+ policy names it for automation) | `.purge` | Only with escalation (§ 5.3) |
| **true** | any | — | — | **Never** (display-only; exit 8 if attempted) |
| (mount/system volume) | any | — | — | **Never** (exit 8) |

## 12. Enforcement & traceability map

| SR range | Concern | Primarily enforced in | Tested by (spec 31) |
|---|---|---|---|
| SR-011 | Labels are not authority | Engine (17/22) | guard + flow tests |
| SR-033…039 | Hard invariants / ProtectedPathGuard | `ProtectedPathGuard`, engine (18/20) | `ProtectedPathGuardTests`, `SafetyGateTests` |
| SR-040…043 | Protected-path algebra (Article 5) | `ProtectedPathGuard` (platform/18) | path-algebra + fuzz tests |
| SR-044…048 | Preview / consent (Y/s/n, `--yes`, `--dry-run`) | Cleanup + CLI (20/26) | confirmation-flow tests |
| SR-051…060 | Consent contexts (non-TTY, `--yes`, policy) | CLI + policy (23/26) | automation-policy tests |
| SR-052…056 | Staging default + undo + purge escalation | Cleanup + staging (20/21) | `StagingTests`, disposition-guard tests |
| SR-061…064 | TOCTOU execute-time re-validation | Cleanup + FS (16/20) | `EngineTests`, race/identity-drift tests |
| SR-065…069 | Truthful surfacing (UI/CLI/JSON) | CLI/report (26/15) | snapshot + JSON-schema tests |
| SR-012, SR-001…032 | **Retired** (removed risk tiers/scorer) | n/a | n/a |

- **SR-070** Every *live* `SR-###` in this spec MUST trace to at least one automated test (spec 31)
  and at least one owning module (spec 12). A safety requirement with no test is a defect
  (Constitution Article 11). Retired ids are exempt.

## Open Questions

- **OQ-22.1** Should the vestigial `RiskLevel`/`SafetyScore`/`SafetyScorer` types be **removed
  entirely** in a future breaking release, or kept as inert metadata indefinitely? *Leaning: keep
  as inert metadata until a schema-version bump makes removal cheap; the invariant is only that the
  cleaning path never reads them (§ 10).*
- **OQ-22.2** Should `select each` (`s`) offer **per-item** selection in addition to per-source, for
  users who want finer control? *Leaning: per-source for v0.6; per-item is a TUI enhancement (spec
  25).*
- **OQ-22.3** Should `--no-stage` be gated behind an extra typed confirmation given that it removes
  the reversibility guarantee? *Leaning: keep it a plain flag but require it to be named explicitly
  in automation policies (SR-059).*
- **OQ-22.4** Should the estimate-vs-actual tolerance (SR-064) be per-category rather than a fixed
  global 10% / 100 MB? *Leaning: fixed global for now; revisit with field data.*
- **OQ-22.5** Should the sensitive-suffix deny (§ 6.1) be extended (e.g. `*.p8`, `*.pfx`,
  `.env` files)? *Leaning: yes, additively, since deny-list additions can only tighten.*

## Dependencies

**Consumes:** 00-constitution (Article 1 principles ranking, Article 4.4 hard invariants, Article 5
protected paths, Article 7 exit codes 5/8), 10-tech-stack (Swift 6 `Sendable` value types),
14-domain-model (`Recoverability`, `Disposition`, `Finding`, `PlannedAction`, `ConfirmationState`,
`ScanResult`, reclaim/shared-block accounting DM-4/5/8/9), 16-filesystem-strategy (canonicalization,
allow/deny enforcement, TOCTOU-safe mutation, dataless/snapshot/symlink rules, `VolumeInfo`).

**Feeds:** 17-scan-engine (marks `isProtected`), 18-rule-engine (`allowedRoots ∩ − denyList`
algebra, `extraProtected`/`extraTargets`), 19-detection (supplies `Evidence` for rationale),
20-cleanup-engine (consent flow, staging default, execute-time re-validation, purge escalation),
21-rollback-design (staging + `undo`), 23-permission-model (automation policies SR-058),
25-tui-design (source/category surfacing, no risk colouring), 26-cli-ux (plain + JSON surfacing,
`--yes`/`--dry-run`/`--no-stage`), 27-error-handling (exit codes 5/8), 28-logging (audit of consent
and outcomes), 35-security-review (SR-### mitigation map), 36-threat-model (THR-### ↔ SR-###
cross-refs), 39-risk-register (RISK-001 data-loss mitigation chain).
