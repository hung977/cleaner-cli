# 39 — Risk Register

> **Phase E · Depends on:** 00-constitution (Principles 1/9, Article 10 decisions), 10-tech-stack
> (deps, TUI immaturity), 16-filesystem-strategy (`getattrlistbulk`, APFS clones), 22-safety-model
> (`SR-###`, data-loss defense), 23-permission-model, 35-security-review (`SEC-###`), 36-threat-model
> (`THR-###`) · **Depended on by:** 33 (release go/no-go), 34 (CI gates), 38 (roadmap prioritization),
> project governance.

## 1. Purpose & scope

The single, living register of **project and product risks** for cleaner-cli — technical, safety,
security, adoption/product, schedule, and dependency. It exists so that the most dangerous
uncertainties are named, owned, scored, mitigated, and watched, rather than discovered in
production. It is the management-level companion to the mechanism-level Safety Model (spec 22) and
Threat Model (spec 36): where those specify *controls*, this tracks *whether the residual risk after
controls is acceptable*, who owns it, and what early-warning signal tells us it is materializing.

Each risk carries `RISK-###`, a category, **probability** (H/M/L), **impact** (H/M/L), a derived
**risk score**, an owner, a mitigation (usually a cross-ref to `SR-###`/`SEC-###`/`THR-###`), a
contingency, a **trigger / early-warning signal**, and a **status**. The register is reviewed at
every phase gate (Constitution Article 9) and is a **release go/no-go input** (spec 33): no risk may
be `open` at `H×H` at release without an explicit, signed acceptance.

## 2. Scoring model

- **Probability** and **Impact** each ∈ {H=3, M=2, L=1}.
- **Risk score = Probability × Impact** (1–9). Bands: **Critical 9**, **High 6**, **Medium 3–4**,
  **Low 1–2**.
- **Impact is judged safety-first** (Constitution Principle 1): any risk whose realization can cause
  *irreversible user-data loss* is scored Impact = **H** regardless of blast frequency.
- **Status** ∈ `open` · `mitigating` · `monitored` · `accepted` · `closed`.

## 3. Risk register (sortable)

Sort key suggestion: `score desc, category, id`. (H/M/L in the P and I columns; Score = P×I.)

