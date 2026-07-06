# ADR-0005: Configuration = YAML via Yams

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-5 · deep analysis in spec 10 §7
- **Constitution articles engaged:** 8 (owned layout: `~/.cleaner/config.yml`)

## Context

`~/.cleaner/config.yml` (Article 8) is hand-edited by power users and holds nested structures:
whitelist/protected-path additions, target rules, per-plugin options, thresholds, staging
retention, and profile definitions. The target audience (developers, CleanMyMac refugees) expects
a friendly, commentable config. The format must integrate with Swift `Codable` (spec 24 defines
the schema + validation) and support `config get/set/edit/validate` (spec 08 §6).

## Decision Drivers

1. **Human-friendliness with inline comments** — users annotate whitelist/rule entries.
2. **Comfortable nesting** for rules/whitelists/profiles.
3. **`Codable` integration** so config maps to typed Swift structs (spec 24).
4. **Familiarity** for the audience (YAML is the lingua franca of dev tooling config).
5. **Widely-used, maintained, dependency-auditable** library (spec 10 §11).

## Options Considered

### YAML via Yams — chosen
- **Pros:** supports **comments** (JSON's fatal gap for a hand-edited file); readable nesting;
  Yams is the SSWG-adjacent, widely-used, `Codable`-integrated YAML library; matches the
  ecosystem's expectations (CI configs, dev tools). Validates cleanly against a schema (spec 24),
  mapping errors to exit `6`.
- **Cons:** YAML has sharp edges (significant whitespace, the "Norway problem" where `no`→false,
  type coercion surprises). Mitigated by strict schema validation (spec 24) and a `config validate`
  command that rejects ambiguous input.

### TOML (TOMLKit) — rejected
- **Pros:** comments; unambiguous scalars; great for flat config.
- **Cons / why rejected:** **nested collections** (our deeply-nested whitelist/target-rule/profile
  structures) are clumsier and less readable in TOML's table-array syntax; less familiar to this
  audience for hierarchical config; adds a less-common dependency than Yams for no net gain on our
  shape of data.

### JSON-only — rejected
- **Pros:** zero extra dependency (Foundation `Codable`), unambiguous.
- **Cons / why rejected:** **no comments** — disqualifying for a file users annotate by hand;
  trailing-comma-hostile and noisy to edit. We still use JSON for machine *output* (`--json`,
  Foundation `Codable`, spec 08 §9) — the right tool for machines, the wrong tool for a
  human-edited config.

## Decision

Use **YAML via Yams** for `~/.cleaner/config.yml` and profile files (`~/.cleaner/profiles/*.yml`).
Enforce a strict schema with validation (spec 24); `config validate` rejects malformed/ambiguous
config with exit `6`; `config set` re-validates before persisting and refuses safety-weakening
writes without `--force-unsafe` + ack (spec 08 §6). Keep JSON strictly for machine output.

## Consequences

- Users get a friendly, commentable config; we accept YAML's parsing sharp edges and neutralize
  them with strict schema validation and a validate command.
- One dependency (Yams) in the allowed set (spec 10 §11) — pinned, vendor-audited before bumps.
- A clean split emerges: **YAML in** (human), **JSON out** (machine) — each format used where it's
  strongest.

## Links

- Constitution Article 10 (CC-5), Article 8 (config path).
- Spec 10 §7, spec 24 (config schema + validation), spec 08 §6 (`config` commands), spec 08 §9
  (JSON output — the machine-side counterpart).
- Related: ADR-0006 (structured logging is likewise machine-facing).
