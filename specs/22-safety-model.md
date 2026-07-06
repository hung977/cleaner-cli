# 22 — Safety Model

> **Phase E · Depends on:** 00-constitution (Articles 1, 4, 5, 7 exit codes), 10-tech-stack,
> 14-domain-model (`RiskLevel`, `SafetyScore`, `Recoverability`, `Disposition`, `Finding`,
> `Evidence`, `CleanPlan`, `ConfirmationState`), 16-filesystem-strategy (canonicalization,
> allow/deny enforcement, TOCTOU-safe mutation, dataless/snapshot rules) ·
> **Depended on by:** 17 (scan), 18 (rules), 19 (detection), 20 (cleanup), 21 (rollback),
> 23 (permissions), 25 (TUI surfacing), 26 (CLI UX), 27 (errors), 28 (audit), 35 (security
> review), 36 (threat model), 39 (risk register).

## 1. Purpose & scope

This is **the most important specification in the suite**. Constitution Principle 1 ("safety
over savings") and Principle 2 ("reversibility by default") are ranked above every other
concern; this spec is where those principles become an enforceable, testable mechanism.

It fully specifies:

1. The three-level **risk system** (🟢/🟡/🔴) with concrete, checkable criteria (§ 3).
2. The **SafetyScorer** — the exact weighted-signal model, weights, formula, gates, and the
   score→risk mapping (§ 4), with worked examples (§ 5).
3. The **hard invariants** (Constitution Article 4.4) and how the *engine* enforces them
   independently of plugins — defense in depth (§ 6).
4. **Protected-path enforcement** (Constitution Article 5): the intersection/subtraction
   algorithm (§ 7).
5. The **preview → confirm → execute** contract per risk level, including typed confirmation
   for 🔴 (§ 8).
6. **Staging-by-default**, recoverability classes, and how permanent deletion is escalated (§ 9).
7. How **`--yes` and automation policies** interact with risk (never auto-🔴) (§ 10).
8. **Safety re-validation at cleanup time** (TOCTOU close-out) (§ 11).
9. How **safety score and risk surface** in the TUI, plain CLI, and JSON (§ 12).
10. A **decision table** (§ 13) and the **enforcement/traceability map** (§ 14).

Every normative safety requirement in this spec carries an `SR-###` id. `SR-###` ids are the
anchor that the Threat Model (spec 36) and Security Review (spec 35) mitigations cross-reference.

**Design axiom.** *Plugins advise; the engine decides.* No plugin can widen what is deletable,
raise a safety score above the shared ceiling, bypass a confirmation, or reach a protected path.
Every safety decision is re-derivable from recorded `Evidence` and re-checked at the last
possible moment against the live filesystem.

## 2. Threat-to-requirement framing

The safety model defends against two distinct failure families, both of which end in the
existential failure — **irreversible loss of data the user needed** (see RISK-001 in spec 39):

- **F1 — False positive:** the tool classifies something as junk that is not (a plugin bug,
  a crafted repository, an ambiguous path, a stale heuristic).
- **F2 — Escape / confused deputy:** an action that *was* correctly scoped is redirected to a
  different target between decision and execution (symlink swap, path race, protected-path
  smuggling, a plugin returning an out-of-root path).

The scorer (§ 4) and the risk gates (§ 8, § 10) primarily defend against **F1**. The engine
invariants (§ 6), protected-path algebra (§ 7), and TOCTOU close-out (§ 11) defend against
**F2**. Both families must be defeated for a byte to be lost wrongly; the model is layered so
that no single bug is sufficient (defense in depth).

## 3. Risk levels — concrete criteria

Risk levels are the `RiskLevel` enum (spec 14 § 4.2): `.safe` 🟢, `.medium` 🟡, `.dangerous`
🔴. Constitution Article 4.1 fixes their meaning and default behavior; this section makes the
boundaries **checkable** so two engineers classifying the same item agree.

The authoritative risk of a `Finding` is `SafetyScore.riskLevel` (spec 14 § 4.3 mapping:
`≥85 → safe`, `50–84 → medium`, `<50 → dangerous`), subject to the gates in § 4.5 and the
plugin-may-only-tighten rule (DM-2/DM-3). The criteria below are the qualitative contract the
scorer is calibrated to reproduce.

### 3.1 🟢 Safe (score ≥ 85)

An item is Safe **only if all** hold:

- **SR-001** Content is **automatically regenerated** by a tool/OS as a side effect of normal
  use (build caches, module caches, thumbnail caches, compiled artifacts, log files, download
  staging), *not* fetched-once-and-kept user data.
- **SR-002** Contains **no user-authored content**: no source files, documents, keys, media, or
  configuration the user would hand-edit. Evidence signals: no Finder tags, no `whereFroms`
  pointing to user-shared origins, Spotlight `kMDItemKind` not a document type, path is under a
  known cache/derived anchor.
- **SR-003** `Recoverability` is `.instant` or `.manual` (regeneration is free or cheap).
- **SR-004** The path resolves with **high path confidence** (§ 4.4) inside a plugin-declared
  cache/derived root that survives the allow∩roots−deny check (§ 7).
- **SR-005** The item is **not open, locked, immutable, or dataless** at scan time.

Loss of a Safe item is *invisible*: the user cannot tell it was removed except that some later
operation transparently regenerates it.

### 3.2 🟡 Medium (score 50–84)

Regenerated but **costs time or bandwidth** to restore, OR one Safe criterion is only weakly
supported:

- **SR-006** Regeneration requires a re-download, re-index, re-build, or re-provision (package
  caches that must be re-fetched, Spotlight indexes, simulator runtimes, Docker layer caches,
  derived data for an *active* project the user will rebuild soon).
- **SR-007** OR path confidence is only *medium* (heuristic match, ambiguous anchor), OR
  last-access recency is recent enough that the item may be part of an active workflow.
- **SR-008** `Recoverability` is `.manual` or `.hard`. It is never `.none` (that forces 🔴).

Medium items are **shown but never pre-selected** and are **skipped under `--yes`** unless the
user explicitly opts in with `--include medium` (Constitution Article 4.1).

### 3.3 🔴 Dangerous (score < 50)

Could contain **irreplaceable data** or breaking a tool if the classification is wrong:

- **SR-009** Any of: user-authored content *may* be present; `Recoverability == .none`
  (irreversible external source); path confidence is *low*; the item straddles or is adjacent to
  a user content root; the item is a whole app bundle, a VM/disk image with unknown contents, a
  mail store, a database, or a credential store.
- **SR-010** `Recoverability == .none` **always** yields 🔴 regardless of other signals
  (Constitution Article 4.3, DM-1). The scorer caps the score at 49 in this case (§ 4.5).

Dangerous items are **shown, never pre-selected, and require typed confirmation** (§ 8.4). They
are **never auto-cleaned** under `--yes` or any automation policy (§ 10, SR-045).

### 3.4 Category is not authority

`Category.defaultRisk` (spec 14 § 4.6) seeds a plugin's baseline but is **advisory**. The
per-`Finding` `RiskLevel`/`SafetyScore` govern. **SR-011** The engine MUST compute risk from the
scorer over recorded `Evidence`; it MUST NOT trust a category label alone to authorize an action.

## 4. The SafetyScorer

### 4.1 Role and boundary

The `SafetyScorer` is an engine-owned, plugin-independent component (module boundary in spec 12,
under `CleanerCore`). It consumes a `Finding`'s `Item` + `Evidence` (spec 14) plus the
protected-path decision (§ 7) and produces a `SafetyScore` (0–100) and the derived `RiskLevel`.

```swift
protocol SafetyScoring: Sendable {
    /// Pure, deterministic, side-effect-free. Same Evidence ⇒ same score (Principle 5).
    func score(item: Item, evidence: Evidence, pathConfidence: PathConfidence,
               pluginHint: SafetyScore?) -> ScoredSafety
}

struct ScoredSafety: Sendable, Hashable {
    let score: SafetyScore          // 0…100, post-gates
    let risk: RiskLevel             // == score.riskLevel (§ 3), never looser than pluginHint
    let signals: [SignalContribution]  // per-signal breakdown for audit/UI "why" (§ 12)
    let appliedGates: [SafetyGate]  // which caps fired (recorded for audit)
}

struct SignalContribution: Sendable, Hashable {
    let signal: SafetySignal        // .regenerability, .userAuthored, …
    let subscore: Double            // 0.0…1.0
    let weight: Double              // fixed weight (§ 4.3)
    let points: Double              // subscore × weight × 100 (contribution to the total)
    let basis: String               // human-readable evidence citation, e.g. "under DerivedData; mtime 41d"
}
```

- **SR-012** The scorer MUST be **pure and deterministic**: identical `Evidence` and
  `PathConfidence` MUST yield an identical `SafetyScore` (Constitution Principle 5). No
  wall-clock, RNG, or ambient state. Recency signals derive from `Evidence` timestamps versus a
  single session-fixed `now` captured once per `Session` (spec 14 § 4.15), passed in, not read
  ad hoc.
- **SR-013** The scorer is the **single source** of the score→risk mapping (spec 14 § 4.3). No
  other component re-implements the mapping.

### 4.2 Signals

Six weighted signals, each normalized to a subscore in `[0.0, 1.0]` (1.0 = maximally safe).

| Signal | `SafetySignal` | Meaning (1.0 = safe end) | Primary `Evidence` inputs |
|---|---|---|---|
| Regenerability | `.regenerability` | Content is auto-regenerated at no user cost | anchor kind, `whereFroms`, Launch Services, `spotlightKind` |
| User-authored absence | `.userAuthored` | *No* user-authored content present | `finderTags`, `spotlightKind`, `whereFroms`, path anchor, extension |
| Recoverability | `.recoverability` | How reversible removal is | `Recoverability` class + staging availability |
| Path confidence | `.pathConfidence` | Path is provably what the plugin claims | canonical path vs declared root, glob specificity, symlink status |
| Last-access recency | `.recency` | Item is stale / unused | `lastUsedDate` (preferred), `atime` (lower-bound), `mtime` |
| Lock / in-use | `.lockState` | Item is free (not open/locked/immutable) | `isOpenOrLocked`, BSD flags |

### 4.3 Weights & formula

Fixed weights, summing to 1.00. These are **constants** (calibrated in § 5, tunable only via an
ADR that re-runs the calibration corpus in spec 31):

| Signal | Weight `wᵢ` |
|---|---|
| `.regenerability` | **0.30** |
| `.userAuthored` (absence) | **0.25** |
| `.recoverability` | **0.15** |
| `.pathConfidence` | **0.15** |
| `.recency` | **0.10** |
| `.lockState` | **0.05** |
| **Σ** | **1.00** |

**Base score** (before gates):

```
S_raw = 100 × Σ (wᵢ × sᵢ)      for i in the six signals,  sᵢ ∈ [0,1]
```

- **SR-014** The weights above are the fixed model. Any weight change is a Constitution-adjacent
  change requiring an ADR and a re-run of the calibration corpus (spec 31), because it can move
  items across the 🟢/🟡/🔴 boundaries.
- **SR-015** A signal whose evidence was **not gathered** (`nil`, e.g. permission-gated
  metadata, spec 16 § 5) contributes its **conservative** subscore, not a neutral or optimistic
  one. Missing evidence never *raises* safety (see per-signal rubric defaults in § 4.4). Ungathered
  signals are recorded so the "why" panel (§ 12) shows the score was computed under uncertainty.

### 4.4 Per-signal subscore rubric

Each `sᵢ` is derived by a documented rubric so scoring is reproducible and auditable.

**Regenerability `s_regen`** (weight 0.30):
- `1.0` — under a known auto-regenerated anchor (build/DerivedData/module/thumbnail/log cache),
  or `whereFroms` shows a re-downloadable public artifact, or a Launch Services managed cache.
- `0.6` — regenerated but costly (package cache requiring re-fetch, index, simulator runtime).
- `0.3` — regeneration requires user action with an external dependency (re-clone, re-provision).
- `0.0` — not regenerable / unknown provenance (default when no positive signal). **SR-016** The
  default in the absence of a positive regenerability signal is `0.0`, not a neutral value.

**User-authored absence `s_uac`** (weight 0.25; higher = *less* likely user-authored):
- `1.0` — no `finderTags`, `spotlightKind` is not a document/media type, extension is a known
  cache/temp extension, path is under a cache anchor, no user-origin `whereFroms`.
- `0.5` — mixed/ambiguous signals (e.g. under a project dir that also holds source).
- `0.0` — positive user-authored signals present: Finder tags set, document/media
  `spotlightKind`, source-code extension, or path under (or adjacent to) a user content root.
  **SR-017** *Any* strong user-authored signal (Finder tag present, document/media kind, source
  extension) forces `s_uac = 0.0` **and** triggers the user-authored gate (§ 4.5, SR-024).

**Recoverability `s_recover`** (weight 0.15):
- `.instant` → `1.0` · `.manual` → `0.6` · `.hard` → `0.3` · `.none` → `0.0` (plus the hard gate
  SR-010/SR-023). If staging is unavailable for this volume/item (e.g. `--no-stage`), an
  otherwise-`.instant` item is scored as its underlying class (`.manual`/`.hard`), never
  `.instant`. **SR-018** `s_recover` reflects *actual* achievable recoverability for this run,
  not the theoretical best.

**Path confidence `s_path`** (weight 0.15) — mirrors `PathConfidence` (§ 4.4a):
- `.high` → `1.0` · `.medium` → `0.5` · `.low` → `0.0`.

**Recency `s_recency`** (weight 0.10) — using the strongest available timestamp
(`lastUsedDate` ≫ `mtime` ≫ `atime`-as-lower-bound):
- age ≥ 90d → `1.0` · 30–90d → `0.7` · 7–30d → `0.4` · < 7d → `0.1` · unknown → `0.3`
  (conservative default per SR-015). **SR-019** `atime` alone (under `relatime`/`noatime`) is a
  *lower-bound* hint and MUST NOT push `s_recency` above `0.7`.

**Lock/in-use `s_lock`** (weight 0.05; also a gate):
- not open/locked/immutable → `1.0` · unknown → `0.5` · open/locked/immutable → `0.0`
  (plus the in-use gate SR-025).

#### 4.4a `PathConfidence`

```swift
enum PathConfidence: String, Sendable, Codable { case high, medium, low }
```

- **`.high`** — canonical path (spec 16 § 9) is a **prefix-descendant** of a plugin-declared,
  symbolic-anchored root (spec 13 § 4), the glob match is specific (not `**`-only at the anchor),
  the path is not a symlink, and it survived allow∩roots−deny (§ 7).
- **`.medium`** — matched by a broad glob or heuristic, or one canonicalization step traversed a
  symlink that still resolved inside the allow-space.
- **`.low`** — heuristic/name-based match only, ambiguous anchor, or the path is within N=2
  directory levels of a user content root.
- **SR-020** Path confidence is computed by the **engine** from the canonical path and the
  declared root, **not** supplied by the plugin. A plugin cannot assert `.high`.

### 4.5 Gates (caps that only lower)

After `S_raw`, the scorer applies **gates**. A gate can only *reduce* the score (or clamp risk
tighter); no gate raises it. Gates encode the non-negotiable "when in doubt, don't" rules.

```swift
enum SafetyGate: String, Sendable, Codable {
    case irreversible         // Recoverability.none → cap 49 (🔴)      SR-023
    case userAuthored         // strong user-authored signal → cap 49   SR-024
    case inUse                // open/locked/immutable → cap 49         SR-025
    case dataless             // iCloud placeholder → excluded entirely SR-026
    case snapshot             // under TM local snapshot → excluded     SR-027
    case protectedPath        // fails allow∩roots−deny → excluded      SR-028
    case lowPathConfidence    // PathConfidence.low → cap 84 (≤🟡)      SR-029
    case pluginHintTighten    // plugin's stricter hint lowers score    SR-030
    case crossVolumeShared    // reclaim mostly shared blocks → cap 84  SR-031
}
```

- **SR-021** Gates are applied **after** `S_raw` and are **monotonic downward**:
  `S_final = min(S_raw, all applicable caps)`. Exclusion gates (`dataless`, `snapshot`,
  `protectedPath`) remove the item from any actionable plan entirely (it becomes a display-only
  or skipped finding), independent of score.
- **SR-022** The engine applies gates; a plugin cannot suppress a gate. Which gates fired is
  recorded in `ScoredSafety.appliedGates` and the audit log (spec 28).
- **SR-023** `Recoverability == .none` ⇒ `irreversible` gate ⇒ score capped at **49** ⇒ 🔴
  (DM-1).
- **SR-024** Any strong user-authored signal (SR-017) ⇒ `userAuthored` gate ⇒ score capped at
  **49** ⇒ 🔴.
- **SR-025** `isOpenOrLocked == true` or an immutable BSD flag ⇒ `inUse` gate ⇒ capped at **49**
  and the item is not disposable without an explicit `--force-locked` override (spec 20).
- **SR-026** `isDataless == true` ⇒ `dataless` gate ⇒ **excluded** (0 reclaim, `SkipReason.dataless`,
  spec 16 § 4.4). Never actioned in a way that materializes cloud data.
- **SR-027** `snapshotRef != nil` (under a local TM/APFS snapshot mount) ⇒ `snapshot` gate ⇒
  **excluded** (Constitution Article 5, spec 16 § 4.3).
- **SR-028** Failing the protected-path check (§ 7) ⇒ `protectedPath` gate ⇒ **excluded** and
  `Finding.isProtected == true` (display-only; DM-4).
- **SR-029** `PathConfidence.low` ⇒ `lowPathConfidence` gate ⇒ capped at **84** (can never be
  🟢). Low confidence about *what* a path is must never be auto-selected.
- **SR-030** A plugin-supplied `SafetyScore` hint that is **lower** than `S_final` replaces it
  (plugins may only tighten, DM-2/DM-3). A hint *higher* than `S_final` is **ignored** and logged.
- **SR-031** If a finding's reclaim is dominated by shared blocks (clones/hardlinks with
  `sharedBytesExcluded` such that actual freed bytes < 25% of logical; spec 14 § 6) ⇒
  `crossVolumeShared` gate ⇒ capped at **84**, because "deleting this frees almost nothing" is a
  sign the user's mental model differs from reality.

