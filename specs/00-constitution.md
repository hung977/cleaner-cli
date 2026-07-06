# cleaner-cli — Project Constitution

> **Status:** Ratified · **Version:** 1.1 · **Owner:** Architecture · **Last updated:** 2026-07-06
>
> This is the anchor document of the SpecKit suite. Every other specification MUST comply
> with the principles, conventions, and cross-cutting decisions recorded here. Where a
> downstream spec needs to deviate, it MUST record an ADR and link it back to the relevant
> article below.

---

## Article 0 — What this document is

The **Constitution** fixes the invariants that all 40+ specification documents share:
the core principles, the glossary, the naming/formatting conventions, the shared decisions
that would otherwise be re-litigated in every spec, and the map of the specification suite.

Read this first. If a term, a safety guarantee, an exit code, or a directory path appears in
any other spec, its single source of truth is here.

---

## Article 1 — Core Principles (non-negotiable)

These principles are ranked. When two principles conflict, the lower-numbered one wins.

1. **Safety over savings.** The tool exists to reclaim space, but never at the cost of
   deleting something the user needs. A byte wrongly deleted is worse than a gigabyte
   wrongly kept. Every destructive action is *preview-first, confirm-second, execute-third*.
   There is no code path that deletes user data without an explicit, informed decision
   (interactive confirmation, `--yes`, or a signed automation policy).

2. **Reversibility by default.** Nothing is `unlink()`-ed outright when a recoverable
   path exists. The default disposition is *move-to-staging* (a tool-managed Trash), not
   permanent deletion. Permanent deletion is an explicit escalation, never a default.

3. **Truth in reporting.** The tool never overstates savings, never hides what it did,
   never reports success it did not achieve. Dry-run numbers and real-run numbers use the
   same measurement code. If a step is skipped, the report says so.

4. **Native first.** Prefer a documented macOS/Foundation API over shelling out. Shell-outs
   are a fallback, are isolated behind an adapter, and are individually justified in an ADR.

5. **Determinism & idempotence.** A scan over an unchanged filesystem yields the same result.
   Running `clean` twice is safe: the second run finds nothing new to do. No operation
   depends on wall-clock randomness or undocumented ordering.

6. **Least privilege.** The tool runs as the invoking user, requests elevation only for the
   specific operations that require it, and never silently escalates. Full Disk Access and
   admin authorization are requested lazily, explained, and scoped.

7. **Extensibility without core edits.** New cleaning capability arrives as a *plugin*.
   Adding a plugin MUST NOT require modifying the engine, the CLI, or another plugin.

8. **Observability.** Every run is explainable after the fact: structured logs, an audit
   trail of every file touched, and a machine-readable report. "Why did you delete this?"
   always has an answer.

9. **Performance is a feature.** The tool must stay responsive and memory-bounded on a
   4 TB SSD with millions of files. Streaming and cancellation are designed in, not bolted on.

10. **Privacy by default.** No network calls in the core cleaning path. Telemetry is opt-in
    and off by default. Reports stay on the user's machine unless they export them. *(Narrow
    exception: the network is permitted **only** for explicit license activation/refresh, app
    auto-update, and opt-in telemetry/AI — never a per-run beacon, never in the scan/clean path.
    Details in the commercial specs, maintained in the private Pro repository.)*

11. **Safety is never behind a paywall.** cleaner-cli is open-core: the CLI (this repository) is
    free and open source; a separate paid Pro app builds on the same engine. No safety feature —
    preview, confirmation, staging, rollback, protected-path enforcement, undo, audit
    trail — may EVER be gated, degraded, nagged, or time-limited in any edition. A free user is
    exactly as safe as a Pro user. Monetization may gate *convenience, automation, visualization,
    and scale* — never *protection*, and never the ability to clean. Losing a Pro license MUST
    NOT endanger data.

---

## Article 2 — Product one-liner & scope boundary

**cleaner-cli** is a production-grade, plugin-based macOS command-line + TUI tool that
analyzes disk usage, detects reclaimable junk (developer caches, build artifacts, browser
caches, logs, duplicates, large/old files, stale SDKs & simulators), and safely reclaims
space with preview, confirmation, and rollback.

**In scope (v1.0):** everything in the capability matrix (§ spec 06). Local, single-machine,
single-user-session operation.

**Out of scope (v1.0), deferred to roadmap:** cloud sync, remote/fleet management, a GUI,
AI-assisted recommendations backed by a remote model, plugin/rule marketplaces, scheduling
daemons. These are explicitly v2.x/v3.x (§ spec 38) and MUST NOT leak requirements into v1.

