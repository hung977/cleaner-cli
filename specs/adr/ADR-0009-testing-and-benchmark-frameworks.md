# ADR-0009: Testing = Swift Testing + XCTest Bridge; Benchmarks = package-benchmark

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-9 · deep analysis in spec 10 §9
- **Constitution principles engaged:** 3 (truth in reporting), 5 (determinism), 9 (performance is a feature)

## Context

This is a data-deleting tool where correctness *is* safety: the traceability rule (Article 9)
requires every FR to trace to ≥1 test, the safety invariants must be red-team tested (FR-110),
measurement honesty must be proven (principle 3, ADR-0010), and performance is a graded feature
with CI-enforced thresholds (principle 9, spec 30). We also need a **virtual filesystem fixture
layer** so scan/detection/cleanup can be tested against synthesized trees without touching the
real disk (spec 31). Tests span heavily parameterized cases (per-plugin risk mappings, size/age
thresholds, clone/hardlink/sparse permutations).

## Decision Drivers

1. **First-party, modern, maintained** test framework aligned with the Swift 6 choice (ADR-0001).
2. **Strong parameterization** — the safety/detection matrices are inherently table-driven.
3. **CI-enforced statistical benchmarks** with thresholds (spec 30), not ad-hoc timing.
4. **Bridge for legacy/edge cases** where XCTest is still required.
5. **Minimal extra dependencies** (spec 10 §11).

## Options Considered

### Swift Testing + XCTest bridge (tests) & package-benchmark (benchmarks) — chosen
- **Pros:** Swift Testing (`@Test`, `#expect`, parameterized traits) is the modern first-party
  framework — its parameterization fits our risk/threshold/clone matrices directly; XCTest is kept
  only where a bridge is needed (async edge cases, tooling that expects it). `package-benchmark`
  (ordo-one) gives **statistical** benchmarks with thresholds enforceable in CI (spec 30), so
  performance regressions fail the build (principle 9). Together with the virtual-FS fixture layer
  (spec 31), scan/detect/clean are tested deterministically off-disk (principle 5).
- **Cons:** two test frameworks coexist during the XCTest→Swift Testing transition; package-benchmark
  is a test-only dependency to vendor-audit (acceptable, it never ships in the binary).

### XCTest only — rejected
- **Pros:** zero new dependency, universally supported.
- **Cons / why rejected:** weaker parameterization (the matrices become boilerplate or clumsy
  `for`-loops with poor failure attribution); older ergonomics; misses the first-party direction
  Apple is investing in. We keep it as a *bridge*, not the primary framework.

### Quick / Nimble — rejected
- **Pros:** expressive matcher DSL, familiar to some.
- **Cons / why rejected:** extra dependencies, matcher-heavy style, no first-party guarantee, and
  no advantage over Swift Testing's native expectations. Against dependency-minimization (spec 10 §11).

### XCTest `measure` / hand-rolled timing (benchmarks) — rejected
- **Cons / why rejected:** `measure` gives coarse, non-statistical numbers unsuitable for CI
  gating; hand-rolled timing is noisy and non-comparable across runners. `package-benchmark`
  provides the statistical rigor and thresholds spec 30 needs.

## Decision

Use **Swift Testing** as the primary framework (`@Test`/`#expect`/parameterized traits), retaining
**XCTest** only as a bridge where required. Use **package-benchmark** (ordo-one, test-only) for
statistical benchmarks with **CI-enforced thresholds** (spec 30). Build a **virtual filesystem
fixture layer** (spec 31) so scan/detection/cleanup run against synthesized trees; safety
invariants (FR-110) and measurement honesty (ADR-0010) get dedicated red-team/round-trip suites.

## Consequences

- Parameterized tables express the safety/threshold matrices cleanly and attribute failures
  precisely — improving confidence in the deletion logic (principle 1).
- Performance regressions fail CI, keeping performance a real feature (principle 9, spec 30).
- Two frameworks coexist temporarily; the transition is bounded and intentional.
- The fixture layer lets the whole engine be tested without risking a real disk (principle 5) —
  itself a safety property for the test suite.

## Links

- Constitution Article 10 (CC-9), Article 9 (traceability → every FR has a test), principles 3, 5, 9.
- Spec 10 §9, spec 30 (benchmark plan + thresholds), spec 31 (testing strategy + virtual FS
  fixtures), FR-110 (invariant tests), ADR-0010 (measurement round-trip tests).
- Related: ADR-0001 (Swift 6), ADR-0007 (staging round-trip proof).