### 4.6 Final mapping

```
S_final = min(S_raw, applicable numeric caps)          // exclusion gates remove item first
risk     = SafetyScore(S_final).riskLevel               // spec 14 § 4.3
risk     = max(risk, pluginHint.riskLevel)              // plugin may only make it *more* dangerous
```

- **SR-032** The resulting `Finding.risk` MUST equal `SafetyScore(S_final).riskLevel` unless a
  plugin presented a **stricter** (higher) level with evidence; a *looser* level is rejected at
  scan time (DM-3, enforced in spec 17). Violation aborts the plugin's contribution with exit
  code 7 (`plugin`), never a silent downgrade.

## 5. Worked scoring examples

`now` = session-fixed `2026-07-06`. Weights per § 4.3.

### 5.1 Xcode DerivedData (stale project) → 🟢

Evidence: under `~/Library/Developer/Xcode/DerivedData/App-abc123/`, `mtime` 41 days,
`lastUsedDate` 41 days, no Finder tags, `spotlightKind` absent, not open, `.instant`
recoverability (staged), `PathConfidence.high`.

| Signal | sᵢ | wᵢ | points |
|---|---|---|---|
| regenerability (build cache anchor) | 1.0 | 0.30 | 30.0 |
| user-authored absence | 1.0 | 0.25 | 25.0 |
| recoverability (`.instant`) | 1.0 | 0.15 | 15.0 |
| path confidence (`.high`) | 1.0 | 0.15 | 15.0 |
| recency (41d → 0.7) | 0.7 | 0.10 | 7.0 |
| lock (free) | 1.0 | 0.05 | 5.0 |
| **S_raw** | | | **97.0** |