---

## Article 3 — Glossary (single source of truth)

| Term | Definition |
|---|---|
| **Item** | The atomic unit a plugin reports and the engine acts on: a file, directory, or logical group (e.g. "Xcode DerivedData for project X"). Carries size, path(s), and evidence. |
| **Finding** | An Item plus the plugin's assessment (recoverability + rationale). What the user sees in a preview. |
| **Reclaim** | Space that becomes free after an Item is cleaned. Measured as *actual on-disk allocation freed*, accounting for APFS clones/sparse files, not naive logical size. |
| **Plugin** | A self-contained unit implementing the `CleanerPlugin` protocol that scans for and cleans one category of junk. |
| **Scan** | A read-only pass that produces Findings. Never mutates the filesystem. |
| **Clean / Cleanup** | The act of disposing of confirmed Items (default: move to Staging). |
| **Staging** | The tool-managed quarantine directory where "deleted" items live until purged. Enables rollback. |
| **Purge** | Permanent deletion of staged items (the only irreversible operation). |
| **Rollback** | Restoring staged items to their original location. |
| **Disposition** | What happens to an Item: `stage`, `purge`, `skip`. The macOS Trash is itself *staged* (moved to Staging), never purged in place. |
| **Evidence** | The metadata a plugin gathered to justify a Finding (mtime, xattrs, Spotlight kind, Launch Services registration, etc.). Recorded for auditability. |
| **Risk Level / Safety Score** | *(Internal, vestigial.)* The `RiskLevel`/`SafetyScore` types still exist in the domain code as optional metadata a plugin may set, but they are **not** used for selection, display, or safety enforcement, and are not surfaced to the user. The safety model rests on the three guarantees in Article 4, not on grading. Do not treat these as shared product constants. |
| **Whitelist / Protected path** | A path the tool will never touch. |
| **Blacklist / Target rule** | A user-added rule that marks additional paths as cleanable. |
| **Session** | One invocation of the tool from process start to exit. Has a UUID, logs, and a report. |
| **Profile** | A named, saved set of plugin selections + options (e.g. "developer-daily"). |

---

## Article 4 — The Safety Model (three guarantees, shared by all plugins)

Full model in spec 22. The safety model does **not** grade Items by risk. There is no
user-facing Safe/Medium/Dangerous grading, no colour coding, no pre-selection, and no
`--all`/`--include` opt-in tiers. Instead, safety rests on three guarantees that hold for
every Item, every plugin, and every edition. Every plugin references these.

### 4.1 Guarantee 1 — You choose

Nothing is deleted without an explicit, informed decision.

- The primary command scans, then asks: `Clean all X? [Y = all · s = select each · n = cancel]`.
  - `Y` / Enter cleans everything that was found.
  - `s` walks each source in turn with a `clean? [y/N]` prompt (default No).
  - `n` cancels; the filesystem is untouched.
- `--yes` cleans everything without prompting (for automation).
- `--dry-run` changes nothing and reports exactly what *would* happen.

No colour, no grade, and no default selection stands in for consent: the user (or a signed
automation policy) always decides.

### 4.2 Guarantee 2 — Everything is recoverable

Nothing is `unlink()`-ed outright when a recoverable path exists.

- The default disposition is *move-to-staging* under `~/.cleaner/staging/`, session-scoped.
- `cleaner undo` restores the last clean byte-for-byte (`cleaner undo --list` / `cleaner undo <id>`
  for older sessions).
- The macOS Trash is **staged too**, not purged in place — emptying the Trash through the tool
  is itself reversible until the staged copy is purged.
- Permanent deletion (Purge) is an explicit escalation, never a default.

Recoverability is still recorded per Finding as `instant` (staged, one-command rollback) ·
`manual` (re-downloadable/re-buildable by the user) · `hard` (external source needed, e.g.
re-clone) · `none` (irreversible). It is shown as rationale in the preview; it is *not* a risk
grade and does not gate selection.

### 4.3 Guarantee 3 — Protected paths can never be touched

A hard deny-list (Article 5) is enforced **in the engine**, independently of plugins, so no
plugin, rule, or option can reach a protected path. Browsers are treated as **cache-only**:
the tool may reclaim browser caches but never cookies, history, or passwords.

### 4.4 Hard invariants (enforced in the engine, not trusted to plugins)

