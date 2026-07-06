# ADR-0001: Language = Swift 6, Build = Swift Package Manager

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-1 · deep analysis in spec 10 §3
- **Constitution principles engaged:** 4 (native first), 9 (performance is a feature)

## Context

cleaner-cli must reach deep into macOS: `URLResourceValues` for allocated size, `getattrlistbulk`
for bulk metadata, DiskArbitration for volume type, Spotlight (`MDQuery`) for last-used/where-from,
Launch Services for app registration, `xattr`/`clonefile` for APFS truth, and Authorization
Services for the rare elevation. It must stream over millions of files on a 4 TB SSD with bounded
memory, cancel cleanly, and ship as one fast binary maintainable for years. It is **macOS-only** —
cross-platform reach has no value here. The brief explicitly rejects "a bash script."

## Decision Drivers

1. **Native API access without FFI friction** (principle 4) — the single most weighted driver.
   Every framework above must be callable directly and completely.
2. **Performance & bounded memory** on huge trees (principle 9).
3. **Single self-contained binary**, easy to notarize and distribute (ADR-0011).
4. **Compile-time safety** for a tool that deletes files — data-race and memory safety matter.
5. **Long-term maintainability** on Apple platforms.

## Options Considered

### Swift 6 + SPM — chosen
- **Pros:** first-class, zero-FFI access to *every* macOS framework we need; value types + ARC
  give predictable, bounded memory; Swift 6 strict concurrency catches data races at compile time
  (principle 5, ADR-0003); async/await gives structured cancellation for the `cancel`/`resume`
  NFRs; SPM builds a static universal binary and is the notarization-friendly toolchain.
- **Cons:** thin TUI ecosystem (addressed by ADR-0004 — we own the layer); longer compile times
  (mitigated by module splitting, spec 12, + CI caching); smaller cross-platform story (irrelevant).

### Rust — rejected
- **Pros:** excellent performance and memory safety; superb CLI/TUI crates (clap, ratatui, indicatif).
- **Cons / why rejected:** macOS framework access goes through `objc2`/`core-foundation` FFI
  bindings that are **incomplete** for Spotlight, DiskArbitration, Authorization Services, and
  Launch Services. We would spend our budget maintaining bindings instead of shipping cleaning
  logic — a direct violation of the native-first driver. Great language, wrong platform coupling.

### Go — rejected
- **Pros:** fast builds, single binary, mature CLI ecosystem (cobra, bubbletea).
- **Cons / why rejected:** cgo bridging to the required frameworks is painful, slow, and brittle;
  the binding gap is the same dealbreaker as Rust but worse for Apple-specific APIs. GC pauses are
  tolerable, but the FFI cost is not.

### Bash / Python — rejected
- **Cons / why rejected:** explicitly excluded by the brief; cannot meet the performance,
  memory-bounding, or compile-time-safety drivers; shelling out to system tools for everything
  contradicts native-first (principle 4) and multiplies the threat surface (spec 36).

## Decision

**Swift 6 with strict concurrency, built by SPM.** Minimum deployment target **macOS 13
(Ventura)**; APIs newer than 13 are runtime-probed and feature-gated (spec 16). Ship a **universal
binary** (arm64 + x86_64) for v1 (revisit the x86_64 slice at v2, OQ-10.3).

## Consequences

- **We own the TUI layer** (ADR-0004) — the one place Swift's ecosystem is thin becomes owned code
  we must test (spec 31 snapshot tests).
- Build times require discipline: module boundaries (spec 12) and CI build caching (spec 34).
- The team must be fluent in Swift concurrency's `Sendable`/isolation rules (ADR-0003).
- We inherit Apple's toolchain for signing/notarization cleanly (ADR-0011).
- Shell-outs remain a justified, adapter-isolated fallback (spec 13), never the default path.

## Links

- Constitution Article 10 (CC-1), Article 6 (conventions), principles 4 & 9.
- Spec 10 §3 (full trade-off), spec 12 (modules), spec 16 (filesystem/feature-gating).
- Related: ADR-0003 (concurrency), ADR-0004 (TUI consequence), ADR-0011 (distribution).