No gates fire. `S_final = 97` → **🟢 Safe**, pre-selected.

### 5.2 npm cache (`~/.npm/_cacache`) → 🟢, but medium if never re-fetched context

Evidence: cache anchor, no user content, `.manual` recoverability (re-download on next install),
`lastUsedDate` 12 days, `.high` path confidence, free.

| Signal | sᵢ | wᵢ | points |
|---|---|---|---|
| regenerability (costly re-fetch → 0.6) | 0.6 | 0.30 | 18.0 |
| user-authored absence | 1.0 | 0.25 | 25.0 |
| recoverability (`.manual`) | 0.6 | 0.15 | 9.0 |
| path confidence (`.high`) | 1.0 | 0.15 | 15.0 |
| recency (12d → 0.4) | 0.4 | 0.10 | 4.0 |
| lock | 1.0 | 0.05 | 5.0 |
| **S_raw** | | | **76.0** |

`S_final = 76` → **🟡 Medium**. Shown, not pre-selected; skipped under `--yes` unless
`--include medium`. (Matches intuition: nuking the npm cache costs a re-download.)

### 5.3 Old `.dmg` in `~/Downloads` → 🔴

Evidence: `~/Downloads/Installer.dmg`, `whereFroms` present (downloaded), `spotlightKind` "Disk
Image", `mtime` 220 days, `.hard` recoverability (must re-download from a vendor), no Finder tags,
`PathConfidence.medium` (Downloads is broad; contents unknown). `~/Downloads` is *not* a protected
content root by default, but a disk image's *contents* are unknown.

