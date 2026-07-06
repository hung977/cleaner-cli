# cleaner-cli Constitution

> Spec Kit memory copy. The full, authoritative Constitution lives at
> [`specs/00-constitution.md`](../../specs/00-constitution.md); this file distills it for the
> Spec Kit workflow (`/speckit-*`). On conflict, the full Constitution wins.

## Core Principles

### I. Safety over savings (NON-NEGOTIABLE)
The tool reclaims space but never at the cost of deleting something the user needs. Every
destructive action is **preview → confirm → execute**. No code path deletes user data without
an explicit, informed decision (interactive confirm, `--yes`, or a signed automation policy).
🔴 Dangerous items are never auto-selected and never auto-cleaned under `--yes`.

### II. Reversibility by default (NON-NEGOTIABLE)
Nothing is permanently deleted when recovery is possible. Default disposition is **move-to-staging**
(a tool-managed quarantine with one-command rollback), not `unlink()`. Permanent purge is an
explicit escalation, never a default. Losing a Pro license never endangers data.

### III. Native-first & truthful reporting
Prefer documented macOS/Foundation APIs over shelling out; every shell fallback is an isolated,
justified adapter. Reclaim is measured as **actual on-disk allocated size** (APFS clone/sparse
aware) so dry-run and real numbers use identical code. Never overstate savings or hide actions.

### IV. Extensibility without core edits
Every cleaning capability is an independent **plugin**. Plugins **propose** directives; the engine
**disposes**. Adding a plugin must not require modifying the engine, the CLI, or another plugin.
Safety invariants (protected paths, staging) are enforced in the engine, not trusted to plugins.

### V. Least privilege, privacy, observability
Run as the invoking user; request Full Disk Access / admin elevation lazily, scoped, explained.
No network in the core cleaning path (narrow exception: explicit license/update, opt-in telemetry —
off by default). Every run is explainable: structured logs + append-only audit of every file touched.

### VI. Safety is never behind a paywall
Open-core: the CLI (this repo) is free/MIT; the Pro app is paid. Safety features are identical for
free and paid users and may never be gated, degraded, or time-limited. Monetization gates only
convenience, automation, visualization, and scale — never protection or the ability to clean.

## Additional Constraints (Technology & Platform)

- **Language/build:** Swift 6 (strict concurrency) + Swift Package Manager. macOS 13+ baseline;
  universal binary (arm64 + x86_64).
- **Fixed stack:** swift-argument-parser (CLI), Swift Concurrency (actors/TaskGroup/AsyncStream),
  custom TUI over ANSI, Yams (config), swift-log + audit sink, CryptoKit (dedup), Swift Testing +
  package-benchmark. Rationale in `specs/10-tech-stack.md` and ADRs.
- **Determinism & idempotence:** a scan over an unchanged FS yields the same result; running
  `clean` twice is safe (second run finds nothing new).
- **Shared constants:** risk levels 🟢/🟡/🔴, exit codes (0 ok, 2 usage, 3 partial, 4 permission,
  5 cancelled, 6 config, 7 plugin, 8 safety, 10 precondition, 11 entitlement), and the `~/.cleaner/`
  layout are defined in the full Constitution — never invent new ones ad hoc.

## Development Workflow (Spec Kit + Quality Gates)

- Follow Spec Kit: `/speckit-constitution` → `/speckit-specify` → (`/speckit-clarify`) →
  `/speckit-plan` → `/speckit-tasks` → (`/speckit-analyze`) → `/speckit-implement`.
- **Safety test suite is a 100% gate** — every protected-path × disposition combination must be
  proven un-deletable before merge (see `specs/31-testing-strategy.md`).
- Traceability: requirements carry stable IDs (`FR-###`, `NFR-###`, `SR-###`); every FR traces to
  a user story, a use case, a test, and an owning module.
- No product code lands without a passing test; deletion-path code additionally needs a safety test.

## Governance

This Constitution supersedes all other practices. Amendments require a written rationale, an
assessment of every affected spec, and a version bump; reordering the principles triggers re-review
of the Safety Model and Threat Model. All plans and reviews must verify compliance; unjustified
complexity is rejected. Runtime agent guidance lives in `CLAUDE.md` (local) and the `specs/` suite.

**Version**: 1.1.0 | **Ratified**: 2026-07-06 | **Last Amended**: 2026-07-06