- Never delete outside the union of plugin-declared roots and user target rules.
- Never delete a path on the protected-path list (Article 5).
- Never follow a symlink out of an allowed root to delete the target.
- Never delete a currently-open/locked file without explicit override.
- Never purge without staging first, unless `--no-stage` **and** confirmation.
- Refuse to operate on a path that is a mount root, a system volume, or `/`.
- Reclaim is measured as true on-disk allocated size, so dry-run figures equal real-run
  figures. Every action is written to an append-only audit log.

---

## Article 5 — Protected paths (deny-list, enforced in engine)

Hard-coded, non-overridable except by a signed policy file with an explicit ack:

```
/                         /System        /usr (except /usr/local)   /bin  /sbin
/Library (system parts)   /Applications (the .app bundles themselves, not their caches)
~/Documents  ~/Desktop  ~/Pictures  ~/Movies  ~/Music (user content roots)
~/.ssh  ~/.gnupg  Keychains  ~/.config credentials  *.key *.pem private material
Any path under a Time Machine local snapshot mount
The tool's own Staging, config, and logs
```

Plugins declare narrower roots *within* the allowed space; the engine intersects plugin
roots with the allow-space and subtracts the deny-list before any action.

---

## Article 6 — Naming & code conventions

- **Product / binary name:** `cleaner` (invoked), package/repo `cleaner-cli`.
- **Language:** Swift 6, strict concurrency. Min target macOS 13 (Ventura); native APIs that
  need 14+/15+ are feature-gated (spec 10, spec 16).