| ID | Risk (short) | Category | P | I | Score | Owner | Status | Mitigation (cross-ref) | Contingency | Trigger / early-warning |
|---|---|---|---|---|---|---|---|---|---|---|
| **RISK-001** | **False-positive deletion of needed user data** (a plugin/scorer mislabels real data as junk) — the existential risk | Safety | M | H | **6** | Safety lead | mitigating | Layered safety model: scorer gates (SR-017/024/029), engine invariants (SR-033–039), staging-by-default recoverability (SR-052), detection test corpus (spec 31); F1/F2 must both fail (spec 22 § 2); RR-2 in spec 36 | Staging retains the item → `rollback` (spec 21); incident runbook; audit trail pinpoints scope (SEC-13) | Any user-reported wrong deletion; rollback invoked; a scorer-corpus regression; a finding actioned with `degraded` evidence |
| **RISK-002** | **Confused-deputy / TOCTOU escape** deletes the wrong target (symlink swap, path race) | Safety/Security | L | H | **3** | Safety lead | mitigating | fd-relative mutation + identity re-check (SR-061/063), no-symlink-follow (SR-035), execute-time re-validation (SR-062); THR-010/011 | Item staged → recoverable; blockedBySafety (exit 8) halts item; audit shows drift | Identity-drift aborts in telemetry; fuzz/race test flake; report shows `blockedBySafety` spikes |
| **RISK-003** | **Protected-path / deny-list bypass** (algebra bug, glob smuggling, root relaxation) | Security/Safety | L | H | **3** | Safety lead | mitigating | Canonical allow∩roots−deny with real-parent check (SR-040), unrelaxable even as root (SR-042/121), path-algebra fuzz (SEC-03); THR-013/014/050 | Exit 8 abort; hotfix; deny-list is compiled-in so no data migration needed | Path-algebra fuzz failure; any `isProtected` finding that yields a PlannedAction in tests |
| **RISK-010** | **Swift TUI ecosystem immaturity** — owning the whole TUI layer is more work/risk than budgeted (rendering, emoji width, resize) | Technical | H | M | **6** | TUI lead | mitigating | Owned `CleanerTUI` layer with tight scope + non-TTY fallback (ADR-0004, spec 25); snapshot tests of rendered frames (spec 31); degrade to plain output always available | Ship plain/`--no-tui` CLI as the guaranteed baseline; TUI polish slips to v1.1 without blocking core | Frame snapshot churn; emoji-width bugs; resize/flicker defects; TUI tasks overrunning estimates |
| **RISK-011** | **`getattrlistbulk` edge cases** — attribute-packing/alignment bugs, `ENOTSUP` on some FS, wrong sizes | Technical | M | M | **4** | FS lead | mitigating | Careful `// SAFETY:`-noted adapter + `FileManager` fallback per volume/error (spec 16 § 2); differential tests bulk-vs-Foundation on fixtures (spec 31) | Runtime-probe fallback to `FileManager.enumerator`; correctness never depends on bulk path | Differential-test mismatch; crash reports in the bulk decoder; anomalous size totals |
| **RISK-012** | **APFS clone / hardlink accounting error** — over- or under-stating reclaim, eroding "truth in reporting" | Technical/Safety | M | M | **4** | FS lead | mitigating | Shared-block exclusion (spec 14 § 6), `ReclaimConfidence.estimated` when exact extent introspection unavailable, estimate-vs-actual gap surfaced (SR-064) | Report the gap honestly; downgrade confidence rather than overstate; never claim savings not realized (Principle 3) | Estimate-vs-actual gap > 10%/100 MB (SR-064); user reports "freed less than promised" |
| **RISK-013** | **Performance/memory failure on 4 TB SSD / millions of files** — misses NFR, hangs, or OOMs | Technical | M | H | **6** | Perf lead | mitigating | Streaming enumeration, bounded memory O(depth×buffer), per-volume concurrency tuning, cancellation (spec 16 § 13, spec 17); `package-benchmark` thresholds enforced in CI (spec 30/34) | Reduce concurrency; degrade to size-only for huge trees; document limits | Benchmark threshold regression in CI; memory-high-water crossing budget; scan-time p95 slippage |
| **RISK-014** | **Swift 6 strict-concurrency friction** — sendability/actor churn slows delivery | Technical/Schedule | M | M | **4** | Arch lead | monitored | Concurrency conventions fixed (CC-3, Article 6); value-type domain (spec 14); module split to bound rebuilds (spec 12) | Isolate hot spots behind actors; accept localized `@unchecked Sendable` with review | Recurring data-race compiler errors; PRs stalled on sendability; build-time growth |
| **RISK-020** | **First-party plugin bug ships a bad heuristic** (a specific plugin over-claims junk) | Safety/Product | M | M | **4** | Plugin owners | mitigating | Per-plugin risk defaults are advisory only; engine re-scores (SR-011); plugin may only tighten (DM-2/3); per-plugin detection corpus + golden tests (spec 31) | Disable the offending plugin via config; staging recovers; patch release | Corpus regression for a plugin; spike in that plugin's `blockedBySafety`/rollback events |
| **RISK-030** | **Full Disk Access friction hurts adoption** — users don't grant it, tool seems weak, or the "granted but still denied" TCC trap frustrates | Product/Adoption | M | M | **4** | UX lead | mitigating | Graceful degradation (SR-101/106), correct FDA guidance incl. TCC-identity nuance (SR-111/112), `doctor` health (SR-108), useful unprivileged scope (spec 23 § 5.1) | Ship strong unprivileged value; improve onboarding copy; FAQ for the TCC trap | Support/issue reports about FDA; `doctor` FDA-denied rate; drop-off after first run |
| **RISK-031** | **Trust/adoption barrier** — users fear a CLI that deletes files (reputation of the category) | Product/Adoption | M | M | **4** | Product lead | monitored | Safety-first design as the *headline* (preview→confirm→execute, staging, rollback, truthful reporting); transparent audit; open threat model | Lead docs/marketing with reversibility & safety guarantees; conservative defaults (SEC-51) | Low activation; "is it safe?" dominating community questions; negative reviews citing fear |
| **RISK-032** | **Scope creep from deferred v2/v3 features** leaking into v1 (cloud, GUI, third-party plugins, daemon) | Product/Schedule | M | M | **4** | Product lead | monitored | Constitution Article 2 scope boundary; deferred surfaces gated (spec 13 § 13, spec 23 § 6, spec 38) | Cut to the capability matrix (spec 06); park requests in roadmap (spec 38) | v2 requirements appearing in v1 tickets; PRs adding dynamic-load/network/elevation code |
| **RISK-040** | **Compromised release channel / supply chain** ships a backdoored binary | Security | L | H | **3** | Release lead | mitigating | Developer-ID sign + notarize, checksum-pinned formula, pinned+audited deps, build provenance (SEC-30/31/32/33); THR-001; RR-4 | Revoke signing cert, pull release, publish advisory + verified rebuild | Notarization/checksum mismatch in CI; unexpected dependency change; typosquat tap reports |
| **RISK-041** | **Audit/staging tamper by an already-root local attacker** (detectability, not prevention) | Security | L | M | **2** | Security lead | accepted | Append-only hash-chained audit + checksummed staging (SEC-13/14); RR-1 (spec 36 § 7) — root adversary explicitly out of scope | Chain-break detection surfaces tampering; document the boundary | `doctor` audit-chain verification failure; staging checksum mismatch on restore |
| **RISK-042** | **Shell-out adapter injection or hang** (docker/simctl/brew) | Security/Technical | L | M | **2** | FS lead | mitigating | argv-only, no shell, validated args, timeout+cancel, scrubbed env (SR-131–135, SEC-11/12); THR-054/043 | Disable the adapter (native-only degrade); the plugin reports `partial` (exit 3) | Injection-corpus test failure; adapter timeout rate; malformed adapter output |
| **RISK-050** | **Schedule/estimation risk** — the 40-spec suite + owned TUI + native FS layer is large for the timeline | Schedule | M | M | **4** | Program mgmt | monitored | Phased delivery with gates (Article 9); TUI/native layers have plain-fallback baselines that de-risk critical path (RISK-010/011) | Ship v1 with plain CLI + core plugins; defer polish & long-tail plugins to v1.x | Milestone slippage; phase gate dates missed; task burn-down flattening |
| **RISK-051** | **Dependency abandonment / breaking change** (Yams, arg-parser, terminal-size helper) | Dependency | L | M | **2** | Arch lead | monitored | Minimal, pinned, audited dep set with a documented removal plan per dep (spec 10 § 11) | Vendor/fork the dep or replace with first-party code (esp. the color/size helper behind an adapter) | Upstream archival/CVE; a pinned version failing on a new Xcode/Swift; license change |
| **RISK-052** | **macOS version / API drift** (min-target debate, Spotlight/APFS API changes across 13–15+) | Technical/Dependency | M | M | **4** | FS lead | monitored | Baseline macOS 13 with runtime-probed feature gates, no hard dependency on gated APIs (spec 16 § 12); fallback columns | Fall back to baseline API + `estimated` confidence; feature-gate newer refinements | New macOS beta breaking a probe/FDA target (spec 23 OQ-23.1); deprecation warnings |

