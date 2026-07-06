# 01 — Product Vision

> **Phase A · Depends on:** 00-constitution ·
> **Depended on by:** 02, 03, 04, 05, 06, 07, 38.
>
> **Status:** Draft · **Version:** 1.0 · **Owner:** Product

## 1. Purpose

This document fixes *why cleaner-cli exists*, *who it wins for*, and *how we will know it
succeeded*. Every requirement, persona, and use case downstream MUST trace back to the
vision, positioning, and success metrics stated here. Where a later spec proposes a feature
that does not advance a KPI in § 7 or serve an outcome in § 3, that feature SHOULD be
challenged or deferred to the roadmap (spec 38).

This is a *what/why* document (SpecKit stage "Specify", Constitution Article 9). It states no
implementation. It inherits the ten Core Principles (Constitution Article 1) verbatim and
treats **Safety over savings** as the north star that overrides all growth ambition.

## 2. Vision statement

> **cleaner-cli is the disk-cleaning tool developers trust because it shows its work.**
> It reclaims the maximum recoverable space on a macOS developer's disk with the safety of a
> surgeon and the transparency of an open ledger: every byte it proposes to remove is
> previewed, risk-scored, explained, and reversible — and every action is scriptable,
> auditable, and free.

A developer SHOULD be able to type `cleaner clean`, watch tens of gigabytes of caches, build
artifacts, and stale simulators be identified and safely reclaimed in under a minute, and know
— with evidence — that nothing they care about was touched. The same command MUST work
unattended in CI, emit machine-readable output, and be undone with one command if regretted.

## 3. Target outcome

The product optimizes for one dominant outcome, stated as a tension it must resolve:

> **Reclaim the maximum disk space that is genuinely safe to reclaim, and never one byte more.**

This decomposes into three commitments, ranked (lower number wins on conflict, mirroring
Constitution Article 1):

1. **Zero data loss.** No user-authored or irreplaceable data is ever lost. This is absolute
   and non-negotiable; a run that reclaims 0 bytes but loses nothing is a *success*, a run
   that reclaims 100 GB but loses one needed file is a *catastrophic failure*.
2. **Maximum safe reclaim.** Subject to (1), find and free as much space as possible —
   developer caches, build artifacts, browser/log caches, stale SDKs and simulators,
   duplicates, and large/old files (capability matrix, spec 06).
3. **Effortless trust.** The user reaches a confident decision fast, whether human at a TTY or
   a pipeline reading JSON, because the tool previews, scores, explains, and can roll back.

## 4. Positioning

cleaner-cli occupies a quadrant no existing tool fills: **developer-native, transparent,
safety-first, scriptable disk reclamation.** The table contrasts it against the categories a
target user reaches for today.

| Dimension | **cleaner-cli** | a GUI cleaner app | DaisyDisk | OmniDiskSweeper | Manual `rm -rf` |
|---|---|---|---|---|---|
| Primary form | CLI + TUI | GUI app | GUI (visualizer) | GUI (list) | Shell |
| Price / license | **Free, open** | Paid, subscription/one-off | Paid | Free | Free |
| Scriptable / CI-friendly | **Yes (JSON, exit codes)** | No | No | No | Yes (unsafe) |
| Previews before deleting | **Yes, risk-scored** | Partial | Visualizes only; you delete | Visualizes only | No |
| Reversible (staging/rollback) | **Yes, default** | Trash for some | N/A | N/A | No |
| Explains *why* an item is junk | **Yes (evidence)** | Marketing-level | No | No | No |
| Developer-junk literacy (Xcode, Docker, node_modules, simulators, SPM/DerivedData) | **First-class plugins** | Some, generic | None (size only) | None (size only) | Whatever you know |
| Audit trail | **NDJSON per action** | No | No | No | Shell history at best |
| Extensible by third parties | **Plugin protocol** | No | No | No | N/A |
| Native macOS API depth (APFS clones, Spotlight, Launch Services) | **Deep** | Deep | Deep (sizing) | Moderate | None |
| Runs headless / over SSH | **Yes** | No | No | No | Yes |

**Positioning statement.** *For macOS developers who watch their SSD fill with invisible
caches and build junk, cleaner-cli is a native command-line disk cleaner that reclaims the
most space safely — previewing, scoring, and reversing every action — unlike paid GUI tools
(popular GUI cleaners) that are opaque and unscriptable, and unlike manual `rm -rf` that is
fast but dangerous.*

### 4.1 Why each alternative loses for our user

