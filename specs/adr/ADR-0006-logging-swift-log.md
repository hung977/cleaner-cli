# ADR-0006: Logging = swift-log + Custom Audit Sink

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-6 · deep analysis in spec 10 §8
- **Constitution principles engaged:** 8 (observability), 10 (privacy — metrics off by default)

## Context

Constitution principle 8 requires every run be explainable after the fact: structured logs, a
**machine-readable audit trail of every filesystem mutation**, and a report. Article 8 fixes the
paths: `~/.cleaner/logs/cleaner.log` and append-only `~/.cleaner/logs/audit/<date>.ndjson`.
During development we also want Console.app / signpost visibility. Metrics (`swift-metrics`) must
exist but stay dark unless telemetry is opted in (principle 10, ADR-0012). The audit trail is a
**safety and trust artifact** — it must answer "why did you delete this?" from recorded evidence
(FR-061/FR-099), so it can't be best-effort `print` output.

## Decision Drivers

1. **Backend-agnostic façade** so we can route dev logs and the audit trail differently.
2. **A dedicated, append-only, structured audit backend** (NDJSON) for every mutation (FR-099).
3. **os.Logger / signpost** path for local dev without coupling the whole app to it.
4. **Metrics compiled in but no-op by default** (privacy, ADR-0012).
5. **SSWG-standard, low-risk dependency.**

## Options Considered

### swift-log (façade) + custom audit backend (+ swift-metrics, no-op default) — chosen
- **Pros:** `swift-log` is the SSWG standard backend-agnostic logging façade; we ship an
  `os.Logger` backend (Console.app, signposts) for dev and a **file/NDJSON audit backend** that
  records every filesystem mutation as an append-only event (path, size, disposition, session,
  evidence) — exactly principle 8 / FR-099. `swift-metrics` is compiled in but wired to a no-op
  backend unless telemetry is opted in (spec 29, ADR-0012). Pluggable, testable, standard.
- **Cons:** we own the audit backend implementation and its NDJSON schema (spec 28) — but that
  code is load-bearing for trust and would exist regardless of façade choice.

### os.Logger only — rejected
- **Pros:** zero dependency, native, great Console.app integration and signposts.
- **Cons / why rejected:** it's a logging *system*, not a routing façade — awkward to also emit a
  separate append-only NDJSON audit file and to swap backends in tests. The unified log is not the
  right home for a durable, user-inspectable, append-only audit artifact under `~/.cleaner`.

### `print` / hand-rolled — rejected
- **Cons / why rejected:** unstructured, no levels, no routing, pollutes the stdout/stderr
  contract (spec 08 §3), and cannot produce a reliable audit trail. Fails principle 8 outright.

### CocoaLumberjack — rejected
- **Cons / why rejected:** Objective-C, heavier, and adds a large dependency for capabilities
  swift-log already covers in a Swift-native, SSWG-blessed way. Against dependency-minimization.

## Decision

Adopt **swift-log** as the façade with two backends: an **os.Logger backend** (dev/Console) and a
custom **NDJSON audit backend** writing append-only events to `~/.cleaner/logs/audit/<date>.ndjson`
(rotated, spec 28). Every filesystem mutation emits an audit event (FR-099) carrying evidence
(FR-061). Compile in **swift-metrics** wired to a **no-op backend** unless telemetry is explicitly
opted in (ADR-0012 / spec 29). Diagnostics (`--verbose`/`--debug`) go to stderr, never polluting
`--json` stdout (spec 08 §3).

## Consequences

- The audit trail becomes a first-class, machine-readable safety artifact backing every "why did
  you delete this?" query (principle 8).
- Dev ergonomics via os.Logger without coupling the app to it.
- Metrics infrastructure exists but is dark by default (privacy, principle 10).
- We own the audit NDJSON schema (spec 28) and must snapshot/round-trip test it (spec 31).

## Links

- Constitution Article 10 (CC-6), Article 8 (log paths), principles 8 & 10.
- Spec 10 §8, spec 28 (logging/audit schema), spec 29 (telemetry/metrics), spec 08 §3 (stderr contract).
- Related: ADR-0012 (telemetry off by default), ADR-0007 (audit records every disposition).