## 4. Category & score rollup

| Category | Risks | Highest score | Notes |
|---|---|---|---|
| Safety | RISK-001, 002, 003, (012, 020 shared) | **6** (RISK-001) | The existential category; data-loss impact is always H |
| Technical | RISK-010, 011, 012, 013, 014, 052 | **6** (RISK-010, 013) | TUI + native FS + perf are the build-risk cluster |
| Security | RISK-040, 041, 042, (003 shared) | **3** (RISK-040) | Well-covered by spec 35/36; residuals mostly accepted/monitored |
| Product/Adoption | RISK-030, 031, 032 | **4** | FDA friction & category trust dominate |
| Schedule | RISK-050, (014 shared) | **4** | De-risked by plain-CLI baselines |
| Dependency | RISK-051, 052 | **4** | Small pinned surface limits exposure |

No risk is currently scored **Critical (9)**. Three sit at **High (6)**: RISK-001, RISK-010,
RISK-013.

## 5. Top-5 risks — narrative

### RISK-001 — False-positive deletion of needed user data (Safety · 6 · mitigating)

The reason spec 22 exists and the reason Constitution Principle 1 outranks everything. A single
wrong byte is worse than a wrongly-kept gigabyte. The register scores impact **H** unconditionally.
Our defense is *layered and independent*: the scorer's gates (a Finder-tagged or document-typed file
is treated as protected regardless of other signals — spec 22 SR-017/024), engine invariants that fire even
if a plugin and the scorer both erred (SR-033–039), and — crucially — **staging-by-default**, which
converts most realized instances of this risk from "data loss" into "one `rollback` command"
(spec 21). The dominant *residual* (RR-2, spec 36) is a first-party plugin heuristic that
confidently mislabels genuine user data as a regenerable cache; the primary mitigation there is the
detection test corpus (spec 31) plus never letting a plugin bypass the scorer. **Early warning:** any
rollback invocation, any corpus regression, any action taken on `degraded` evidence. **Contingency:**
recover from staging, freeze the implicated plugin, run the incident runbook, use the audit trail to
scope exactly what was touched.