- **a GUI cleaner app** — polished but paid, opaque ("Smart Scan" is a black box), GUI-only, not
  scriptable, weak developer-junk literacy, and its trust model is marketing rather than an
  auditable ledger. A user cannot put it in a Makefile or a CI job.
- **DaisyDisk / OmniDiskSweeper** — excellent *visualizers* of where space went, but they
  stop at "here is a big folder"; the human still decides and deletes, with no risk scoring,
  no reversibility, no developer semantics, and no automation.
- **Manual `rm -rf` / shell one-liners** — infinitely scriptable and free, but the failure
  mode is unbounded (`rm -rf $VAR/` with an empty `VAR`), there is no preview, no evidence,
  no rollback, and no shared knowledge of *what* is safe to delete. This is the status quo we
  are replacing, and its pain is quantified in spec 02.

## 5. Differentiators (the durable moat)

1. **Native-first depth.** Direct macOS framework use (Constitution principle 4, spec 10)
   yields *truthful* reclaim numbers (APFS clone/sparse-aware allocated size, CC-10) and
   developer-junk literacy no generic sweeper matches.
2. **Plugin architecture.** New cleaning capability ships as a plugin without core edits
   (Constitution principle 7); the community and third parties extend coverage. No competitor
   is extensible.
3. **Safety-first, provably.** Preview-first / confirm-second / execute-third, staging with
   one-command rollback, hard engine invariants and a protected-path deny-list (Constitution
   Articles 4–5). Trust is *demonstrated* through evidence and an audit trail, not asserted.
4. **First-class TUI *and* headless CLI.** A rich interactive experience (spec 25) for humans
   and a clean JSON/exit-code contract (Article 7) for automation — the same engine, the same
   measurement code, no second-class path.

## 6. Three-year north star

By the end of the v3 horizon (roadmap, spec 38), cleaner-cli SHOULD be:

> **The default, trusted way macOS developers manage disk space — the `brew` of disk
> hygiene** — a tool a developer installs on day one of a new machine, runs without thinking,
> recommends by reflex, and never fears.

Concretely, the north star implies, over three years:

- **Trust is the brand.** "It has never lost my data" is the dominant sentiment; zero-data-loss
  remains at 100% (§ 7). Trust, not features, is the growth engine.
- **Ubiquity in the developer toolchain.** Present in dotfiles, onboarding scripts, CI images,
  and team runbooks. Reclamation is *automated*, not a chore someone remembers to do.
- **An ecosystem.** A healthy set of first- and third-party plugins covering toolchains we did
  not anticipate (Constitution principle 7), without the core growing unsafe.

The north star does **not** imply a GUI, a cloud service, or a subscription business; those
are explicit non-goals (§ 8) and out of v1 scope (Constitution Article 2).

## 7. Success metrics (KPIs)

Metrics are computed only from **opt-in, local-first** telemetry (Constitution principle 10,
spec 29); the product MUST function fully with telemetry off, and these KPIs MUST be
derivable from the local report/audit trail (Article 8) even for users who never share data.

| # | KPI | Definition | v1.0 target | North-star (3 yr) |
|---|---|---|---|---|
| K1 | **Zero-data-loss rate** | 1 − (sessions with an irreversible loss of user-needed data ÷ all sessions). *The primary metric; a regression here is a stop-ship.* | **100%** | **100%** |
| K2 | **Median reclaim per run** | Median actual on-disk bytes freed per `clean` (allocated size, CC-10), first run on a "dirty" dev machine. | ≥ **10 GB** | ≥ **15 GB** |
| K3 | **Time-to-first-value (TTFV)** | Wall-clock from first `cleaner` invocation to first previewed, actionable reclaim on a typical dev machine. | ≤ **60 s** | ≤ **30 s** |
| K4 | **Rollback success rate** | Staged items restored to original location without error ÷ rollback attempts. | **100%** | **100%** |
| K5 | **Preview accuracy** | 1 − mean(|reclaim_reported_dryrun − reclaim_actual| ÷ reclaim_actual). Truth-in-reporting (principle 3). | ≥ **98%** | ≥ **99.5%** |
| K6 | **False-positive rate** | Items the user rejects at preview or reports as wrongly flagged ÷ items proposed. Measures detection trust. | ≤ **2%** | ≤ **0.5%** |
| K7 | **Adoption** | Monthly active installs (Homebrew analytics + opt-in). Proxy for reach. | Baseline established | Category default |
| K8 | **Automation ratio** | Runs invoked non-interactively (`--yes`/`--ci`/policy) ÷ all runs. Proxy for scriptability value. | ≥ **20%** | ≥ **50%** |
| K9 | **Repeat usage** | Users with ≥ 2 runs in 30 days ÷ new users. Proxy for retained trust. | ≥ **40%** | ≥ **70%** |
| K10 | **Doctor-clean rate** | `cleaner doctor` runs exiting 0 (healthy) ÷ all doctor runs. Health of the install base. | ≥ **90%** | ≥ **98%** |