- **Module prefix:** none (Swift modules namespace). Public types are `PascalCase`, no `CL`
  prefix (that's Objective-C style). Protocols end in `-ing`/`-able` or are role nouns
  (`CleanerPlugin`, `Scanner`, `Disposer`).
- **Errors:** every error type conforms to `CleanerError` (spec 27) and carries an exit code.
- **Async:** `async`/`await` + `actor` for shared mutable state; `TaskGroup` for fan-out.
  No `DispatchQueue` in new code except where a C API mandates it.
- **No force-unwrap** in non-test code except documented invariants with `// SAFETY:` note.
- **Feature flags:** compile-time `#if` only for OS-version APIs; runtime capability probing
  otherwise.

---

## Article 7 — Shared exit codes (referenced everywhere)

| Code | Name | Meaning |
|---|---|---|
| 0 | `ok` | Success; work completed (or nothing to do). |
| 1 | `general` | Unclassified runtime error. |
| 2 | `usage` | Bad arguments/flags (Argument Parser). |
| 3 | `partial` | Completed with some items skipped/failed; report lists them. |
| 4 | `permission` | Needed access (Full Disk Access / admin) not granted. |
| 5 | `cancelled` | User cancelled (interactive `q`/Ctrl-C) or timeout. |
| 6 | `config` | Invalid configuration file. |
| 7 | `plugin` | A plugin failed to load or violated the contract. |
| 8 | `safety` | Aborted by a safety invariant (attempted protected-path action). |
| 10 | `precondition` | Environment unmet (unsupported OS, no TTY where required). |
| 11 | `entitlement` | A Pro-only command/feature invoked without a valid license (Pro edition). Distinct from 4 `permission`. |
| 130 | `sigint` | Reserved: process interrupted (POSIX convention). |

CI mode (`--ci`) maps `doctor` health to: 0 healthy, 3 warnings, 1 critical.

---

## Article 8 — Directory & file layout the tool owns

```
~/.cleaner/                         # tool home (XDG-overridable via CLEANER_HOME)
├── config.yml                      # user config (spec 24)
├── profiles/                       # saved profiles
├── staging/                        # quarantine (spec 21) — dated, session-scoped
│   └── <session-uuid>/
├── logs/                           # structured + audit logs (spec 28), rotated
│   ├── cleaner.log
│   └── audit/<date>.ndjson
├── cache/                          # tool's own scan cache for incremental scans (spec 17)
├── reports/                        # exported reports (spec, md, html)
└── policy/                         # signed automation policies (spec 23)
```

Repository layout, CI, and packaging live in specs 32–34.

---

## Article 9 — The SpecKit process for this project

We follow Specification-Driven Development in five gated stages:

1. **Constitution** (this doc) — invariants & conventions. *Gate: ratified before any spec.*
2. **Specify** — the *what* and *why*: vision, requirements, personas, domain, safety,
   detection, UX. (Specs 01–29.) *Gate: functional + safety + UX signed off.*
3. **Plan** — the *how*: architecture, module decomposition, engine designs, data model,
   tech ADRs, packaging, CI/CD, testing, security. (Specs 10–37.) *Gate: ADRs accepted.*
4. **Tasks** — decompose each planned module into implementable, testable tasks with
   acceptance criteria (produced per-phase in `specs/tasks/`, not in this suite's v1).
5. **Implement** — code against tasks; every task closes against an acceptance test.

**Traceability rule:** every Functional Requirement (FR-###) traces to ≥1 User Story,
≥1 Use Case, ≥1 test in the Testing Strategy, and ≥1 owning module. The traceability matrix
lives at the end of spec 06.

### Specification phases (delivery order)

- **Phase A — Foundations:** 00 Constitution, 01 Vision, 02 Problem, 03 Personas,
  04 User Stories, 05 Use Cases.
- **Phase B — Requirements & Interface:** 06 Functional Reqs, 07 Non-functional Reqs,
  08 Command Reference, 09 Information Architecture.
- **Phase C — Architecture & Tech:** 10 Tech Stack (+ADRs), 11 Architecture Overview,
  12 Module Decomposition, 13 Plugin Architecture.
- **Phase D — Core Engines:** 14 Domain Model, 15 Data Model, 16 Filesystem Strategy,
  17 Scan Engine, 18 Rule Engine, 19 Detection Algorithms, 20 Cleanup Engine,
  21 Rollback Design.
- **Phase E — Safety & Trust:** 22 Safety Model, 23 Permission Model, 35 Security Review,
  36 Threat Model, 39 Risk Register.
- **Phase F — Experience:** 24 Configuration System, 25 TUI Design System,
  26 CLI UX Guideline, 27 Error Handling, 28 Logging, 29 Telemetry.
- **Phase G — Quality & Delivery:** 30 Benchmark Plan, 31 Testing Strategy,
  32 Packaging, 33 Release, 34 CI/CD, 37 Performance Optimization.
- **Phase H — Direction:** 38 Future Roadmap, plus per-plugin specs in `specs/plugins/`.

---

## Article 10 — Cross-cutting decisions locked here (so specs don't re-argue them)

| # | Decision | Rationale (short) | Full ADR |
|---|---|---|---|
| CC-1 | Language = **Swift 6 / SPM** | Native macOS API access, performance, single static binary. | ADR-0001 |
| CC-2 | CLI parsing = **Swift Argument Parser** | First-party, declarative, testable, completions. | ADR-0002 |
| CC-3 | Concurrency = **Swift Concurrency (actors/TaskGroup)** | Structured cancellation, data-race safety. | ADR-0003 |
| CC-4 | TUI = **custom component layer over ANSI**, small deps for color/width | No mature Swift TUI covers our needs; control + no heavy deps. | ADR-0004 |
| CC-5 | Config = **YAML (Yams)** | Human-friendly, comments, matches consumer-cleaner-style expectations. | ADR-0005 |
| CC-6 | Logging = **swift-log** + custom audit sink | SSWG standard, pluggable backends. | ADR-0006 |
| CC-7 | Delete = **stage-then-purge**, macOS Trash optional | Reversibility principle. | ADR-0007 |
| CC-8 | Plugins = **in-process, statically linked, protocol-based** (v1) | Safety + performance; out-of-process/dylib deferred. | ADR-0008 |
| CC-9 | Testing = **Swift Testing** + XCTest bridge + package-benchmark | Modern, parameterized, first-party. | ADR-0009 |
| CC-10 | Reclaim measured via **`URLResourceValues` allocated size** | Truth-in-reporting with APFS clones/sparse. | ADR-0010 |
| CC-11 | Distribution = **notarized Homebrew tap + GitHub Releases** | Trust + reach on macOS. | ADR-0011 |
| CC-12 | Telemetry = **off by default, local-only unless opted in** | Privacy principle. | ADR-0012 |
| CC-13 | Business = **open-core**: free CLI (MIT, this repo) + paid Pro app; licensing = **offline entitlements** | Trust via open safety engine; monetize convenience/automation, not protection. | *(commercial repo)* |

Each `ADR-####` file lives in `specs/adr/` and states context, options, decision, consequences.

---

## Article 11 — Definition of Done (applies to every spec in this suite)

A specification document is "done" when it: states its purpose and scope; enumerates the
decisions with rationale and at least one rejected alternative each; defines all new terms
in Article 3 or locally; lists open questions explicitly (no silent gaps); cross-links the
specs it depends on and the ones that depend on it; and is implementable by a competent
engineer or agent **without further clarification**. Ambiguity is a defect.

---

## Article 12 — Amendment process

Any change to this Constitution requires: a written rationale, an assessment of every
downstream spec affected, and a version bump. Principle reordering (Article 1) is a breaking
change requiring re-review of the Safety Model and Threat Model.
