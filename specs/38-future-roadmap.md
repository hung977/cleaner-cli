# 38 — Future Roadmap

> **Phase H · Depends on:** 00-constitution (Article 2 scope boundary, Article 10 CC-decisions),
> 06-functional-requirements, 08-command-reference, 10-tech-stack, 13-plugin-architecture ·
> **Depended on by:** release planning (spec 33), ADR-0008 (deferred plugin models),
> ADR-0011 (distribution), ADR-0012 (telemetry).
>
> This spec sequences the product from a minimal, provably-safe MVP to a fleet-managed
> platform. It is the **single source of truth for what is v1 vs. deferred**. Constitution
> Article 2 draws the v1.0 scope boundary; this document owns everything on the far side of it
> and the ordering that gets us there. Nothing here may leak a requirement back into v1 (Article 2).

---

## 1. Purpose & how to read this

The roadmap answers three questions for every capability:

1. **When** — which milestone (MVP / v0.5 / v1.0 / v2.x / v3.x).
2. **Why then** — the sequencing constraint (what it depends on, what it unblocks).
3. **Exit criteria** — the objective, testable gate that closes the milestone.

Milestones are **capability gates, not calendar dates.** A milestone ships when its exit
criteria pass, not when a quarter ends. Versions follow SemVer (spec 33); the roadmap fixes
*ordering and content*, release planning fixes dates.

**Guiding rule (Constitution Article 1, principle 1 — Safety over savings):** every milestone
must strengthen or preserve the safety model. No milestone trades reversibility, preview-first,
or truth-in-reporting for a new feature. AI, automation, and third-party plugins (v2+) are
gated behind *more* safety machinery, never less.

---

## 2. Milestone overview

| Milestone | Theme | One-line goal |
|---|---|---|
| **MVP (v0.1)** | Prove the safety spine | Analyze + a handful of provably-safe plugins, with the full preview→confirm→stage→rollback loop and JSON output, so the core promise ("never lose data") is demonstrable end-to-end. |
| **v0.5 beta** | Breadth + hardening | Most cleaning plugins, the diagnostic/reporting/config/profile surface, the complete safety model, and staging/rollback hardened under fault injection. |
| **v1.0 production** | Ship it | Every v1 FR from the brief, the full-screen TUI, notarized Homebrew distribution, complete test/benchmark/safety suites, and user docs. This is the Article 2 scope boundary. |
| **v2.x** | Intelligence + autonomy | AI-assisted recommendations (local-first, privacy-preserving), scheduling via a launchd agent, self-update, and dynamic/third-party plugins with a published SDK. |
| **v3.x** | Platform + fleet | Plugin & rule marketplaces, remote/fleet management, team policies, and dashboards. |

---

## 3. MVP (v0.1) — Prove the safety spine

**Goal.** Make the central, differentiating promise real and demonstrable: *the tool reclaims
space and can always give it back.* A user (or a test) can analyze a disk, clean three
low-risk categories, see an honest reclaim number, and roll every byte back. If we cannot do
this flawlessly, no amount of breadth matters.

**Scope.**

- **Commands:** `analyze` (FR-070), `clean` (FR-075, stage-only), `staging list|restore|purge`
  (FR-087/088/089), `report` (FR-073, human + JSON), `doctor` (minimal: OS, TTY, FDA, staging
  integrity — FR-072 subset), `version`, `completion`.