**Guardrail metric.** K1 (zero-data-loss) is a *guardrail*: any change that risks it MUST be
gated regardless of its effect on K2–K10. This encodes Constitution principle 1 as a metric.

## 8. Non-goals (v1.0)

The following are explicitly **out of scope** (aligns with Constitution Article 2). Listing
them here prevents scope creep in downstream specs; each MUST NOT leak requirements into v1.

1. **No GUI.** CLI + TUI only. A graphical app is not planned for v1 and is not the north star.
2. **No cloud, no fleet, no remote management.** Local, single-machine, single-user-session.
3. **No scheduling daemon.** The tool does not install a background agent in v1; users may
   wire it into `cron`/`launchd`/CI themselves. (A managed scheduler is a v2.x roadmap item.)
4. **No remote-model AI recommendations.** No network calls in the core cleaning path
   (principle 10). Heuristics are local and explainable, not model-backed over the wire.
5. **No plugin/rule marketplace** in v1 (plugins are statically linked, CC-8).
6. **Not a general file manager, backup tool, or antivirus.** It reclaims reclaimable junk;
   it does not organize, back up, or scan for malware.
7. **Not a Linux/Windows tool.** macOS-only; native-first depth is the moat (spec 10).
8. **Not a "maximize savings at any cost" tool.** It will *decline* to delete when safety is
   uncertain. Aggressive, unexplained deletion is an anti-feature.

## 9. Vision-to-spec traceability (forward links)

| Vision element | Realized/constrained by |
|---|---|
| Target outcome § 3 | 06 (functional reqs), 22 (safety model) |
| Positioning § 4 (scriptable) | 08 (command reference), 26 (CLI UX), 34 (CI/CD) |
| Differentiator: native depth | 10 (tech stack), 16 (filesystem), 19 (detection) |
| Differentiator: plugins | 13 (plugin architecture), `specs/plugins/` |
| Differentiator: safety | 22 (safety model), 21 (rollback), 23 (permissions) |
| Differentiator: TUI + headless | 25 (TUI), 26 (CLI UX) |
| KPIs § 7 | 29 (telemetry), 28 (logging/audit), 30 (benchmarks) |
| Non-goals § 8 | 38 (roadmap) |

## Open Questions

- **OQ-01.1** Is K2's "≥ 10 GB median reclaim" calibrated against real developer machines, or
  a placeholder? A benchmarking sweep (spec 30) on representative "dirty" dev disks SHOULD set
  the number before v1 sign-off. *Default: treat as provisional pending data.*
- **OQ-01.2** How is K1 (zero-data-loss) *measured* without violating privacy? Proposed: a
  local, opt-in "regret" signal (`cleaner rollback` invoked + user-tagged as data-loss) plus
  crash/abort audit events — never file contents. Needs telemetry-spec (29) confirmation.
- **OQ-01.3** Does "developer" over-narrow the vision? Prosumer/power-user personas (spec 03)
  overlap heavily; decide whether marketing positioning stays dev-first or broadens. *Leaning:
  dev-first for focus in v1, prosumer as a served-but-not-targeted segment.*
- **OQ-01.4** Should K7 (adoption) have an absolute target, or stay "baseline"? Depends on
  whether opt-in analytics give a trustworthy count. Defer number to post-launch.
- **OQ-01.5** Is "the `brew` of disk hygiene" (§ 6) the right north-star metaphor, or does it
  imply a package-manager scope we do not intend? Revisit with the roadmap (spec 38).

## Dependencies

**Consumes:** 00-constitution (principles 1–10, Article 2 scope boundary, Article 4 risk
levels, Article 7 exit codes) — the vision inherits and MUST NOT contradict these.

**Feeds:** 02-problem-statement (quantifies the pain this vision addresses), 03-personas (who
the outcomes serve), 04-user-stories and 05-use-cases (concrete realizations of the outcome),
06-functional-requirements (features must trace to § 3/§ 7), 07-nonfunctional-requirements
(TTFV/performance KPIs), 29-telemetry (KPI instrumentation), 38-future-roadmap (north star,
non-goals sequencing).