| Signal | sᵢ | wᵢ | points |
|---|---|---|---|
| regenerability (re-download external → 0.3) | 0.3 | 0.30 | 9.0 |
| user-authored absence (unknown DMG contents → 0.5) | 0.5 | 0.25 | 12.5 |
| recoverability (`.hard`) | 0.3 | 0.15 | 4.5 |
| path confidence (`.medium`) | 0.5 | 0.15 | 7.5 |
| recency (220d → 1.0) | 1.0 | 0.10 | 10.0 |
| lock | 1.0 | 0.05 | 5.0 |
| **S_raw** | | | **48.5** |

`S_final = 48.5 → 48` → **🔴 Dangerous** (below 50). Shown, never pre-selected, typed
confirmation required. Correct: a stale installer is *probably* junk, but the tool must not
assume a disk image's contents.

### 5.4 A tagged document under a cache path → 🔴 via gate

Evidence: a file that a plugin's glob matched under a cache anchor, but it has a Finder tag
("Important") and `spotlightKind` "PDF Document". Raw signals might compute high, but SR-017 forces
`s_uac = 0.0` and SR-024 fires the `userAuthored` gate → **cap 49** → **🔴**. Even if every other
signal is 1.0, `S_raw` with `s_uac = 0` is `100 − 25 = 75`, then capped to `49`. The gate, not the
weights, protects the user here.