- **Plugins (3, all baseline 🟢):** `TrashPlugin` (FR-037, report + purge disposition),
  `DerivedDataPlugin` (FR-021), `NodePlugin` restricted to the **npm cache** slice of FR-025
  (`~/.npm/_cacache`) — deliberately *not* `node_modules` (that's 🟡, deferred to v0.5).
- **Safety model (minimum viable):** the Article 4.4 hard invariants enforced centrally
  (FR-110), the Article 5 deny-list, risk icons 🟢🟡🔴 with a coarse scorer, `--dry-run`
  (FR-082), `--yes` (FR-083), typed-confirm scaffolding for 🔴 (even if no 🔴 plugin ships yet).
- **Reclaim measurement:** allocated-size truth (CC-10 / ADR-0010) from day one — dry-run and
  real-run share one measurement path (principle 3). This cannot be retrofitted honestly, so
  it is MVP-critical.
- **Output:** `--json` with `schemaVersion` (FR-084), stdout/stderr contract (spec 08 §3),
  exit-code contract (Article 7).
- **TUI (basic):** linear progress + a plain preview/confirm prompt. **Not** the full-screen
  alternate-screen TUI — that is v1.0. Degrades to plain output with no TTY.
- **Infra:** SPM package skeleton, module split (spec 12), Swift Testing harness + the virtual
  filesystem fixture layer (spec 31), audit NDJSON sink (FR-099).

**FR / spec areas touched.** FR-001–002, FR-021, FR-025 (cache slice), FR-037, FR-070,
FR-073, FR-075, FR-082–084, FR-087–089, FR-099, FR-110–112. Specs 10–17, 20, 21, 22 (core),
28, 31.

**Exit criteria.**

1. **Round-trip proof:** for each of the 3 plugins, an automated test cleans a synthesized tree
   and `staging restore` returns it byte-for-byte identical (checksum + metadata), across
   same-volume and cross-volume staging (FR-087 copy-then-verify).
2. **Truth check:** dry-run projected reclaim equals real-run measured reclaim on the fixture
   set, within 0 bytes for non-clone data and correctly discounted for APFS clones (ADR-0010).
3. **Invariant check:** a red-team fixture that tries to make a plugin escape its roots / hit
   the deny-list / follow an escaping symlink is aborted with exit `8` (FR-110).
4. **Idempotence:** `clean` run twice finds nothing new the second time (FR-112).
5. **Contract:** `--json` output validates against the v1 schema; exit codes match Article 7;
   `cleaner analyze --json | jq` is byte-clean (no chrome on stdout).

**Deliberately excluded from MVP (and why).** Full TUI (breadth of plugins matters more first);
🟡/🔴 plugins (prove the spine on 🟢 only); docker/xcrun/brew shell-out adapters (native-only
first, adapters add a threat surface — spec 36); notarized distribution (dev builds are fine to
validate the spine).

---

## 4. v0.5 beta — Breadth + hardening

**Goal.** Cover the long tail of cleaning categories and stand up the operator surface
(diagnose, configure, profile, report), while turning the "minimum viable" safety model into
the *complete* one. This is where the tool becomes broadly useful and where staging/rollback
earns production trust.

**Scope.**

- **Plugins — the rest of the developer + system set (FR-020–040):** Xcode, Simulators,
  SwiftPM, CocoaPods, full Node (incl. `node_modules` as 🟡), Python, Ruby, JVM/Gradle/Maven,
  Android, Docker, Homebrew, Chrome/Safari cache, Logs, Crash reports, Mail downloads, Generic
  cache, Temp files, Build artifacts. Includes the **shell-out fallback adapters**
  (`xcrun simctl`, `docker system df/prune`, `brew cleanup`) — each behind the isolated,
  argument-escaped, timeout-bounded adapter contract (spec 13, spec 36).
- **Detection & audit (FR-050–061):** `audit` command with unused-apps, orphan packages,
  obsolete SDKs, stale DerivedData, old runtimes/archives, duplicate/large/old file detection
  (FR-003–005), symlink/hardlink/sparse/snapshot awareness (FR-059).
- **Full safety model (spec 22):** the weighted safety scorer with evidence-driven scoring,
  recoverability classes, per-plugin risk defaults, dedup across overlapping plugins (FR-042),
  plugin-failure isolation (FR-113).
- **Operator surface:** `doctor` complete (FR-072, incl. `--fix`), `config get|set|edit|validate`
  (spec 24), `profile` with the three built-ins (FR-095), `report` in Markdown/HTML,
  `--include/--exclude` selector grammar (FR-094), whitelist/target rules (FR-096/097).
- **Dispositions:** `--trash` (FR-090) and `--no-stage` purge escalation (FR-089) with typed
  confirmation.
- **Permissions:** Full Disk Access detection + scoped Authorization Services elevation (FR-098).
- **Hardening:** cancellation (FR-091) + resume checkpoints (FR-092); crash/kill fault injection
  on staging; audit-trail completeness.

**FR / spec areas touched.** FR-003–005, FR-020–042, FR-050–061, FR-071–072, FR-088–098,
FR-113. Specs 18, 19, 22, 23, 24, 27, all `plugins/*`.

**Exit criteria.**

1. **Coverage:** every MUST cleaning FR (FR-020–040) and MUST detection FR (FR-050–061) has a
   passing plugin/detector with a fixture-backed test.
2. **Safety-model conformance:** the scorer's risk mapping (Article 4.2) is exercised by
   parameterized tests; no plugin can raise a score above the scorer ceiling without an ADR.
3. **Fault injection:** SIGKILL the process mid-clean at N staged, M unstaged; on restart,
   `doctor --fix` repairs the staging index and no item is lost or double-counted; partial runs
   report exit `3` with a per-item reason (FR-093).
4. **Adapter safety:** each shell-out adapter is fuzzed for argument injection and enforces its
   timeout; a hung adapter cancels cleanly (spec 36 checks pass).
5. **Config/profile round-trip:** `config validate` rejects malformed config with exit `6`;
   profiles save/apply deterministically.

**Rationale for ordering.** Breadth depends on the MVP spine (staging, invariants, measurement)
being proven — adding 20 plugins onto an unproven safety core would be reckless (principle 1).
Adapters come now, not in MVP, because they widen the threat surface and need the full threat
model (spec 36) in place.

---

## 5. v1.0 production — Ship the brief

**Goal.** Deliver every capability in the Constitution Article 2 v1.0 scope, at production
quality: the full-screen TUI, notarized distribution, complete test/benchmark/safety suites,
and documentation. **This milestone *is* the Article 2 scope boundary** — nothing beyond it is
v1.

**Scope.**

- **Full TUI (spec 25, ADR-0004):** the owned component layer — alternate-screen + raw mode,
  double-buffered flicker-free renderer, `ProgressBar`/`Spinner`/`Tree`/`Table`/`MultiSelect`/
  `Confirm`/`Summary`/`KeyRouter`, themes, correct emoji/East-Asian width, `SIGWINCH` resize,
  and the Volumes→Categories→Plugins→Findings→Items navigation (spec 09, FR-076). Full plain
  fallback for non-TTY / `NO_COLOR` / `--no-tui` / `--ci`.
- **Commands complete:** `optimize` (FR-074), `plugins list|info`, everything in spec 08 except
  the v2 `self-update` stub (which ships as a stub returning exit `10`).
- **All v1 FRs closed:** FR-001–113, with the traceability matrix (spec 06 §9) fully populated —
  every FR → ≥1 US, ≥1 UC, ≥1 test, ≥1 module (Article 9).
- **Quality suites:** benchmark thresholds enforced in CI (spec 30, package-benchmark),
  performance targets met on a 4 TB / millions-of-files fixture (principle 9), snapshot tests of
  rendered TUI frames (spec 31), the safety/red-team suite green.
- **Distribution (ADR-0011):** universal binary (arm64 + x86_64), Developer-ID signed +
  **notarized + stapled**, shipped via a Homebrew tap and GitHub Releases with checksums
  (spec 32/33).
- **Docs:** `--help` on every node, man page, README/usage guide, safety-model explainer.
- **Telemetry (ADR-0012):** off by default, local-only; the `swift-metrics` no-op backend wired
  but dark unless explicitly opted in (spec 29).

**FR / spec areas touched.** All FR-001–113; specs 25, 26, 30, 31, 32, 33, 34, 35, 36, 37, 39.

**Exit criteria.**

1. **FR closure:** 100% of MUST FRs implemented and traced; SHOULD FRs either done or deferred
   with an ADR (Constitution Article 11 / FR priority rules).
2. **TUI acceptance:** snapshot tests of rendered frames pass across widths (incl. narrow +
   emoji-heavy rows); plain fallback verified under `--no-tui`, `NO_COLOR`, piped stdout, CI.
3. **Performance:** all spec 30 benchmark thresholds green in CI on the large fixture; memory
   stays bounded; scan is cancellable within the NFR latency.
4. **Trust:** notarization passes Apple's Gatekeeper check on a clean machine; `spctl`/`stapler`
   validate; Homebrew formula installs and `cleaner doctor` reports healthy.
5. **Safety sign-off:** security review (spec 35) and threat model (spec 36) checklists closed;
   risk register (spec 39) has no open high risks.

---

## 6. v2.x — Intelligence + autonomy

Everything here is **explicitly out of v1** (Article 2). Each feature is additive and gated
behind extra safety, privacy, or trust machinery. Sequenced so that the *plugin SDK* and
*dynamic loading* land before third-party plugins can exist.

### 6.1 AI-assisted recommendations (v2.0)
- **Local heuristics first:** a recommendation engine that ranks opportunities and suggests
  profiles from *local* signals (usage recency, reclaim/effort ratio, historical restore rate) —
  **no network, no model** in the default path (principle 10).
- **Optional LLM-assist (opt-in, privacy-preserving):** an explicitly opt-in mode that can use a
  local on-device model, or a remote model only with informed consent, sending **metadata not
  file contents** (sizes, categories, ages — never paths of user content, never file bytes).
  Off by default; a signed policy governs any automation acting on AI suggestions. Recommendations
  are *advisory* — they never bypass preview→confirm→stage (principle 1). Ties to ADR-0012
  (telemetry/privacy) as the precedent for opt-in-only network behavior.

### 6.2 Scheduling & automation — launchd agent (v2.1)
- A `LaunchAgent` that runs curated `optimize`/`clean` passes on a schedule, governed strictly by
  a **signed automation policy** (spec 23) — the only non-interactive path allowed to dispose
  without a live human, and it still stages by default (principle 2). Never auto-cleans 🔴.
  Depends on v1 staging + policy being rock-solid.

### 6.3 Self-update (v2.1)
- Turn the v1 `self-update` **stub** into a real, signature-verified updater (Sparkle-style or
  a notarized delta), verifying the notarized signature before applying. Network I/O is now
  allowed **only** in this explicitly-invoked command, never in the cleaning path.

### 6.4 Dynamic / third-party plugins + published SDK (v2.2)
- Move from v1's in-process, statically-linked plugins (ADR-0008) to **dynamically loaded**
  plugins. Two candidate mechanisms, decided by a fresh ADR at the time: **XPC out-of-process**
  (best isolation, matches the safety posture) or signed **dylib** loading. Third-party plugins
  MUST be sandboxed, capability-scoped (declared roots enforced by the engine, not trusted), and
  signature-checked. Publish the **Plugin SDK**: the stable `CleanerPlugin` protocol, host API,
  test harness, and packaging format. This is the enabler for the v3 marketplace.

**Exit criteria (v2 family).** Recommendation engine measurably improves reclaim-per-confirm on
a benchmark without increasing restore rate; scheduling runs only under a valid signed policy and
is fully audited; self-update refuses unsigned/unnotarized payloads; a sample third-party plugin
runs sandboxed and cannot escape its declared roots (engine-enforced), proven by red-team tests.

**Why deferred to v2 (not v1).** Article 2 explicitly defers AI, scheduling daemons, and
dynamic/third-party plugins. Each adds a network, autonomy, or code-loading surface that must
not exist in the safety-first v1. Static in-process plugins (ADR-0008) are the correct v1 choice
precisely because they carry no dynamic-loading threat surface.

---

## 7. v3.x — Platform + fleet

The transition from a personal tool to a managed platform. All **out of v1 scope** (Article 2:
cloud, remote/fleet, marketplaces).

- **Plugin marketplace (v3.0):** a curated registry to discover/install signed third-party
  plugins built on the v2.2 SDK; provenance, signature, and capability review are prerequisites.
- **Rule marketplace (v3.0):** shareable target-rule / whitelist / profile packs (e.g.
  "React Native dev", "Data science"), signed and reviewed the same way.
- **Remote / fleet management (v3.1):** manage many Macs from one control plane — inventory,
  aggregate reclaim, policy push. Requires a secure sync/transport designed under a new threat
  model; still local-execution, remote-orchestration (the engine never trusts the network to
  authorize a deletion).
- **Team policies (v3.1):** org-level signed policies extending spec 23 — allow/deny plugin sets,
  mandatory whitelists, retention rules — enforced locally, distributed centrally.
- **Dashboards (v3.2):** fleet-wide reclaim/health dashboards fed by opted-in, aggregated,
  privacy-preserving metrics (still governed by ADR-0012's opt-in-only rule).

**Exit criteria (v3 family).** A plugin/rule can be published, signed, discovered, installed,
and revoked; a policy pushed from the control plane is enforced locally and audited; fleet
dashboards reflect only opted-in aggregate data with no user-content leakage.

---

## 8. Feature-by-version matrix

Legend: ✅ shipped · ◑ partial/subset · ▹ planned this milestone · — not present.

| Capability | MVP v0.1 | v0.5 beta | v1.0 | v2.x | v3.x |
|---|---|---|---|---|---|
| `analyze` (usage + storage report) | ◑ core | ✅ | ✅ | ✅ | ✅ |
| Large/dupe/old-file detection (FR-003–005) | — | ✅ | ✅ | ✅ | ✅ |
| `audit` advisories (FR-050–061) | — | ✅ | ✅ | ✅ | ✅ |
| `clean` (preview→confirm→dispose) | ◑ stage-only | ✅ | ✅ | ✅ | ✅ |
| Staging / restore / purge (FR-087–089) | ✅ | ✅ hardened | ✅ | ✅ | ✅ |
| macOS Trash disposition (`--trash`, FR-090) | — | ✅ | ✅ | ✅ | ✅ |
| Reclaim = allocated size (CC-10) | ✅ | ✅ | ✅ | ✅ | ✅ |
| JSON output + exit-code contract | ✅ | ✅ | ✅ | ✅ | ✅ |
| Plugins: Trash, DerivedData, npm-cache | ✅ | ✅ | ✅ | ✅ | ✅ |
| Plugins: full dev + system set (FR-020–040) | — | ✅ | ✅ | ✅ | ✅ |
| Shell-out adapters (docker/xcrun/brew) | — | ✅ | ✅ | ✅ | ✅ |
| Full safety scorer (spec 22) | ◑ coarse | ✅ | ✅ | ✅ | ✅ |
| `doctor` | ◑ subset | ✅ | ✅ | ✅ | ✅ |
| `optimize` | — | ◑ | ✅ | ✅ | ✅ |
| `config` / `profile` (+ built-ins) | — | ✅ | ✅ | ✅ | ✅ |
| Whitelist / target rules (FR-096/097) | ◑ deny-list | ✅ | ✅ | ✅ | ✅ |
| Permissions / FDA elevation (FR-098) | ◑ detect | ✅ | ✅ | ✅ | ✅ |
| Cancellation + resume (FR-091/092) | ◑ cancel | ✅ | ✅ | ✅ | ✅ |
| Basic TUI (linear) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Full-screen TUI (spec 25) | — | — | ✅ | ✅ | ✅ |
| Notarized Homebrew distribution (ADR-0011) | — | ◑ dev | ✅ | ✅ | ✅ |
| Benchmark/test/safety suites complete | ◑ | ◑ | ✅ | ✅ | ✅ |
| AI recommendations (local heuristics) | — | — | — | ✅ | ✅ |
| AI LLM-assist (opt-in, privacy-preserving) | — | — | — | ✅ | ✅ |
| Scheduling / launchd agent | — | — | — | ✅ | ✅ |
| Self-update (real) | — | — | ▹ stub | ✅ | ✅ |
| Dynamic / third-party plugins (dylib/XPC) | — | — | — | ✅ | ✅ |
| Published Plugin SDK | — | — | — | ✅ | ✅ |
| Plugin marketplace | — | — | — | — | ✅ |
| Rule marketplace | — | — | — | — | ✅ |
| Remote / fleet management | — | — | — | — | ✅ |
| Team policies | — | — | — | ◑ policy file | ✅ |
| Dashboards | — | — | — | — | ✅ |

---

## 9. Dependency / sequencing graph

Arrows mean "must exist before". The spine is deliberately narrow: everything hangs off staging
+ invariants + honest measurement.

```
                    ┌──────────────────────── MVP (v0.1) ────────────────────────┐
                    │  SPM skeleton + module split (spec 12)                      │
                    │        │                                                    │
                    │        ▼                                                    │
                    │  Allocated-size measurement (ADR-0010) ──┐                  │
                    │        │                                 │                  │
                    │        ▼                                 ▼                  │
                    │  Hard invariants + deny-list ──►  Staging + rollback        │
                    │  (FR-110, Article 5)              (FR-087/088/089)          │
                    │        │                                 │                  │
                    │        └──────────────┬──────────────────┘                  │
                    │                       ▼                                     │
                    │           3 safe plugins + analyze + clean(stage)           │
                    │                       │                                     │
                    │                       ▼   JSON + exit-code contract         │
                    └───────────────────────┼─────────────────────────────────────┘
                                            ▼
        ┌────────────────────────── v0.5 beta ──────────────────────────┐
        │  Full safety scorer (spec 22) ◄── needs proven spine           │
        │        │                                                       │
        │        ├─► All cleaning plugins (FR-020–040) + adapters        │
        │        │        ▲ needs threat model (spec 36) for adapters    │
        │        ├─► Detection/audit (FR-050–061)                        │
        │        ├─► config / profile / doctor / permissions             │
        │        └─► staging hardened (fault injection)                  │
        └───────────────────────────┼───────────────────────────────────┘
                                    ▼
        ┌────────────────────────── v1.0 ───────────────────────────────┐
        │  Full-screen TUI (spec 25) ◄── needs stable data model         │
        │  optimize · benchmarks · docs                                  │
        │  Notarized Homebrew distribution (ADR-0011) ◄── needs GA build │
        │  ===== Article 2 scope boundary =====                          │
        └───────────────────────────┼───────────────────────────────────┘
                                    ▼
        ┌────────────────────────── v2.x ───────────────────────────────┐
        │  Local recommendation engine (no network)                     │
        │        └─► optional LLM-assist (opt-in, ADR-0012 precedent)    │
        │  Signed automation policy (spec 23) ──► launchd scheduling     │
        │  Self-update (notarized signature verify) ◄── needs ADR-0011   │
        │  Plugin SDK ──► dynamic loading (XPC/dylib, new ADR vs 0008)   │
        │        │                                                       │
        └────────┼───────────────────────────────────────────────────────┘
                 ▼   (SDK + dynamic loading + signing are prerequisites)
        ┌────────────────────────── v3.x ───────────────────────────────┐
        │  Plugin marketplace ◄── SDK + signing                          │
        │  Rule marketplace ◄── rules/profiles (v0.5)                    │
        │  Fleet management + team policies ◄── policy engine (spec 23)  │
        │  Dashboards ◄── opt-in aggregated metrics (ADR-0012)           │
        └────────────────────────────────────────────────────────────────┘
```

**Critical path to v1.0:** measurement → invariants → staging → plugins → safety scorer →
TUI → notarized distribution. The two hardest-to-retrofit items (honest measurement and the
hard invariants) are front-loaded into MVP on purpose.

---

## 10. Explicitly deferred — and why

| Deferred item | Earliest | Why not sooner |
|---|---|---|
| Full-screen TUI | v1.0 | Breadth of safe plugins and the safety spine matter more first; a rich TUI over an unproven core is polish on sand. Basic linear UX suffices through v0.5. |
| Shell-out adapters (docker/xcrun/brew) | v0.5 | They widen the threat surface; require the full threat model (spec 36). Native-first (principle 4) keeps MVP adapter-free. |
| 🟡/🔴 plugins & `node_modules` cleaning | v0.5 | Prove the spine on 🟢-only in MVP; medium/dangerous risk needs the full scorer + typed-confirm flow. |
| AI recommendations | v2.0 | Article 2 defers AI-backed-by-remote-model out of v1. Even local heuristics wait until there's usage history to learn from and a stable data model. |
| Remote/LLM inference | v2.0 (opt-in) | Principle 10 (no network in core path). Only ever opt-in, metadata-only, never in the cleaning path. |
| Scheduling / launchd agent | v2.1 | Non-interactive disposal needs a rock-solid signed-policy model (spec 23) and battle-tested staging first (principle 1). |
| Self-update (real) | v2.1 | Requires notarized distribution + signature verification (ADR-0011) to exist; ships as a refusing stub in v1 to reserve the command surface. |
| Dynamic / third-party plugins | v2.2 | ADR-0008 chose static in-process plugins for v1 (no dynamic-loading threat surface). Requires a published SDK, sandboxing, and a fresh ADR (XPC vs dylib). |
| Plugin / rule marketplaces | v3.0 | Depend on the v2 SDK + signing + a review/provenance pipeline. |
| Fleet management, team policies, dashboards | v3.1 | Depend on a secure transport and a new threat model; a fundamentally different (cloud) product surface than v1's local, single-machine scope (Article 2). |
| GUI app | Not roadmapped | Out of scope (Article 2); the TUI is the interactive surface. Revisit only on strong demand. |

**Scope-boundary contract (Article 2).** No deferred item above may introduce a requirement,
config key, flag, or dependency into v1 beyond the reserved *stubs* explicitly listed in spec 08
(`self-update` → exit `10`). Stubs reserve surface; they add no behavior and no network I/O.

---

## Open Questions

- **OQ-38.1** Does the local recommendation engine (v2.0) warrant a small persisted "usage
  history" store, and if so under what retention/privacy rules (coordinate ADR-0012)?
  *Leaning: yes, local-only, opt-in, short retention.*
- **OQ-38.2** For dynamic plugins (v2.2), XPC vs signed dylib as the default — decide with a
  fresh ADR when the SDK is designed; XPC leans safer, dylib leans faster/simpler.
- **OQ-38.3** Should scheduling (v2.1) ship before or after third-party plugins (v2.2)? Current
  order puts scheduling first (lower risk, reuses v1 policy). Revisit if SDK demand is higher.
- **OQ-38.4** Is a v1.5 warranted to absorb SHOULD FRs deferred out of v1.0, or do they fold
  into v2.0? *Leaning: a light v1.x train for SHOULDs, v2.0 for net-new capability.*

## Dependencies

- **Consumes:** 00 (Article 2 scope boundary, Article 10 CC-decisions), 06 (the FRs each
  milestone closes), 08 (command surface incl. v2 stubs), 10 (tech stack), 13 (plugin
  architecture → v2 dynamic-loading pivot), 22 (safety model), 23 (policy/permissions), 29
  (telemetry), 36 (threat model for adapters/dynamic plugins).
- **Feeds:** 33 (release planning attaches dates to these gates), ADR-0008 (records the v1
  static-plugin decision this roadmap defers away from), ADR-0011 (distribution), ADR-0012
  (opt-in privacy precedent for AI/telemetry/dashboards).
