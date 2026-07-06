# Architecture Decision Records (ADRs)

> **Owner:** Architecture · **Anchors to:** [00-constitution.md](../00-constitution.md)
> Article 10 (cross-cutting decisions CC-1..CC-12) and [10-tech-stack.md](../10-tech-stack.md)
> (the deeper trade-off analysis).

This directory holds the **Architecture Decision Records** for cleaner-cli. An ADR captures a
single significant decision, the forces that shaped it, the options weighed, the choice made,
and the consequences we accept. ADRs are **immutable once accepted** — we don't rewrite history;
we *supersede* a record with a new one and update the old one's Status and links.

## Why ADRs exist here

Constitution Article 10 locks the cross-cutting decisions (CC-1..CC-13) so that the 40+
specs don't re-litigate them. (CC-13's ADRs live in the private commercial repository — see
the note under the index below.) Each CC-# carries a one-line rationale and points to an
`ADR-####` file. **This directory is where those one-liners are justified in full.** Constitution
Article 11 (Definition of Done) requires every decision to state at least one rejected
alternative with reasons — ADRs are where that trade-off analysis lives in depth.

Relationship between the three layers:

- **Constitution Article 10** — the *decision*, one line, non-negotiable without an amendment.
- **Spec 10 (Tech Stack)** — the *pinned set* and a paragraph of justification per choice.
- **ADR-#### (here)** — the *full record*: context, drivers, options, decision, consequences.

They must stay consistent. If an ADR's decision ever diverges from its CC-# one-liner, the
Constitution wins and the ADR is a defect until reconciled (Article 12 amendment process).

## ADR format (every file follows this)

Each ADR uses these sections, in order:

1. **Title & metadata** — `ADR-####: <short decision>`, plus **Status**, **Date**, **Deciders**,
   and the **Constitution link** (which CC-# it realizes).
2. **Status** — one of: `Proposed` · `Accepted` · `Superseded by ADR-####` · `Deprecated`.
   All v1 ADRs here are **Accepted**.
3. **Context** — the problem, the forces, the constraints (which Constitution principles and
   NFRs apply). Enough that a reader needn't have the whole spec suite in their head.
4. **Decision Drivers** — the criteria we optimized for, ranked where it matters. These are the
   yardsticks the options are scored against.
5. **Options Considered** — the chosen option and **at least two rejected alternatives**, each
   with concrete pros/cons measured against the drivers (Article 11).
6. **Decision** — the choice, stated crisply, with any scoping/version gates.
7. **Consequences** — what we now accept: the good, the bad, the follow-on work, and what this
   forecloses. Includes revisit triggers where relevant.
8. **Links** — related ADRs, the specs that consume this decision, the Constitution article.

Keep each ADR to ~1–2 pages. An ADR is a decision record, not a design doc — the design lives
in the referenced specs.

## Index

| ADR | Decision | CC-# | Status | Alternatives rejected |
|---|---|---|---|---|
| [ADR-0001](./ADR-0001-language-and-build.md) | Language = Swift 6, build = SPM | CC-1 | Accepted | Rust, Go, Bash/Python |
| [ADR-0002](./ADR-0002-cli-argument-parser.md) | CLI parsing = swift-argument-parser | CC-2 | Accepted | Hand-rolled, third-party parsers |
| [ADR-0003](./ADR-0003-swift-concurrency.md) | Concurrency = Swift Concurrency (actors/TaskGroup) | CC-3 | Accepted | Dispatch/OperationQueue, Combine |
| [ADR-0004](./ADR-0004-custom-tui-layer.md) | TUI = custom component layer over ANSI | CC-4 | Accepted | SwiftTUI, Noora, ncurses |
| [ADR-0005](./ADR-0005-yaml-config-yams.md) | Config = YAML via Yams | CC-5 | Accepted | TOML, JSON-only |
| [ADR-0006](./ADR-0006-logging-swift-log.md) | Logging = swift-log + audit sink | CC-6 | Accepted | os.Logger-only, print, CocoaLumberjack |
| [ADR-0007](./ADR-0007-stage-then-purge-deletion.md) | Deletion = stage-then-purge | CC-7 | Accepted | Direct `rm`, macOS Trash-only |
| [ADR-0008](./ADR-0008-in-process-static-plugins.md) | Plugins = in-process, static, protocol-based (v1) | CC-8 | Accepted | dylib, XPC, subprocess |
| [ADR-0009](./ADR-0009-testing-and-benchmark-frameworks.md) | Testing = Swift Testing + package-benchmark | CC-9 | Accepted | XCTest-only, Quick/Nimble |
| [ADR-0010](./ADR-0010-reclaim-measured-by-allocated-size.md) | Reclaim = allocated on-disk size | CC-10 | Accepted | Logical size, `du`-style |
| [ADR-0011](./ADR-0011-distribution-homebrew-notarized.md) | Distribution = notarized Homebrew tap | CC-11 | Accepted | Mac App Store, curl\|bash, raw binary |
| [ADR-0012](./ADR-0012-telemetry-off-by-default.md) | Telemetry = off by default, local-only | CC-12 | Accepted | On-by-default, none at all |

> **CC-13 (open-core business model & licensing)** is realized by ADR-0013 (open-core +
> subscription licensing) and ADR-0014 (repository strategy). Those records concern the paid Pro
> product and are maintained in the **private commercial repository**, not here. This repo is the
> free, open-source CLI.

## Numbering & lifecycle

- Numbers are permanent and monotonic. A superseded ADR keeps its number; the replacement gets
  the next free number and links back.
- New cross-cutting decisions (e.g. the v2 dynamic-plugin mechanism that will supersede
  ADR-0008) get new ADR numbers and, if they change a CC-#, a Constitution amendment (Article 12).
- Per-plugin technical decisions (e.g. duplicate-hashing choice) may live as scoped ADRs
  referenced from their plugin spec rather than as top-level CC-# records.