### RISK-010 — Swift TUI ecosystem immaturity (Technical · 6 · mitigating)

We are building a first-class TUI in a language whose TUI ecosystem is thin (ADR-0004): owned
rendering, correct emoji/East-Asian width, flicker-free diffing, resize handling. This is genuine
build risk on the critical path. The **de-risking lever is architectural**: the tool has a guaranteed
plain / `--no-tui` / JSON output path (spec 25/26) that delivers 100% of *function* without any TUI,
so TUI difficulty can slip polish to v1.1 without blocking the release of a safe, useful cleaner.
**Early warning:** frame-snapshot churn, emoji-width defects, resize/flicker bugs, TUI tasks
overrunning. **Contingency:** ship the plain baseline; treat the rich TUI as an enhancement.

### RISK-013 — Performance/memory failure at 4 TB scale (Technical · 6 · mitigating)

Constitution Principle 9 makes performance a *feature*, and the target (millions of files, 4 TB SSD,
bounded memory, responsive, cancellable) is demanding. The design answers it structurally —
streaming enumeration, streaming size sums, O(depth×buffer) memory, per-volume concurrency tuning,
`getattrlistbulk` syscall economy (spec 16 § 13) — and CI enforces `package-benchmark` thresholds
(spec 30/34) so regressions are caught mechanically. **Early warning:** any benchmark threshold
regression, memory high-water crossing budget, scan-time p95 slippage. **Contingency:** dial down
concurrency, degrade to size-only for pathological trees, document hard limits. Closely coupled to
RISK-011 (`getattrlistbulk` correctness) since the fast path is also the scalable path.

### RISK-030 — Full Disk Access friction hurts adoption (Product · 4 · mitigating)

The tool is most valuable exactly where TCC guards hardest (Library caches), yet many users won't
grant FDA, and macOS's "granted but still denied" identity trap (spec 23 SR-112) breeds
frustration. We mitigate by (a) being genuinely useful *unprivileged* (spec 23 § 5.1), (b) never
mispresenting a permission-limited scan as complete (SR-106), and (c) giving precise, context-aware
FDA guidance that explains the TCC-identity nuance instead of a generic "grant access." **Early
warning:** FDA-related support volume, `doctor` FDA-denied rate, first-run drop-off. **Contingency:**
lead onboarding with unprivileged value; publish a focused FDA/TCC FAQ.

