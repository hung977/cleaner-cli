# ADR-0008: Plugins = In-Process, Statically Linked, Protocol-Based (v1)

- **Status:** Accepted (v1) — *to be superseded for dynamic plugins in v2.2 by a future ADR (see
  spec 38 §6.4)*
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-8 · analysis in spec 10, spec 13
- **Constitution principles engaged:** 1 (safety), 7 (extensibility without core edits), 9 (performance)

## Context

Every cleaning capability is a plugin (principle 7), and adding one must not require editing the
engine, CLI, or another plugin. The question is the **plugin boundary mechanism** for v1: how
plugins are packaged, loaded, and isolated. This trades off safety (a plugin can request file
deletions), performance (plugins run in the hot scan loop over millions of files), and simplicity
against the future goal of a third-party plugin ecosystem (v2.2/v3 marketplace, spec 38). Article 2
explicitly defers third-party/dynamic plugins out of v1.

## Decision Drivers

1. **Safety** — the engine, not the plugin, enforces the hard invariants (Article 4.4/FR-110); a
   simpler boundary means a smaller attack surface for v1's known, first-party plugins.
2. **Performance** — plugins participate in the tight scan/enumerate loop; a call boundary in that
   loop must be near-free (principle 9).
3. **Simplicity for v1** — all v1 plugins are first-party and shipped in the same binary.
4. **Extensibility without core edits** (principle 7) — new plugin ⇒ new type, no engine change.
5. **Forward path** to dynamic/third-party plugins without repainting the protocol.

## Options Considered

### In-process, statically linked, protocol-based — chosen (v1)
- **Pros:** zero IPC/serialization overhead in the hot loop (principle 9); a plugin is just a type
  conforming to `CleanerPlugin` (spec 13), registered at build time — new capability with no core
  edit (principle 7); the engine enforces all invariants centrally and never trusts plugin
  self-reports (FR-110); no dynamic-loading threat surface (no untrusted code, no dylib injection,
  no XPC attack surface) — the right posture for safety-first v1; simplest to build, test (fixture
  trees, spec 31), and notarize (one signed binary, ADR-0011).
- **Cons:** all plugins ship in one binary (no third-party plugins in v1 — but that's out of scope
  per Article 2); a badly-behaved plugin shares the process (mitigated: plugins are first-party and
  the engine, not the plugin, performs all filesystem mutations; failures are isolated per FR-113).

### Dynamically loaded dylibs — rejected for v1
- **Pros:** third-party plugins without recompiling the host; the eventual ecosystem model.
- **Cons / why rejected (v1):** loading external code is a serious threat surface (code injection,
  unsigned/malicious dylibs) that contradicts the safety-first posture; requires signing/sandbox
  machinery we haven't built; unnecessary when all v1 plugins are first-party. Deferred to v2.2 as
  a candidate mechanism (spec 38 §6.4), gated behind sandboxing + signature verification.

### XPC / out-of-process services — rejected for v1
- **Pros:** strong isolation (crash/security containment) — attractive for *untrusted* plugins.
- **Cons / why rejected (v1):** per-item IPC + serialization overhead is unacceptable in a loop
  over millions of files (principle 9); heavy plumbing for zero v1 benefit since plugins are
  trusted and first-party. It is, however, the **leading candidate** for v2.2 third-party plugins
  precisely for its isolation (spec 38 §6.4) — the safety win that's wasted on trusted v1 code.

### Subprocess per plugin — rejected
- **Cons / why rejected:** the worst of both — process-spawn and pipe-serialization overhead in the
  hot path, plus argument/threat-surface concerns, with weaker structured typing than XPC. No niche
  where it wins for us.

## Decision

For **v1**, plugins are **in-process, statically linked, and protocol-based** (`CleanerPlugin`,
spec 13), registered at build time. The engine centrally enforces all Article 4.4 invariants and
performs all filesystem mutations — plugins *propose*, the engine *disposes* — so a plugin can
never escape its declared roots (FR-110) and one plugin's failure is isolated (FR-113). Dynamic
and third-party plugins (dylib **or** XPC, decided by a fresh ADR) are **explicitly deferred to
v2.2** with the SDK (spec 38 §6.4).

## Consequences

- Maximum performance and minimum threat surface for v1 — aligned with safety-first (principle 1).
- The `CleanerPlugin` protocol (spec 13) must be designed to survive the eventual move
  out-of-process (stable, serialization-friendly types) so v2.2 doesn't force a rewrite.
- No third-party plugins in v1 — accepted, and consistent with Article 2 scope.
- This ADR will be **superseded** (not deleted) when v2.2 chooses the dynamic mechanism; the
  supersession must justify the added isolation vs. performance trade-off then.

## Links

- Constitution Article 10 (CC-8), Article 2 (defers third-party plugins), principles 1, 7, 9.
- Spec 13 (plugin architecture / `CleanerPlugin` contract), spec 38 §6.4 (v2.2 dynamic plugins +
  SDK), spec 36 (threat model), FR-041/042/110/113.
- Related: ADR-0001 (single static binary), ADR-0011 (notarization of the one binary).
