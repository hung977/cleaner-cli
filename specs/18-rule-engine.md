# 18 — Rule Engine

> **Phase D · Depends on:** 00-constitution (Art. 4 safety model, Art. 5 protected paths, Art. 7
> exit codes, Principles 1/3/8), 10-tech-stack (Yams, Swift value types), 13-plugin-architecture
> (§10 four-gate funnel — RuleEngine is gate ②), 14-domain-model (`Finding`, `RiskLevel`,
> `SafetyScore`, `Disposition`, `Recoverability`, `Evidence`), 16-filesystem-strategy (§9
> canonicalization, deny-list), 17-scan-engine (funnel invocation) ·
> **Depended on by:** 19 (detection sets baseline risk the rules can adjust), 20 (cleanup honors
> disposition gating), 22 (safety model composition), 24 (config supplies user rules).

## 1. Purpose & scope

The **Rule Engine** is the declarative layer that classifies paths and *gates* actions on top of
plugin output. It is **gate ②** of the scan safety funnel (spec 13 §10): after the `SafetyScorer`
(gate ①) recomputes a score and before the `ProtectedPathGuard` (gate ③) enforces hard
allow/deny, the Rule Engine applies:

- **built-in rules** — non-overridable protected paths (Art. 5), baseline risk classification,
  age/size threshold conventions shared by all plugins;
- **user rules** from config/profile (spec 24) — `ignore`/`whitelist`/`blacklist`(target)/custom
  `target` definitions, plus per-category overrides.

