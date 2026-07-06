# ADR-0012: Telemetry = Off by Default, Local-Only Unless Opted In

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-12 · analysis in spec 10 §8, spec 29
- **Constitution principles engaged:** 10 (privacy by default — the direct driver)

## Context

Principle 10 is explicit: "No network calls in the core cleaning path. Telemetry is opt-in and off
by default. Reports stay on the user's machine unless they export them." This is a tool that walks
a user's entire disk and knows the paths of their most sensitive files — the privacy stakes are
maximal. At the same time, product needs *some* ability to understand performance and usage *if
the user chooses to help*. The design must make the safe default (silence) effortless and any data
sharing a deliberate, informed, revocable act. This ADR also sets the **precedent** for the v2
AI-assist and v3 dashboard features (spec 38), which reuse the same opt-in-only, metadata-only rule.

## Decision Drivers

1. **Privacy by default (principle 10)** — zero network, zero telemetry unless explicitly enabled.
2. **No core-path network I/O ever** — even opted-in, telemetry never touches the cleaning path.
3. **Informed, revocable consent** — opt-in is explicit, explained, and reversible.
4. **Local-first value** — reports and metrics are useful on-device without ever leaving it.
5. **Infrastructure present but dark** — no code churn to enable later, but no data flows by default.

## Options Considered

### Off by default, local-only unless opted in — chosen
- **Pros:** honors principle 10 literally; `swift-metrics` is compiled in but wired to a **no-op
  backend** unless telemetry is opted in (spec 10 §8, spec 29), so there is *no* data collection or
  network I/O in the default configuration; reports live under `~/.cleaner/reports` and never leave
  unless the user exports them; opt-in is explicit and revocable; sets a clean precedent for v2
  AI-assist / v3 dashboards (metadata-only, opt-in, spec 38). Trust-preserving for a whole-disk tool.
- **Cons:** we get little/no field data by default — product/performance insight relies on
  benchmarks (spec 30), bug reports, and the minority who opt in. Accepted: trust > analytics.

### On by default (opt-out) — rejected
- **Pros:** rich usage/performance data; industry-common.
- **Cons / why rejected:** a **direct violation of principle 10**. For a tool that can enumerate
  every private file path a user owns, silent-by-default collection is a betrayal of the exact trust
  the product is built on; opt-out normalizes surveillance we've promised not to do. Non-starter.

### No telemetry capability at all — rejected
- **Pros:** simplest possible privacy story; nothing to misuse.
- **Cons / why rejected:** forecloses ever letting *willing* users help improve performance/UX and
  blocks the opt-in AI-assist/dashboard roadmap (spec 38) without a later re-architecture. Better to
  build the infrastructure now, keep it **dark by default**, and let consent flip it — which is
  strictly safer than bolting collection on later under pressure.

## Decision

Telemetry is **off by default and local-only.** `swift-metrics` is compiled in but bound to a
**no-op backend** unless the user **explicitly opts in** (spec 29); even when opted in, telemetry
**never** runs in the core analysis/clean/audit path (principle 10 / FR-100) — only out-of-band,
and only metadata (never file contents or user-content paths). Reports stay under `~/.cleaner`
unless the user exports them. Opt-in is explicit, explained, and revocable. This opt-in-only,
metadata-only rule is the **binding precedent** for v2 AI-assist and v3 dashboards (spec 38).

## Consequences

- The default install collects nothing and makes no network call — the strongest privacy posture
  (principle 10) and the trust foundation for a whole-disk tool.
- Product insight comes primarily from CI benchmarks (spec 30) and voluntary reports; we accept
  thin default field data as the price of trust.
- Metrics infrastructure exists but is dark — no future re-architecture needed to support
  opted-in AI-assist/dashboards, and no risk of accidental data flow (the backend is no-op).
- Any future feature that sends data inherits this ADR's constraints: opt-in, revocable,
  metadata-only, never in the cleaning path.

## Links

- Constitution Article 10 (CC-12), principle 10, FR-100 (no network in core path).
- Spec 10 §8 (metrics wiring), spec 29 (telemetry design), spec 38 §6.1 (v2 AI-assist opt-in
  precedent) / §7 (v3 dashboards).
- Related: ADR-0006 (metrics compiled-in-but-no-op), ADR-0011 (no install-time telemetry).