### RISK-040 — Compromised release channel / supply chain (Security · 3 · mitigating)

Everyone who installs trusts our channel. The impact is **H** (a backdoored `cleaner` runs with the
user's full disk power), but probability is **L** given Developer-ID signing + notarization,
checksum-pinned Homebrew formula, a small pinned+audited dependency set, and recorded build
provenance (SEC-30/31/32/33, THR-001). The irreducible residual is a compromise *upstream of our
signing* (RR-4). **Early warning:** notarization/checksum mismatch in CI, an unexpected dependency
change, reports of a typosquatted tap. **Contingency:** revoke the signing certificate, pull the
release, publish an advisory and a verified rebuild.

## 6. Review cadence & governance

- **Gate reviews.** Re-scored at every SpecKit phase gate (Article 9); a risk crossing into **High
  (6)** or **Critical (9)** is escalated to the owning lead + program management.
- **Release gate (spec 33).** The register is a go/no-go input: no `open` risk at `H×H` ships without
  a written, signed acceptance; every **High** risk must be at least `mitigating` with a working
  contingency.
- **Traceability.** Safety/security risks cross-reference their mechanism: `RISK-001/002/003/012/020`
  ↔ spec 22 `SR-###`; `RISK-040/041/042` ↔ spec 35 `SEC-###` / spec 36 `THR-###`. A control removed
  or weakened in those specs MUST re-open the linked risk here.
- **Ownership.** Every risk has a named owner accountable for its mitigation, trigger monitoring, and
  status; ownerless risks are a governance defect.

## Open Questions

- **OQ-39.1** Should the register live *only* here (spec, phase-gated) or also as a lightweight
  living issue-tracker board for between-gate updates? *Leaning: this spec is the source of truth;
  mirror `open`/`mitigating` rows into the tracker for day-to-day burn-down.*
- **OQ-39.2** Is a 3×3 (H/M/L) scoring model granular enough for the safety category, or should
  safety risks use a finer impact scale given data-loss dominance? *Leaning: keep 3×3 but hard-pin
  data-loss impact to H (already done); revisit if it hides differentiation.*
- **OQ-39.3** What quantitative early-warning thresholds (e.g. rollback-rate per 1k cleans,
  benchmark-regression %) should promote a risk's status automatically? *Leaning: define per-risk SLOs
  in spec 30/34 once telemetry (opt-in) and CI baselines exist.*
- **OQ-39.4** Should RISK-041 (root-attacker tamper) stay `accepted` for v1, or does external
  audit-chain anchoring (spec 36 OQ-36.1) move it to `mitigating` in v1.1? *Leaning: `accepted` for
  v1, re-evaluate with external anchoring in v1.1/v2.*
- **OQ-39.5** Do we need an explicit *legal/liability* risk row (a cleaner that deletes data invites
  liability claims) distinct from RISK-001, or is it covered by the safety guarantees + docs?
  *Leaning: add a Product/Legal row in the next revision; for now folded into RISK-001/031.*

## Dependencies

**Consumes:** 00-constitution (Principle 1 safety-first impact weighting, Principle 9 performance,
Article 2 scope boundary, Article 9 gates, Article 10 CC decisions), 10-tech-stack (owned TUI risk,
dependency policy, benchmark tooling), 16-filesystem-strategy (`getattrlistbulk` edge cases, APFS
clone/hardlink accounting, streaming/perf model), 22-safety-model (`SR-###` data-loss defense,
staging recoverability, scorer gates), 23-permission-model (FDA friction, least-privilege),
35-security-review (`SEC-###` controls, residual findings), 36-threat-model (`THR-###`, residual
risks RR-1…RR-5).

**Feeds:** 33-release (go/no-go gate on open High/Critical risks, signed acceptances),
34-ci-cd (benchmark/perf thresholds, checksum/notarization checks as early-warning triggers),
38-future-roadmap (deferred-scope and v2 elevation/third-party-plugin risks inform prioritization),
project governance (owner accountability, gate-review cadence).