It produces a decision that can **drop** a Finding (whitelisted/ignored), **admit a new** Finding
(user target rule promotes a path plugins didn't flag), or **modify** a Finding's `risk`,
`safetyScore` (lower only, DM-2), `recoverability`, and `suggestedDisposition` — always recording
**which rule fired** for audit and explainability (Principle 8).

The Rule Engine is *declarative and deterministic* (Principle 5): the same rules over the same
Finding always yield the same decision, independent of evaluation-thread order. It never touches
the filesystem (gate ③ owns path realness/TOCTOU; spec 16 §9) and never *raises* a safety score
past the scorer ceiling (Art. 4.2, DM-2).

Non-goals: computing the base `SafetyScore` (spec 22), physical deny-list path realness/symlink
escape (spec 16 §9 / gate ③), detection heuristics (spec 19).

## 2. Precedence model (the spine)

Rules are grouped into **tiers**; a higher tier is evaluated first and its terminal decisions are
*final* against lower tiers. **Deny always wins; protected paths are non-overridable.**

```
 ┌── TIER 0 — HARD PROTECTED (built-in, non-overridable) ────────────────┐  deny wins,
 │   Art. 5 deny-list: /, /System, ~/Documents, ~/.ssh, *.key, TM snap…   │  even over a
 │   → verdict = .protected  (display-only, isProtected=true, DM-4)       │  user "target"
 └────────────────────────────────────────────────────────────────────────┘
 ┌── TIER 1 — USER DENY (whitelist / ignore) ───────────────────────────┐  a user "keep this"
 │   config whitelist + ignore globs → verdict = .drop(keep)             │  beats a user
 └────────────────────────────────────────────────────────────────────────┘  "clean this"
 ┌── TIER 2 — USER ALLOW (blacklist / custom target) ───────────────────┐  promotes/annotates
 │   config targets → verdict = .admit / .modify (risk, disposition)     │  a path
 └────────────────────────────────────────────────────────────────────────┘
 ┌── TIER 3 — BUILT-IN CLASSIFICATION (baseline, weakest) ──────────────┐  age/size/metadata
 │   risk classification, age/size thresholds, category defaults         │  refinements
 └────────────────────────────────────────────────────────────────────────┘
```

Precedence invariants (normative):

- **RE-1** Tier 0 is absolute: no user or built-in rule in tiers 1–3 can un-protect a Tier-0 path.
  A `target` rule pointing at `~/Documents` is *rejected at config load* (exit 6) and, if it
  somehow reaches evaluation, produces `.protected`, never `.admit`.
- **RE-2** Within tiers 1–3, **deny beats allow beats classify**: an `ignore`/`whitelist` (tier 1)
  drop wins over a `target` (tier 2) admit which wins over a built-in classification (tier 3).
- **RE-3** Ties *within a tier* resolve by **most-specific-path wins**, then rule declaration
  order (stable), then rule ID (lexical) — fully deterministic (Principle 5).
- **RE-4** A rule may only make a Finding **stricter** on safety: it may lower `SafetyScore`,
  raise `RiskLevel`, or downgrade `Recoverability`; it may **not** raise a score above the
  scorer's ceiling (DM-2) nor loosen risk below what the scorer computed (DM-3). Loosening
  attempts are clamped and logged (`RuleClamp` audit event).

## 3. Rule types

A rule is a **predicate** (does this rule apply to this Finding?) plus an **effect** (what it does
when it matches). Predicates compose with AND/OR/NOT.

### 3.1 Predicates

```swift
indirect enum Predicate: Sendable, Codable, Hashable {
    // Path matching (evaluated against Item.primaryPath, canonicalized — spec 16 §9)
    case glob(String)                       // fnmatch-style, e.g. "**/DerivedData/**"
    case regex(RegexSpec)                    // NSRegularExpression source + options; anchored by default
    case pathPrefix(FilePath)                // canonical prefix (fast, common case)
    case underAnchor(RootBase, glob: String) // symbolic anchor (spec 13 §4) + relative glob

    // Metadata predicates (read Evidence — spec 14 §4.7; nil field ⇒ predicate is false, not true)
    case ageOlderThan(Duration, basis: AgeBasis)   // mtime | atime | lastUsed | birthtime
    case ageNewerThan(Duration, basis: AgeBasis)
    case sizeAtLeast(Int64, of: SizeBasis)         // onDisk | logical
    case sizeAtMost(Int64, of: SizeBasis)
    case spotlightKind(String)                     // kMDItemKind == "…"
    case hasWhereFroms                             // download origin present
    case whereFromsMatches(RegexSpec)              // e.g. re-downloadable from a known host
    case hasFinderTags                            // user tagged → matters (lowers score)
    case isDataless                               // iCloud placeholder (spec 16 §4.4)
    case isSymlink, isHardlink, isSparse, isClone
    case category(CategoryID)                      // finding's category
    case producedBy(PluginID)                      // finding's origin plugin
    case riskAtLeast(RiskLevel)                    // current (post-scorer) risk

    // Composites
    case all([Predicate])                          // AND
    case any([Predicate])                          // OR
    case not(Predicate)                            // NOT
    case always                                    // matches everything (catch-all)
}

enum AgeBasis: String, Codable, Sendable { case mtime, atime, lastUsed, birthtime }
enum SizeBasis: String, Codable, Sendable { case onDisk, logical }
struct RegexSpec: Sendable, Codable, Hashable { let pattern: String; let caseInsensitive: Bool }
```

**Nil-safety of metadata predicates (RE-5).** A predicate over a `nil` Evidence field evaluates
to **false** (not true, not "unknown-as-match"). This is a safety choice (Principle 1): a rule
that says "clean if older than 90 days" must *not* fire when age is unknown — absence of evidence
is never evidence for a destructive action. A rule that *keeps* a file (tier 1) may opt into
"apply on unknown" via `matchOnMissingEvidence: true` (fail-safe toward keeping).

### 3.2 Effects

```swift
enum Effect: Sendable, Codable, Hashable {
    // Terminal (tier 0/1)
    case protect                              // Art. 5 — display-only, non-overridable (tier 0)
    case keep                                 // drop the finding (user whitelist/ignore, tier 1)

    // Admission (tier 2) — promote a path plugins didn't flag into a Finding
    case admit(as: AdmitSpec)                 // category, baseline risk, rationale, disposition

    // Modification (tier 2/3) — adjust an existing finding (stricter-only per RE-4)
    case setRisk(RiskLevel)                   // may only raise; lowering clamped
    case lowerScore(to: Int, rationale: String)   // may only lower (DM-2)
    case setRecoverability(Recoverability)    // may only downgrade
    case setDisposition(Disposition)          // stage↔trash allowed; .purge REJECTED (DM-5)
    case retag(CategoryID)                    // reclassify category (presentation)
    case annotate(Evidence)                   // add evidence (audit only; no safety change)
}

struct AdmitSpec: Sendable, Codable, Hashable {
    let category: CategoryID
    let baselineRisk: RiskLevel               // still re-scored by gate ① (DM-2/3)
    let recoverability: Recoverability
    let disposition: Disposition              // default .stage (never .purge — DM-5)
    let rationale: String
}
```

`setDisposition(.purge)` is **rejected**: a rule can never escalate to permanent deletion
(DM-5, Art. 4.4). `admit` disposition defaults to `.stage`.

### 3.3 The `Rule` and `RuleSet`

```swift
struct Rule: Sendable, Codable, Hashable, Identifiable {
    let id: RuleID                            // stable, provenance key (§7)
    let tier: RuleTier                        // .protected | .userDeny | .userAllow | .builtinClassify
    let when: Predicate
    let then: [Effect]                        // applied in order; effects are commutative within RE-4
    let source: RuleSource                    // .builtin | .config(path) | .profile(id) | .plugin(id)
    let enabled: Bool
    let matchOnMissingEvidence: Bool          // RE-5 opt-in (keep-effects only)
    let comment: String?                      // user's own note, surfaced in --explain
}

enum RuleTier: Int, Codable, Sendable, Comparable {  // lower rawValue = higher precedence
    case protected = 0, userDeny = 1, userAllow = 2, builtinClassify = 3
}
struct RuleID: Hashable, Sendable, Codable { let raw: String }
enum RuleSource: Sendable, Codable, Hashable {
    case builtin(String), config(FilePath), profile(ProfileID), plugin(PluginID)
}

struct RuleSet: Sendable {
    let rules: [Rule]                         // compiled, sorted by (tier, specificity, order)
    let index: RuleIndex                      // §6 — path trie + predicate buckets for speed
}
```

## 4. Rule DSL (YAML)

User rules live under `config.yml` (spec 24 owns the full schema; spec 15 §4) and in profiles
(spec 15 §9). The DSL is intentionally small and readable (CC-5). Built-in rules ship compiled in
Swift but have an equivalent YAML representation for `cleaner rules dump`.

```yaml
# ~/.cleaner/config.yml  (excerpt — rules section)
rules:
  # ── TIER 1: keep these no matter what a plugin says ──────────────────────
  - id: keep-thesis
    keep:                                   # effect shorthand → Effect.keep, tier userDeny
      path: "~/Projects/thesis/**"          # → Predicate.glob (canonicalized)
    comment: "Active writing; never clean."

  - id: ignore-recent-downloads
    keep:
      all:
        - under: { anchor: downloads, glob: "**" }
        - ageNewerThan: { days: 7, basis: mtime }   # keep anything downloaded in the last week
    matchOnMissingEvidence: true            # if age unknown, err toward keeping

  # ── TIER 2: clean these that plugins don't cover (custom target) ─────────
  - id: target-vendor-cache
    target:                                 # effect → Effect.admit, tier userAllow
      path: "~/work/*/node_modules/.cache/**"
      as:
        category: developer-cache
        risk: safe
        recoverability: manual
        disposition: stage
        rationale: "Project vendor build cache; regenerated on next build."

  - id: bump-archives-danger
    when:                                   # explicit predicate form
      all:
        - category: developer-archive
        - sizeAtLeast: { mib: 200, of: onDisk }
    set:                                    # modification effects
      risk: dangerous                       # raise only (RE-4)
      recoverability: hard
    comment: "Large Xcode archives may be shipped builds."

  # ── TIER 3: classification convention override ───────────────────────────
  - id: stale-logs-90d
    when:
      all:
        - category: logs
        - ageOlderThan: { days: 90, basis: mtime }
    set:
      risk: safe
      lowerScoreTo: 95
      rationale: "Log rotation age exceeded; safe to reclaim."
```

Shorthands (`keep:`, `target:`, `set:`) desugar to explicit `{ tier, when, then }` at load;
`cleaner rules lint` reports the desugared, sorted rule set so users can see effective
precedence. Unknown keys → exit 6 (`config`). A `target`/`set` predicate resolving into a Tier-0
protected path → exit 6 with the offending path named (RE-1).

### 4.1 Built-in rule catalog (compiled, tier 0 & 3)

| Rule ID | Tier | When | Effect | Rationale |
|---|---|---|---|---|
| `protect.denylist.*` | 0 | `underAnchor` each Art. 5 path (`/System`, `~/Documents`, `~/.ssh`, `*.key`, `*.pem`, keychains, TM snapshot mounts, `~/.cleaner/**`) | `protect` | Constitution Art. 5, non-overridable. |
| `protect.dataless` | 0 | `isDataless` | `protect` | Never evict iCloud placeholders (spec 16 §4.4). |
| `protect.snapshot` | 0 | `snapshotRef != nil` | `protect` | Local TM snapshots read-only (spec 16 §4.3). |
| `protect.user-tagged` | 0* | `hasFinderTags` | `lowerScore`+`setRisk(medium)` | User tagged ⇒ matters (spec 16 §5). (*advisory, not hard-protect) |
| `classify.age.stale` | 3 | `ageOlderThan(baseline)` per category | `lowerScore` | Older ⇒ safer to reclaim (spec 19). |
| `classify.size.large` | 3 | `sizeAtLeast(threshold)` | `retag(large-files)` | Feed large-file view. |
| `classify.wherefroms.redownloadable` | 3 | `hasWhereFroms` | `lowerScore` | Re-downloadable ⇒ safer (spec 16 §5). |

The engine ships these as Swift values; `cleaner rules dump --builtin` renders them as the YAML
above for transparency (Principle 3).

## 5. Evaluation algorithm & conflict resolution

```swift
struct RuleEvaluator: Sendable {
    let set: RuleSet
    let clock: any ClockReading                // age predicates use injected now (Principle 5)

    /// Gate ② of the funnel (spec 13 §10). Called per raw Finding (post-scorer).
    func evaluate(_ finding: Finding) -> RuleDecision
    /// Admission pass: does any tier-2 target rule promote this path to a NEW finding?
    func admissions(for node: FSNode, roots: [ResolvedRoot]) -> [AdmitSpec]  // §5.3
}

enum RuleDecision: Sendable {
    case protected(firedBy: RuleID)                    // → isProtected finding, DM-4
    case dropped(firedBy: RuleID)                      // whitelist/ignore
    case modified(Finding, provenance: [RuleFiring])   // adjusted risk/score/disposition
    case unchanged(Finding)                            // no rule applied
}

struct RuleFiring: Sendable, Codable, Hashable {       // provenance (§7)
    let rule: RuleID
    let tier: RuleTier
    let effectSummary: String                          // "risk safe→dangerous", "kept", "score 88→95"
    let matchedOn: String                              // "glob ~/Projects/thesis/**"
}
```

### 5.1 Per-finding algorithm

```
evaluate(finding):
  matches = index.candidateRules(for: finding.item.primaryPath)      // §6 fast prefilter
             .filter { $0.enabled && predicateHolds($0.when, finding) }
             .sorted(by: precedence)                                  // tier, then specificity, RE-3

  # TIER 0 short-circuit — protected wins over everything (RE-1)
  if let p = matches.first(where: { $0.tier == .protected && hasProtect($0) }) :
      return .protected(firedBy: p.id)

  # TIER 1 — deny (keep) wins over allow/classify (RE-2)
  if let d = matches.first(where: { $0.tier == .userDeny && hasKeep($0) }) :
      return .dropped(firedBy: d.id)

  # TIER 2 & 3 — apply modification effects in precedence order, accumulating provenance.
  var current = finding; var firings: [RuleFiring] = []
  for rule in matches where rule.tier >= .userAllow:
      for effect in rule.then:
          (current, firing) = apply(effect, to: current, clampBy: RE-4)   # stricter-only
          firings.append(firing)
  return firings.isEmpty ? .unchanged(current) : .modified(current, firings)
```

### 5.2 Conflict resolution rules

1. **Cross-tier conflict** (a `keep` and a `target` both match): higher tier wins (RE-2). Recorded
   as `RuleFiring` on the winner; the loser is noted in `--explain` as "shadowed by <ruleID>".
2. **Same-tier, opposite effects** (two tier-2 rules, one `setRisk(safe)` one `setRisk(dangerous)`):
   **most-specific path wins** (longer canonical prefix / more-constrained predicate). If equally
   specific, **stricter effect wins** (dangerous > medium > safe; keep > act) — safety bias
   (Principle 1). Final tie-break: declaration order then `RuleID`.
3. **Score clamp** (RE-4): a `lowerScore(to:)` that would *raise* the score is clamped to the
   current score and emits a `RuleClamp` warning to the audit trail (Principle 3 — we don't
   silently ignore a mis-authored rule).
4. **Disposition conflict**: `.purge` from a rule is rejected outright (DM-5); `stage` vs `trash`
   → stricter/more-recoverable (`stage`) wins unless the finding's category is Trash-native.

### 5.3 Admission (tier-2 targets create new Findings)

User `target` rules can promote paths **no plugin flagged** (Art. 3 "blacklist/target"). During
the scan walk (spec 17 §4.2 driven mode), each `FSNode` under a target rule's scope that matches
its predicate and is **not** already covered by a plugin Finding is turned into a synthetic
Finding:

```
admit(node, rule):
   item = Item(primaryPath: node.path, size/allocated from node, volumeID …)     # spec 16 sizes
   finding = Finding(producedBy: "dev.cleaner.rules", category: rule.as.category,
                     risk: rule.as.baselineRisk, recoverability: rule.as.recoverability,
                     suggestedDisposition: rule.as.disposition, rationale: rule.as.rationale,
                     evidence: gathered(node))
   → still passes through gate ① (re-score, DM-2/3) and gate ③ (protected guard) like any finding
```

Admitted findings are indistinguishable downstream from plugin findings except `producedBy ==
"dev.cleaner.rules"` and a `RuleFiring` provenance entry, so audit shows the user's own rule
caused the action (Principle 8).

## 6. Compilation & indexing (performance)

Evaluating every rule against every Finding is `O(rules × findings)`. With potentially thousands
of findings and dozens of rules this is fine, but path predicates dominate; we index:

```swift
struct RuleIndex: Sendable {
    // Path trie of pathPrefix / underAnchor rules for O(path-depth) candidate lookup.
    let prefixTrie: PathTrie<RuleID>
    // Glob/regex rules bucketed by their literal prefix (the part before the first wildcard),
    // also inserted into the trie so "~/Library/Caches/**" is found by prefix ~/Library/Caches.
    let wildcardByLiteralPrefix: [FilePath: [RuleID]]
    // Non-path predicates (category/producedBy/metadata) bucketed by category & plugin.
    let byCategory: [CategoryID: [RuleID]]
    let global: [RuleID]                        // predicates with no cheap key (always, metadata-only)
}
```

`candidateRules(for: path)` walks the trie along the path components, unions the category/plugin
buckets and the small `global` set, then the evaluator runs full predicate checks only on that
candidate set. Compilation happens once per session after config load; the compiled `RuleSet` is
`Sendable` and shared across scan tasks (immutable, no locking).

Determinism: sorting the candidate list by `(tier, specificity, declOrder, id)` before applying
makes evaluation order independent of trie/dictionary iteration order (Principle 5, NFR-031).

## 7. Provenance, explainability & audit

Every safety-relevant decision records **which rule fired** (Principle 8, "why did you delete
this?" always has an answer):

- Each modified/dropped/protected Finding carries `[RuleFiring]` (rule ID, tier, effect summary,
  what it matched on). Surfaced in the TUI's per-finding detail and in `cleaner explain <path>`.
- The audit trail (spec 15 §6) `scan.finding` and `item.*` events include the firing rule IDs so
  the on-disk record is self-describing.
- `cleaner explain <path>` prints the full decision trace:

```
$ cleaner explain ~/Projects/thesis/build
 path: /Users/h/Projects/thesis/build   (canonical)
 candidate rules (5):
   [tier1] keep-thesis        glob ~/Projects/thesis/**        → KEEP  ✔ FIRED (terminal)
   [tier2] target-vendor-cache path ~/work/*/…                 → (no match: path)
   [tier3] classify.age.stale  ageOlderThan 90d                → shadowed by keep-thesis
 decision: DROPPED (kept) by rule "keep-thesis" (source: config.yml:42)
 → this path will NOT be cleaned.
```

This makes the rule engine debuggable and the tool trustworthy: a user can always see *why* a path
was kept, promoted, or reclassified.

## 8. Worked examples

### 8.1 Whitelist beats a plugin (tier 1 > plugin)

`XcodePlugin` flags `~/Projects/thesis/build` (looks like DerivedData) as `safe`. User has
`keep-thesis` (§4). Evaluation: candidate rules include `keep-thesis` (tier 1, glob match) →
terminal `dropped(firedBy: keep-thesis)`. The Finding never reaches the plan. Audit records the
firing. (RE-2: user deny beats plugin classification.)

### 8.2 User target promotes an un-flagged path (tier 2 admit)

No plugin covers `~/work/proj/node_modules/.cache`. `target-vendor-cache` (§4) matches during the
walk → `admit` a synthetic `developer-cache` Finding, `risk: safe`, `disposition: stage`. Gate ①
re-scores (say 90 → stays safe), gate ③ confirms it's under an allowed root. It appears in the
preview attributed to `dev.cleaner.rules`.

### 8.3 Same-tier conflict, most-specific wins (RE-3)

Two tier-2 rules match `~/Library/Caches/com.big.app/huge`:
`R1 = glob ~/Library/Caches/** → setRisk(safe)`, `R2 = pathPrefix ~/Library/Caches/com.big.app →
setRisk(medium)`. R2's prefix is longer (more specific) → `medium` wins. If they were equally
specific, `medium` (stricter) wins by Principle 1. Both firings logged; R1 shown as shadowed.

### 8.4 Protected beats a user target (RE-1, tier 0 absolute)

A careless user writes `target: { path: "~/Documents/old/**" }`. At **config load** this is
rejected (exit 6) because `~/Documents` is a Tier-0 protected anchor. Even if injected at runtime,
evaluation returns `.protected(firedBy: protect.denylist.documents)` — the target is inert.
Nothing under `~/Documents` is ever actionable.

### 8.5 Missing evidence is not a match (RE-5)

Rule `stale-logs-90d` (age > 90d). A log file on a `noatime` mount with unreadable mtime has
`Evidence.mtime == nil`. `ageOlderThan` over `nil` → **false**, so the rule does *not* fire and
the log keeps its plugin-assigned risk. The tool does not delete on absent evidence (Principle 1).

## Open Questions

- **OQ-18.1** Should `target` (admit) rules run during the driven walk (§5.3, cheap, one pass) or
  as a post-scan sweep over `skipped`/un-flagged paths (simpler, but re-walks)? *Leaning:
  in-walk admission for perf; confirm with spec 17 driven-mode feed.*
- **OQ-18.2** Regex safety: user-supplied `regex` predicates risk catastrophic backtracking on
  adversarial paths. Do we cap regex evaluation time / require RE2-style linear regex? *Leaning:
  timeout per predicate + a lint warning; investigate a linear-regex engine (spec 36 threat).*
- **OQ-18.3** Should `matchOnMissingEvidence` be allowed on non-keep effects at all, or strictly
  keep-only (fail-safe)? *Leaning: keep-only; a `target`/`set` firing on unknown evidence is
  unsafe (RE-5).*
- **OQ-18.4** Rule precedence when a plugin *and* a rule both set risk — does the scorer (gate ①)
  or the rule (gate ②) have the final say on a *raise*? *Leaning: scorer sets the ceiling (DM-2);
  a rule may raise risk further (stricter) but the displayed score is the scorer's — coordinate
  with spec 22.*
- **OQ-18.5** Do we support rule *priorities* as an explicit integer (like firewall rules) in
  addition to tier + specificity, for power users who want manual ordering? *Leaning: no for v1;
  tier + most-specific covers it and is less foot-gun-prone.*
- **OQ-18.6** Hot-reload: should editing `config.yml` mid-session re-compile the `RuleSet`?
  *Leaning: no; rules are frozen at session start for determinism/idempotence (NFR-030/031).*

## Dependencies

**Consumes:** 00-constitution (Art. 4 safety model & score ceiling, Art. 5 protected paths
non-overridable, Art. 7 exit code 6, Principles 1/3/5/8), 10-tech-stack (Yams DSL, Swift value
types), 13-plugin-architecture (§10 funnel gate ②, plugin advisory vs engine authoritative),
14-domain-model (`Finding`, `RiskLevel`, `SafetyScore` DM-2, `Recoverability`, `Disposition`
DM-5, `Evidence`, `Category`), 16-filesystem-strategy (§9 canonicalization for path predicates,
Art. 5 deny-list), 17-scan-engine (funnel invocation, driven-walk admission feed).

**Feeds:** 19-detection-algorithms (baseline risk/category the rules refine; admitted findings),
20-cleanup-engine (honors gated `Disposition`, refuses rule-`.purge`), 22-safety-model (score
clamp interaction, RE-4), 24-config (owns the YAML rule schema, validation, exit-6 rejection),
25-tui (`--explain`, provenance display), 28-logging (`RuleFiring`/`RuleClamp` audit events).