### 5.5 iCloud placeholder → excluded

`isDataless == true` ⇒ SR-026 `dataless` gate ⇒ item excluded, 0 reclaim, `SkipReason.dataless`.
No score is actioned. (Deleting it could evict cloud data the user expects to re-materialize.)

## 6. Hard invariants — engine-enforced defense in depth

Constitution Article 4.4 fixes six hard invariants. They are enforced **in the engine**
(`CleanerCore`), *not* delegated to plugins, and re-checked at execute time (§ 11). Each is a
last-line gate that fires even if scoring, planning, and the plugin all agreed.

- **SR-033** *Never delete outside the allow-space.* Every candidate action path must satisfy
  `path ∈ (⋃ pluginDeclaredRoots ∩ allowSpace) − denyList` (§ 7). Enforced at plan build **and**
  at execute time. Violation ⇒ abort that item, `ActionResult.blockedBySafety`, exit code 8.
- **SR-034** *Never delete a protected path* (Article 5 deny-list, § 7). Enforced identically;
  a protected path never yields a `PlannedAction` (DM-4).
- **SR-035** *Never follow a symlink out of an allowed root to delete the target.* Disposition
  operates fd-relative with `O_NOFOLLOW` (spec 16 § 9); deleting a symlink removes only the link.
  The **resolved real path** of the target is re-checked against § 7 before action.
- **SR-036** *Never delete a currently-open/locked/immutable file* without an explicit override
  (`--force-locked`). Re-checked at execute time (`isOpenOrLocked`, BSD flags), not just at scan.
- **SR-037** *Never purge without staging first,* unless `--no-stage` **and** confirmation
  (interactive typed confirmation or a policy that explicitly authorizes `--no-stage`). `.purge`
  is unreachable as a default (DM-5, spec 14 § 4.5/§ 4.13).
- **SR-038** *Refuse to operate on a mount root, a system/read-only volume, or `/`.* Enforced via
  DiskArbitration `VolumeInfo` (`isSystemVolume`, `isReadOnly`, mount-point equality; spec 16 § 7).
  Violation ⇒ exit code 8.

Enforcement placement:

| Invariant | Scan (17) | Plan build (18/20) | Execute close-out (20/§11) |
|---|---|---|---|
| SR-033 allow-space | mark `isProtected` | reject action | re-check canonical path |
| SR-034 protected | `isProtected` | no action produced | re-check |
| SR-035 symlink escape | `O_NOFOLLOW` walk | resolved-path check | fd-relative `O_NOFOLLOW` + re-check |
| SR-036 in-use | `inUse` gate | skip/annotate | re-`fstat` + lock check |
| SR-037 stage-before-purge | n/a | disposition defaulting | disposition guard |
| SR-038 mount/system vol | volume probe | reject | re-probe volume |

- **SR-039** Each invariant has a **dedicated test** in spec 31 that attempts the violation
  through the *public* plan/execute API (not a unit shortcut) and asserts the engine blocks it
  with the right exit code. Defense in depth is only real if it is tested at the boundary.

## 7. Protected-path enforcement (Article 5)

### 7.1 The three sets

- **`allowSpace`** — the coarse envelope the tool may ever touch: the user's home *minus* the
  content roots, plus `/usr/local`, plus `/private/var/folders` temp, plus explicitly declared
  system cache areas. Everything else is outside `allowSpace` a priori.
- **`pluginRoots`** — the union of every enabled plugin's `declaredRoots`, resolved from their
  **symbolic anchors** (`RootSpec`, spec 13 § 4) against the real user; a plugin cannot declare an
  absolute string (SR-041).
- **`denyList`** — the hard-coded, non-overridable protected set from Constitution Article 5:
  `/`, `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, system parts of `/Library`, the
  `.app` bundles under `/Applications`, `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`,
  `~/Music`, `~/.ssh`, `~/.gnupg`, all Keychains, credential config, `*.key`/`*.pem`/private
  material, any path under a Time Machine local snapshot mount, and the tool's own
  `~/.cleaner/{staging,config,logs,policy}`.

### 7.2 The algorithm

```
allowed(path) :=
    p := canonicalize(path)                         // spec 16 §9: absolute, symlink-resolved, NFC
    if isUnder(p, denyList)                → DENY (protectedPath gate, SR-028)
    if not isUnder(p, allowSpace)          → DENY
    if not existsRoot(r ∈ pluginRoots : isUnder(p, r)) → DENY
    if isMountRoot(p) or onSystemOrReadOnlyVolume(p)   → DENY (SR-038)
    if realParentEscapes(p)                → DENY      // parent resolves outside allow (SR-035)
    else                                   → ALLOW
