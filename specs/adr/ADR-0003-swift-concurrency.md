# ADR-0003: Concurrency = Swift Concurrency (actors, TaskGroup, AsyncSequence)

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-3 · deep analysis in spec 10 §5
- **Constitution principles engaged:** 5 (determinism), 9 (performance/cancellation)

## Context

The scan engine fans out across many roots and directories, must stay memory-bounded on millions
of files, must stream findings to a live UI, and must be **cancellable at directory boundaries**
(the `cancel` NFR) and **resumable from a checkpoint** (the `resume` NFR). Shared mutable state
(scan accumulators, the staging manager) is touched from many concurrent tasks. This is a data
race waiting to happen in a tool whose worst-case bug is deleting the wrong file — so compile-time
race safety is not a nicety, it's a safety control (principle 1 indirectly, principle 5 directly).

## Decision Drivers

1. **Compile-time data-race safety** for shared mutable state — Swift 6 strict concurrency.
2. **Structured, cooperative cancellation** to satisfy `cancel`/`resume` cleanly.
3. **Streaming** findings to the TUI/JSON without buffering the whole result set.
4. **Bounded fan-out** tuned to volume type (SSD vs HDD vs network, from DiskArbitration).
5. **No lock zoo** — serialize mutation without hand-rolled mutexes.

## Options Considered

### Swift Concurrency (actors + TaskGroup + AsyncSequence) — chosen
- **Pros:** `actor ScanAccumulator` / `actor StagingManager` serialize mutation without locks and
  are race-safe by construction; `TaskGroup` per root gives structured fan-out bounded by a
  concurrency limiter (spec 17); `Task.checkCancellation()` at directory boundaries gives clean
  cooperative cancellation; `AsyncStream<Finding>` streams results for live UI and JSON;
  `Sendable` checking catches races at compile time (native to the Swift 6 choice, ADR-0001).
- **Cons:** `Sendable`/isolation discipline has a learning curve; some Foundation APIs need
  careful bridging into async contexts.

### Dispatch / OperationQueue (GCD) — rejected
- **Pros:** battle-tested, fine-grained control, familiar.
- **Cons / why rejected:** cancellation is manual and error-prone (checking flags, cancelling
  operations); shared state needs hand-written locking, which is exactly the class of bug we most
  want to avoid in a deletion tool; no compile-time race safety. Retained only where a C API
  mandates a queue (Article 6 permits this narrow exception).

### Combine — rejected
- **Pros:** declarative streaming, back-pressure operators.
- **Cons / why rejected:** on a deprecating trajectory relative to async/await; heavier; worse
  cancellation ergonomics for our tree-walk model; couples us to a framework Apple is steering away
  from. `AsyncSequence` covers our streaming needs natively.

## Decision

Use **Swift Concurrency throughout**: `TaskGroup` for scan fan-out under a volume-tuned limiter;
`actor`s for all shared mutable state; `AsyncStream`/`AsyncSequence` for streaming findings;
cooperative `Task.checkCancellation()` at directory boundaries plus a checkpoint file for resume.
No `DispatchQueue` in new code except where a C API requires it (Article 6).

## Consequences

- Cancellation and resume fall out of the model rather than being bolted on (principle 9).
- Data races on scan/staging state become compile errors, not production incidents.
- The team owns the `Sendable`/isolation learning curve (also noted in ADR-0001 consequences).
- The concurrency limiter must be tuned per volume type (spec 17) — a deliberate design task.

## Links

- Constitution Article 10 (CC-3), Article 6 (async conventions), principles 5 & 9.
- Spec 10 §5, spec 17 (scan engine + limiter + checkpoint), spec 21 (staging actor), spec 25 (live TUI).
- Related: ADR-0001 (Swift 6 enables strict concurrency).