```

`isUnder(p, S)` uses **canonical, boundary-anchored prefix** matching: `p` equals a member of
`S` or has a member of `S` as a path-component prefix (so `~/.sshx` does **not** match `~/.ssh`,
and `/usr/localx` does **not** match `/usr/local`). Matching is on decomposed path components,
never raw string `hasPrefix`.

- **SR-040** The set algebra is computed on **canonical** paths (spec 16 § 9), and the deny check
  is applied to both the target and its **real parent**. A `..` or symlink component cannot smuggle
  a path past the check.
- **SR-041** Plugin roots are resolved from symbolic anchors only. A plugin declaring a root that
  resolves into the deny-list (e.g. `~/Documents/**`) is **rejected at plugin validation**
  (spec 13 § 4), before any scan — the intersection can never widen the allow-space.
- **SR-042** The deny-list is **compiled in and non-overridable** except by a signed policy file
  (spec 23) that names the specific path and carries an explicit acknowledgement; even then, the
  absolute roots (`/`, `/System`, system volume, snapshots, keychains, private-key material) are
  **never** unlockable. Precedence: `denyList` > `pluginRoots ∩ allowSpace`. Deny always wins.
- **SR-043** User `extraProtected` entries (spec 14 § 4.16) are **added** to the deny-list for
  that session; user `extraTargets` are added to `pluginRoots` **only after** passing the same
  allow∩−deny check (a user target rule can never point into the deny-list).

### 7.3 Result

A path failing `allowed()` produces a **display-only** `Finding` with `isProtected == true`
(shown so the user understands why the tool won't touch it) and **no** `PlannedAction` (DM-4). An
action somehow reaching execute time against such a path aborts with `ActionResult.blockedBySafety`
and exit code 8 (`safety`).

## 8. Preview → confirm → execute contract

Constitution Principle 1: every destructive action is *preview-first, confirm-second,
execute-third*. The confirmation **strength scales with risk**.

### 8.1 Preview (always, all levels)

- **SR-044** No disposition executes before a **preview** is produced: the `ScanResult`'s
  `Finding`s with risk icon, safety score, recoverability, rationale, per-item and total reclaim
  (on-disk, shared-block-corrected; spec 14 § 6). In non-interactive/JSON mode the preview is the
  emitted plan; in TUI it is the selectable list (spec 25). Dry-run and real-run use identical
  measurement code (Principle 3, DM-9).

### 8.2 Confirmation matrix

| Risk | Pre-selected in `clean`? | Confirmation required | `ConfirmationState` |
|---|---|---|---|
| 🟢 Safe | Yes | Single bulk confirm (`Proceed? [y/N]`) or pre-selected in TUI | `.preselected` |
| 🟡 Medium | No (opt-in) | Explicit per-item / per-category selection, then bulk confirm | `.explicitInteractive` |
| 🔴 Dangerous | No, never | **Typed confirmation** (§ 8.4) per item or per dangerous batch | `.typedConfirmation` |

- **SR-045** 🔴 items are **never pre-selected** and **never** auto-confirmed by `--yes` or any
  automation policy (§ 10).
- **SR-046** A `CleanPlan` with any 🔴 action or any `.purge` disposition has
  `requiresConfirmation == true` (spec 14 § 4.13) and MUST carry the corresponding
  `ConfirmationState` on each such `PlannedAction`, or the cleanup engine refuses to execute it
  (DM-5, enforced in spec 20).

### 8.3 Execute

- **SR-047** Execution runs actions **ordered safe→risky** (spec 20): 🟢 first, then 🟡, then 🔴,
  and within a batch `.stage` before `.trash` before `.purge`. This limits blast radius — a
  failure or abort stops before the riskiest work.
- **SR-048** Every executed action passes the **execute-time re-validation** (§ 11) immediately
  before the syscall. Passing at plan time is necessary but not sufficient.

### 8.4 Typed confirmation for 🔴

- **SR-049** A 🔴 action requires the user to type a **non-trivial token**, not press `y`. The
  token is the literal word **`delete`** for a batch, or the item's short name for a single
  high-value item (the TUI shows exactly what to type; spec 25 § confirm). `y`/Enter is
  insufficient. Ctrl-C / `q` / empty input aborts (exit code 5).
- **SR-050** Typed confirmation is **per dangerous batch or per item**, never inherited from a
  prior bulk 🟢/🟡 confirmation. Confirming the safe batch does not confirm any 🔴 item.
- **SR-051** In a non-TTY context (CI, piped), 🔴 items **cannot** be typed-confirmed and are
  therefore **not actionable** at all unless authorized by a signed automation policy that
  explicitly enumerates them (§ 10); otherwise they are reported as skipped and the run exits 3
  (`partial`) if the user asked to clean them.

## 9. Staging-by-default, recoverability, and escalation to permanent deletion

### 9.1 Staging default (Principle 2, CC-7)

- **SR-052** The **default `Disposition` is `.stage`** for every actioned item (spec 14 § 4.5).
  Staging moves the item into the session staging tree (`~/.cleaner/staging/<session-uuid>/`,
  spec 15 § 5) via atomic same-volume `renameat` where possible (spec 16 § 11), capturing full
  restore metadata (owner/mode/ACL/xattrs/flags/timestamps/symlink target) **before** the move.
- **SR-053** Nothing is `unlink()`-ed outright when a recoverable path exists. `.purge` is an
  explicit escalation, never a default and never selected by the scorer or planner.

### 9.2 Recoverability classes (spec 14 § 4.4)

| Class | Meaning | Effect on scoring / risk |
|---|---|---|
| `.instant` | Staged; one-command `rollback` (spec 21) | `s_recover = 1.0`; enables 🟢 |
| `.manual` | User can re-download/re-build | `s_recover = 0.6`; typically 🟡 |
| `.hard` | External source needed (re-clone, vendor re-download) | `s_recover = 0.3` |
| `.none` | Irreversible, no source | `s_recover = 0.0`; **forces 🔴** (SR-023) |

- **SR-054** `Recoverability` classifies the *underlying* recoverability of the content, while
  **staging** additionally overlays instant tool-level rollback for *any* staged item. An item can
  be `.manual` at the content level yet still be restorable from staging until purge — the report
  and UI make both facts explicit (spec 12 § 12).

### 9.3 Escalation to permanent deletion

- **SR-055** `.purge` (permanent) is reachable only via: (a) purging **already-staged** items
  through the explicit `purge` command with confirmation, or (b) `clean --no-stage` **with** typed
  confirmation (interactive) or an automation policy that explicitly grants `--no-stage`. There is
  no other path (DM-5).
- **SR-056** `--no-stage` on a 🔴 item still requires typed confirmation (§ 8.4); the two gates
  compose (no-stage does not relax risk confirmation).

## 10. `--yes`, automation, and risk

Constitution Article 4.1 fixes: 🟢 auto-clean, 🟡 skipped unless `--include medium`, 🔴 **never**
auto-cleaned.

- **SR-057** `--yes` (non-interactive consent) authorizes **only 🟢** items by default. 🟡 requires
  `--yes --include medium`. 🔴 is **never** authorized by `--yes` (SR-045). Attempting to clean a
  🔴 item with `--yes` results in it being skipped and reported; exit code 3 if the user targeted it.
- **SR-058** A **signed automation policy** (spec 23) may pre-authorize a *specific, enumerated*
  set of plugins/categories/paths at 🟢 and 🟡. **SR-058a** A policy MUST NOT be able to
  auto-authorize a 🔴 item generically; if a policy authorizes a specific path that later scores
  🔴, that item is **held back** and reported, never auto-purged. The policy sets
  `ConfirmationState.automationPolicy`, and the cleanup engine still applies every § 6 invariant
  and § 11 re-validation.
- **SR-059** Automation never escalates disposition: a policy may authorize `.stage`/`.trash`;
  `.purge`/`--no-stage` under automation requires the policy to **explicitly** name `--no-stage`
  for the specific target, and even then never for a 🔴-scored item (SR-055, SR-058a).
- **SR-060** `--yes` and policies are **recorded in the audit log** (spec 28) with the exact set
  of authorized findings, so consent is reconstructable after the fact (Principle 8).

## 11. Safety re-validation at cleanup time (TOCTOU close-out)

The scan→plan→execute pipeline spans time; the filesystem can change under it. The engine
re-derives safety **immediately before each mutating syscall**, operating fd-relative (spec 16 § 9).

- **SR-061** Before disposing of an item, the engine re-opens the target **fd-relative to its
  already-verified parent** (`openat(…, O_NOFOLLOW)`) and re-checks:
  1. **Identity** — `dev`, `inode`, expected `type`, and `nlink` match what the scan recorded. If
     identity drifted, **abort** that item (skip + report), never act on the swapped file.
  2. **Protected-path** — the resolved real path still satisfies `allowed()` (§ 7).
  3. **Volume** — still not a system/read-only volume / mount root (SR-038).
  4. **In-use** — re-check `isOpenOrLocked`/immutable flags (SR-036).
  5. **Dataless/snapshot** — re-check `isDataless`/`snapshotRef` (SR-026/SR-027).
- **SR-062** Any re-validation failure yields `ActionResult.blockedBySafety` (exit 8) for that
  item and does **not** abort the whole run; other items proceed, and the report lists the block
  (Principle 3). A protected-path or system-volume failure is a hard safety abort recorded as such.
- **SR-063** The engine **never re-resolves the full path string** at act time; it acts relative
  to the fixed parent fd verified at open, closing the symlink-swap race (spec 16 § 9).
- **SR-064** A large **estimate-vs-actual reclaim gap** discovered during execution (measured
  `statfs` delta vs `projectedReclaim` beyond a tolerance) is surfaced in the report, not hidden
  (spec 14 § 6, OQ-14.5 resolved here: the tolerance constant lives in this spec — **10%** relative
  or 100 MB absolute, whichever is larger, triggers a report note). This detects clone/hardlink
  mis-accounting after the fact.

## 12. Surfacing safety score and risk (UI / CLI / JSON)

- **SR-065** Every `Finding` surfaces its `RiskLevel.icon` (🟢/🟡/🔴), numeric `SafetyScore`, and
  `Recoverability` in **all** presentation modes: TUI list/tree (spec 25), plain CLI (spec 26),
  and JSON (`--json`). The three modes report the **same** score from the same scorer (Principle 3).
- **SR-066** A "**why**" explanation is available per finding: the `rationale` string plus the
  `SignalContribution` breakdown (§ 4.1) and `appliedGates`. The TUI shows it on demand (e.g.
  expand/`?`); JSON always includes it under a `safety.signals` / `safety.gates` array; the audit
  log records it for every actioned item (spec 28). "Why did you (want to) delete this?" always has
  an answer (Principle 8).
- **SR-067** JSON safety shape (stable export contract; versioned with the report, spec 15 § 8):

```json
"safety": {
  "risk": "medium",
  "score": 76,
  "recoverability": "manual",
  "signals": [
    {"signal": "regenerability", "subscore": 0.6, "weight": 0.30, "points": 18.0,
     "basis": "npm cache anchor; costly re-fetch"},
    {"signal": "userAuthored",  "subscore": 1.0, "weight": 0.25, "points": 25.0, "basis": "no user-authored signals"}
  ],
  "gates": [],
  "protected": false
}
```

- **SR-068** Totals surface `byRisk` counts (spec 14 § 4.12) so the user sees, before confirming,
  how many 🟢/🟡/🔴 items and how much reclaim each tier represents. The 🔴 tier is visually
  separated and never inside a "select all safe" affordance.
- **SR-069** The tool **never overstates** safety: if a score was computed under missing evidence
  (SR-015), the UI marks it (e.g. a "computed with limited access" note) and the JSON sets a
  `degraded: true` flag on affected signals. Truth in reporting extends to the confidence of the
  safety judgment itself.

## 13. Decision table (risk × path × consent → action)

| Risk | `isProtected` | Consent context | Pre-selected? | Confirmation | Default disposition | Executes? |
|---|---|---|---|---|---|---|
| 🟢 | false | interactive `clean` | Yes | bulk `y/N` | `.stage` | Yes on confirm |
| 🟢 | false | `--yes` | Yes | none (consent given) | `.stage` | Yes |
| 🟢 | false | signed policy | Yes | policy | `.stage` | Yes |
| 🟡 | false | interactive | No | explicit select + bulk | `.stage` | On explicit select |
| 🟡 | false | `--yes` (no `--include medium`) | No | — | — | **No** (skipped, reported) |
| 🟡 | false | `--yes --include medium` | No | consent given | `.stage` | Yes |
| 🔴 | false | interactive | No | **typed** (`delete`/name) | `.stage` | Only on typed confirm |
| 🔴 | false | `--yes` / policy (generic) | No | — | — | **Never** (held, reported) |
| 🔴 | false | non-TTY, no explicit policy path | No | impossible | — | **No** (exit 3 if targeted) |
| any | **true** | any | No (display-only) | — | — | **Never** (exit 8 if attempted) |
| any (dataless/snapshot) | excluded | any | — | — | — | **Never** (skipped) |
| 🟢/🟡 | false | `.purge`/`--no-stage` requested | No | typed confirm (+ policy names it for automation) | `.purge` | Only with escalation |

## 14. Enforcement & traceability map

| SR range | Concern | Primarily enforced in | Tested by (spec 31) |
|---|---|---|---|
| SR-001…011 | Risk-level criteria | Scorer + scan (17/22) | risk-classification corpus |
| SR-012…032 | Scorer model, signals, gates, mapping | `SafetyScorer` (22) | scorer property + golden tests |
| SR-033…039 | Hard invariants (Article 4.4) | Engine (17/18/20) | boundary invariant tests |
| SR-040…043 | Protected-path algebra (Article 5) | Rule/allow-deny (18) | path-algebra + fuzz tests |
| SR-044…051 | Preview/confirm/execute + typed 🔴 | Cleanup + TUI/CLI (20/25/26) | confirmation-flow tests |
| SR-052…056 | Staging default + purge escalation | Cleanup + staging (20/21) | disposition guard tests |
| SR-057…060 | `--yes` / automation vs risk | CLI + policy (23/26) | automation-policy tests |
| SR-061…064 | TOCTOU execute-time re-validation | Cleanup + FS (16/20) | race/identity-drift tests |
| SR-065…069 | Safety surfacing (UI/CLI/JSON) | TUI/CLI/report (25/26/15) | snapshot + JSON-schema tests |

- **SR-070** Every `SR-###` in this spec MUST trace to at least one automated test (spec 31) and
  at least one owning module (spec 12). A safety requirement with no test is a defect (Constitution
  Article 11).

## Open Questions

- **OQ-22.1** Should the six weights (§ 4.3) be exposed as an *advanced, signed-only* tuning knob,
  or remain hard constants? *Leaning: hard constants; per-plugin tightening (DM-2) is the only
  sanctioned adjustment, so users cannot loosen safety by config.*
- **OQ-22.2** Is the 🔴 typed token (`delete`) the right friction, or should high-value single
  items require typing the item's name (§ 8.4)? *Leaning: batch → `delete`; single high-value item
  (app bundle, DB, disk image) → item name. Needs UX validation (spec 25).*
- **OQ-22.3** Should `crossVolumeShared` (SR-031) cap at 84 or fully exclude when freed bytes are
  ~0? *Leaning: cap to 🟡 and annotate "frees ~0 bytes"; excluding hides a real user-facing truth.*
- **OQ-22.4** The recency thresholds (§ 4.4, 7/30/90 days) are heuristic — do they need to be
  per-category (a 7-day-old build cache is safer than a 7-day-old download)? *Leaning: allow a
  per-`Category` recency profile in v1.1, fixed global thresholds for v1.0.*
- **OQ-22.5** Where does the estimate-vs-actual tolerance (SR-064) belong long-term — here or in
  the reclaim accounting of spec 20? *Resolved for now: the constant lives here (10% / 100 MB);
  the measurement lives in spec 20.*
- **OQ-22.6** Should `atime`-derived recency ever be used at all given `noatime` mounts, or should
  the scorer treat missing `lastUsedDate`/`mtime` as strictly `0.3` (SR-015) and ignore `atime`?
  *Leaning: keep `atime` as a capped lower-bound (SR-019); revisit with field data.*

## Dependencies

**Consumes:** 00-constitution (Articles 1 principles ranking, 4 risk/score/recoverability
constants, 4.4 hard invariants, 5 protected paths, 7 exit codes 5/8), 10-tech-stack (Swift 6
`Sendable` value types, pure scorer), 14-domain-model (`RiskLevel`, `SafetyScore`,
`Recoverability`, `Disposition`, `Finding`, `Evidence`, `CleanPlan`, `PlannedAction`,
`ConfirmationState`, `ScanResult`, reclaim/shared-block accounting DM-1/2/3/4/5/8/9),
16-filesystem-strategy (canonicalization § 9, allow/deny enforcement, TOCTOU-safe fd-relative
mutation, dataless/snapshot/symlink rules, `VolumeInfo`).

**Feeds:** 17-scan-engine (invokes `SafetyScorer`, enforces DM-2/3, marks `isProtected`),
18-rule-engine (allow∩roots−deny algebra, `extraProtected`/`extraTargets`), 19-detection
(supplies `Evidence` signals the scorer reads), 20-cleanup-engine (confirmation matrix, ordered
execution, execute-time re-validation, purge escalation), 21-rollback-design (staging as instant
recoverability), 23-permission-model (metadata gating affects SR-015; automation policies SR-058),
25-tui-design (risk/score/why surfacing), 26-cli-ux (plain + JSON surfacing, `--yes`/`--include`),
27-error-handling (exit codes 5/8), 28-logging (audit of consent, signals, gates),
35-security-review (SR-### mitigation map), 36-threat-model (THR-### ↔ SR-### cross-refs),
39-risk-register (RISK-001 data-loss mitigation chain).
