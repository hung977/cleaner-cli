# 11 — Architecture Overview

> **Phase C · Depends on:** 00-constitution, 07-nonfunctional-requirements, 10-tech-stack ·
> **Depended on by:** 12 (module decomposition), 13 (plugins), 14–21 (engines), 24–28.

## 1. Purpose

Fix the macro-shape of `cleaner`: the layers, the components inside them, the direction
dependencies may point, how a full `clean` run flows through the system, how Swift
Concurrency primitives map onto the layers, how errors propagate to exit codes, and how the
composition root wires everything at startup. This is the load-bearing "how" that specs 12
and 13 refine and that every engine spec (14–21) plugs into.

The three non-negotiable shapes it encodes, straight from the Constitution:

- **Safety is enforced by the engine, not the plugins** (Article 4.4). Plugins *propose*
  Findings; the engine *disposes*. The dependency rule and the sequence flow both exist to
  make it impossible for a plugin to reach the filesystem without passing engine gates.
- **One core, many front-ends.** `--dry-run`, `--yes`, `--json`, interactive TUI, and CI mode
  are presentation/policy variations over a *single* orchestration pipeline (principle 3,
  "truth in reporting" — dry-run and real-run share measurement code).
- **Streaming, cancellable, bounded memory** (principle 9). Findings flow as an
  `AsyncStream`; nothing accumulates the whole filesystem in RAM.

## 2. Layered architecture

Five layers. Dependencies point **inward and downward only** (§4). Native macOS APIs sit
outside the domain and are reached exclusively through the Platform layer's adapters
(principle 4, "native first"; and testability — the domain never imports `DiskArbitration`).

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ L1  PRESENTATION                                                               │
│     cleaner (executable) · CleanerTUI · CLI arg parsing · JSON/NDJSON emitter  │
│     Renders Findings, drives confirmation, maps errors → exit codes.           │
├──────────────────────────────────────────────────────────────────────────────┤
│ L2  APPLICATION / ORCHESTRATION                                                │
│     RunCoordinator · SessionController · PluginResolver · policy for           │
│     dry-run/--yes/--json · progress + cancellation wiring · report assembly    │
├──────────────────────────────────────────────────────────────────────────────┤
│ L3  DOMAIN + ENGINES                                                           │
│     CleanerCore: Finding, Item, Disposition, RiskLevel, SafetyScore, Evidence  │
│     CleanerEngine: ScanEngine · RuleEngine · SafetyScorer · CleanupEngine ·    │
│                    StagingManager · RollbackEngine · ProtectedPathGuard        │
├──────────────────────────────────────────────────────────────────────────────┤
│ L4  PLUGINS  (link only against L3-via-SDK, never engine internals)            │
│     CleanerPluginAPI (stable SDK) ◀── TrashPlugin, XcodePlugin, BrowserPlugin, │
│                                        DockerPlugin, DuplicatePlugin, …        │
├──────────────────────────────────────────────────────────────────────────────┤
│ L5  PLATFORM ADAPTERS                                                          │
│     FileSystemProvider · VolumeProvider(DiskArbitration) · MetadataProvider    │
│     (Spotlight) · LaunchServicesProvider · TrashProvider(NSWorkspace) ·        │
│     AuthorizationProvider · ClockProvider · ProcessRunner(shell fallback)      │
├──────────────────────────────────────────────────────────────────────────────┤
│      macOS native frameworks (Foundation, System, Darwin, DiskArbitration,     │
│      CoreServices, Security, CryptoKit, AppKit)   ← ONLY L5 touches these      │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Layer responsibilities.**

| Layer | Owns | May NOT |
|---|---|---|
| L1 Presentation | Argument parsing (spec 08), TUI rendering (spec 25), JSON schema out, error→exit-code mapping | Contain cleaning logic, touch the filesystem, decide safety |
| L2 Application | Sequencing a run, selecting plugins, applying run-mode policy, aggregating a `SessionReport`, owning the cancellation token | Implement scan/scoring/deletion; know ANSI or JSON details |
| L3 Domain+Engine | The vocabulary (Core) and the algorithms (Engine): enumeration, scoring, staging, purge, rollback, invariant enforcement | Import a plugin, import a UI type, call native frameworks directly |
| L4 Plugins | Category knowledge: *where* junk lives, *what* it means, category-specific Evidence | Reach the OS directly, delete anything, bypass staging or protected paths |
| L5 Platform | Every syscall/framework call, behind `Sendable` protocol adapters | Contain policy or domain rules |

## 3. Component diagram

```
        ┌─────────────────────────────────────────────────────────────┐
        │  cleaner (executable, ArgumentParser command tree)          │  L1
        │  scan · clean · rollback · doctor · config · profile …      │
        └───────────────┬─────────────────────────────┬───────────────┘
                        │ builds RunRequest            │ renders
                        ▼                              ▼
        ┌───────────────────────────┐      ┌───────────────────────────┐
        │  RunCoordinator           │      │  CleanerTUI / JSONEmitter  │ L1/L2
        │  (Application)            │◀────▶│  Presenter (protocol)      │
        └───┬─────────┬─────────┬───┘      └───────────────────────────┘
            │         │         │  AsyncStream<RunEvent>
   resolves │  drives │  drives │
            ▼         ▼         ▼
     ┌──────────┐ ┌────────┐ ┌───────────┐
     │ Plugin   │ │ Scan   │ │ Cleanup   │                              L3
     │ Resolver │ │ Engine │ │ Engine    │──▶ StagingManager ─▶ Rollback
     └────┬─────┘ └───┬────┘ └─────┬─────┘        │(actor)      Engine
          │           │            │              ▼
          │           │      ┌───────────────────────────┐
          │           │      │ ProtectedPathGuard +       │  hard invariants (Art.4.4/5)
          │           │      │ SafetyScorer + RuleEngine  │
          │           │      └───────────────────────────┘
          │           │
          ▼           ▼   (both go THROUGH the SDK, never around it)
     ┌─────────────────────────────┐
     │  CleanerPluginAPI  (SDK)    │  CleanerPlugin, PluginContext, PluginManifest  L4
     └───────────┬─────────────────┘
                 │ registered plugins
     ┌───────────▼──────────────────────────────────────────────┐
     │ TrashPlugin  XcodePlugin  BrowserPlugin  DockerPlugin  …  │
     └───────────┬──────────────────────────────────────────────┘
                 │ every OS access injected as a provider
     ┌───────────▼──────────────────────────────────────────────┐
     │ FileSystemProvider VolumeProvider MetadataProvider …      │  L5
     └───────────────────────────────────────────────────────────┘
                 │
         macOS native frameworks (only here)
```

Key structural facts:

- **Presenter is a protocol** (L2 boundary). `CleanerTUI` and `JSONEmitter` are two
  conformers; the coordinator emits an `AsyncStream<RunEvent>` and does not know which is
  attached. This is how `--json` and interactive TUI share the core.
- **Plugins receive a `PluginContext`, not the engine.** The context hands them provider
  protocols (L5) and a config slice — never `ScanEngine`/`StagingManager`. A plugin
  physically *cannot* call `purge()`; the type isn't in its dependency graph.
- **The SafetyScorer, RuleEngine, and ProtectedPathGuard sit between plugin output and any
  mutation.** Findings enter one door; the engine re-scores, re-checks paths, and gates.

## 4. The dependency rule

> **Dependencies point inward (toward the domain) and downward (toward platform adapters).
> Nothing in an inner layer names a type from an outer layer. Plugins depend on the stable
> SDK (`CleanerPluginAPI`), never on `CleanerEngine` internals.**

Concretely, as an allowed-import matrix (✓ = may `import`; blank = forbidden, enforced by
the SPM target graph in spec 12):

```
             imports →  Core Engine PluginAPI Platform TUI Config Report App/CLI
 CleanerCore            —    ·      ·         ·        ·   ·      ·      ·
 CleanerEngine          ✓    —      ✓(types)  ✓        ·   ·      ·      ·
 CleanerPluginAPI       ✓    ·      —         ·(proto) ·   ·      ·      ·
 CleanerPlatform        ✓    ·      ·         —        ·   ·      ·      ·
 CleanerPlugins         ✓    ·      ✓         ·        ·   ·      ·      ·
 CleanerTUI             ✓    ·      ·         ·        —   ·      ·      ·
 cleaner (CLI/App)      ✓    ✓      ✓         ✓        ✓   ✓      ✓      —
```

Consequences that make this rule *real*, not aspirational:

- `CleanerCore` imports nothing but the standard library + `System`. It compiles without
  Foundation-heavy frameworks, so domain tests are instant.
- `CleanerPluginAPI` depends on `Core` (for `Finding`, `Item`, `RiskLevel`, …) and defines
  the *provider protocols* it needs, but does **not** depend on `CleanerEngine`. A plugin can
  be compiled and unit-tested with zero engine code present.
- Only the **composition root** (the `cleaner` executable, §9) is allowed to see every
  target at once and wire them together. Everything else is deliberately near-sighted.

The rule is what buys us Constitution principle 7 ("extensibility without core edits"): a new
plugin adds an edge into `CleanerPluginAPI` and nothing else changes.

## 5. Data & control flow for a full `clean` run

Read-only scan on the left half; the first mutation happens only after `confirm`.

```mermaid
sequenceDiagram
    autonumber
    participant U as User/TTY
    participant CLI as cleaner (L1)
    participant RC as RunCoordinator (L2)
    participant Cfg as ConfigLoader
    participant PR as PluginResolver
    participant P as Plugin(s) (L4)
    participant SE as ScanEngine (L3)
    participant SS as SafetyScorer+RuleEngine
    participant PG as ProtectedPathGuard
    participant CE as CleanupEngine
    participant ST as StagingManager (actor)
    participant RP as ReportBuilder
    participant AU as AuditSink

    U->>CLI: cleaner clean --include medium
    CLI->>CLI: parse args (ArgumentParser) → RunRequest
    CLI->>RC: run(RunRequest, presenter)
    RC->>Cfg: load(config.yml, profile, env)
    Cfg-->>RC: EffectiveConfig (+protected paths, run mode)
    RC->>PR: resolve(config, requested categories)
    PR-->>RC: [ResolvedPlugin] (validated manifests)

    Note over RC,SE: SCAN phase — read-only, streaming, cancellable
    loop per plugin (bounded TaskGroup)
        RC->>SE: scan(plugin, PluginContext)
        SE->>P: scan(context) -> AsyncStream<Finding>
        P-->>SE: Finding … Finding (streamed)
        SE->>SS: score+ruleAdjust(Finding)
        SS-->>SE: Finding' (engine SafetyScore/RiskLevel)
        SE->>PG: validate roots ∩ allow − deny (Art.5)
        PG-->>SE: accepted | rejected(safety)
        SE-->>RC: RunEvent.found(Finding')  (AsyncStream)
    end
    RC-->>CLI: preview (grouped, sized, risk-colored)
    CLI-->>U: render preview + reclaim estimate

    Note over U,CLI: CONFIRM gate (skipped by --yes policy; forced typed-confirm for 🔴)
    U->>CLI: confirm selection (y / typed / q)
    CLI->>RC: proceed(selectedItems) | cancel(exit 5)

    Note over RC,ST: CLEANUP phase — mutation, staged by default
    alt dry-run
        RC->>RP: record intended dispositions (no mutation)
    else execute
        loop per confirmed Item
            RC->>CE: dispose(Item, Disposition.stage)
            CE->>PG: re-check invariants (TOCTOU guard)
            CE->>ST: move(Item → staging/<session>/)
            ST-->>CE: StagedRecord (measured reclaim)
            CE->>AU: append NDJSON audit event
            CE-->>RC: RunEvent.cleaned(Item, reclaim)
        end
    end

    RC->>RP: finalize(SessionReport)
    RP-->>CLI: SessionReport
    CLI-->>U: summary (reclaimed, skipped, rollback hint)
    CLI->>CLI: exit code (0 / 3 partial / 5 / 7 / 8)
```

Phase boundaries and their guarantees:

1. **parse** → `RunRequest` (pure value; no I/O). Bad flags exit 2 here.
2. **load config** → `EffectiveConfig` merges file + profile + env + CLI overrides
   (spec 24). Invalid config exits 6.
3. **resolve plugins** → each `PluginManifest` validated (id unique, API version compatible,
   declared roots inside allow-space). A bad manifest → skip that plugin, degrade toward
   exit 3/7 (§7).
4. **scan (streaming)** → plugins emit `AsyncStream<Finding>`; the engine re-scores and
   guards *every* Finding. Read-only invariant: the ScanEngine holds no mutating provider.
5. **build findings / preview** → grouped, de-duplicated, sized with the *shared* reclaim
   measurement (CC-10). This same estimate is what a dry-run reports.
6. **confirm** → interactive selection, or `--yes` policy (auto-select 🟢, honor
   `--include`, never 🔴), or non-TTY refusal.
7. **cleanup (stage)** → `CleanupEngine` re-validates each Item against the guard (TOCTOU),
   moves to staging via `StagingManager` (an actor), measures actual freed allocation.
8. **report** → `SessionReport` assembled from the same event stream shown live.
9. **audit** → every mutation is an append-only NDJSON line written *before* the engine
   reports the item as cleaned (durability for principle 8).

## 6. Concurrency architecture mapped onto the layers

Swift Concurrency primitives (CC-3, tech-stack §5) are assigned per layer so that all shared
mutable state lives in actors and all fan-out is structured (cancellable) `TaskGroup`s.

```
L2 RunCoordinator ── owns the root Task + a single CancellationToken (Task tree)
        │
        ├─ AsyncStream<RunEvent> ───────────────▶ Presenter (TUI/JSON) consumes serially
        │
        └─ withThrowingTaskGroup  ── one child Task per plugin root
                 │  bounded by ConcurrencyLimiter (SSD vs HDD, from VolumeProvider, spec 17)
                 ▼
           ScanEngine per plugin
                 │  AsyncStream<Finding>  (back-pressured; plugin is the producer)
                 ▼
           actor ScanAccumulator   ── dedup + running reclaim total (no locks)
```

| Concern | Primitive | Where |
|---|---|---|
| Run-wide lifetime & cancellation | one root `Task`, cooperative `Task.checkCancellation()` at directory/plugin boundaries | L2 RunCoordinator |
| Plugin fan-out | `withThrowingTaskGroup`, width-limited by `ConcurrencyLimiter` | L2→L3 |
| Streaming findings | `AsyncStream<Finding>` (producer = plugin, consumer = engine) | L3/L4 |
| Live UI events | `AsyncStream<RunEvent>` (producer = coordinator, consumer = presenter) | L2→L1 |
| Shared mutable state | `actor` (`ScanAccumulator`, `StagingManager`, `AuditSink`) | L3/L5 |
| Provider isolation | providers are `Sendable` protocols; heavy ones are actors | L5 |

Rules: no `DispatchQueue` in new code (CC-3). Everything crossing an actor boundary is
`Sendable` — `Finding`, `Item`, `RunEvent` are frozen value types (spec 14). Cancellation
propagates structurally: cancelling the root Task cancels every plugin's scan group, and each
plugin's `scan` stream terminates at its next `checkCancellation()`.

## 7. Error propagation path

Every error conforms to `CleanerError` (Constitution Article 6) and carries an `ExitCode`
(Article 7). Errors flow **outward** through the layers, are classified once at the boundary,
and never silently vanish.

```
 plugin throws ─┐
 provider throws┤
 guard rejects ─┼─▶ Engine catches ─▶ classify ─▶ RunEvent.failure(item, CleanerError)
 config invalid─┘        │                              │  (per-item: does NOT abort the run)
                         ▼                              ▼
                 fatal (safety/precondition)     accumulate in SessionReport.skipped
                         │                              │
                         ▼                              ▼
              RunCoordinator sets terminal ExitCode ◀── worst-of aggregation
                         │
                         ▼
              CLI maps ExitCode → process exit + human/JSON error render
```

Aggregation policy (deterministic, principle 5):

- A **single item failing** (throwing plugin `clean`, provider I/O error) → item marked
  skipped, run continues, terminal code becomes **3 (partial)** unless already worse.
- A **plugin failing to load / violating its contract** → that plugin's Findings dropped,
  code **7 (plugin)**; other plugins proceed (error isolation, spec 13 §9).
- A **safety-invariant hit** (attempt to touch a protected path, symlink escape) → the
  offending action is refused and the run aborts with **8 (safety)**. This is fatal by
  design: it means a plugin or rule tried something the Constitution forbids.
- **Cancellation** (Ctrl-C / `q` / timeout) → **5 (cancelled)**; already-staged items remain
  staged and are reported. **2/6/10** are raised pre-scan (usage/config/precondition).
- Worst-of wins: `max(severity)` across all events, with `safety` and `precondition`
  short-circuiting. The mapping table lives in spec 27; this spec only fixes the *path*.

## 8. How dry-run, `--yes`, and `--json` reuse the same core

All three are **policy/presentation variations injected into the same pipeline** — no forked
code paths, which is what keeps dry-run numbers honest (principle 3).

```
                     ┌──────────── RunMode (value, from RunRequest) ───────────┐
                     │ .interactive │ .dryRun │ .assumeYes(include:) │ .json    │
                     └───────┬──────────────────────────────────────────────────┘
                             ▼
          scan + score + guard  ← IDENTICAL for every mode (same measurement code)
                             ▼
        ┌────────────────────┴─────────────────────┐
        │ ConfirmationPolicy (injected)             │
        │  interactive → prompt; assumeYes → auto   │
        │  select 🟢 (+ --include);  json → same as  │
        │  assumeYes but machine input; dryRun → all │
        │  selected but Disposition forced to .noop  │
        └────────────────────┬─────────────────────┘
                             ▼
        ┌────────────────────┴─────────────────────┐
        │ Presenter (injected)                      │
        │  interactive/assumeYes → CleanerTUI       │
        │  json → JSONEmitter (NDJSON events + final │
        │         SessionReport as JSON)             │
        └───────────────────────────────────────────┘
```

- **`--dry-run`** swaps the `CleanupEngine`'s disposer for a *recording* disposer that
  computes the exact same reclaim (CC-10) and writes the same audit events tagged
  `dryRun:true`, but performs no move. The report is byte-for-byte comparable to a real run's
  *plan*.
- **`--yes`** replaces the interactive `ConfirmationPolicy` with an auto-policy: auto-select
  🟢, include 🟡 only if `--include medium`, **never** 🔴 (Article 4.1). Still runs the full
  guard.
- **`--json`** attaches `JSONEmitter` as the `Presenter` and defaults confirmation to the
  `--yes` policy (machine use has no TTY). Findings and the final report serialize via the
  domain's `Codable` conformances (spec 15) — the *same* structs the TUI renders.

Because `RunMode`, `ConfirmationPolicy`, and `Presenter` are the only things that vary, a
single set of golden tests (spec 31) drives all four fronts through one engine.

## 9. Startup, DI, and the composition root

There is exactly **one** composition root: the `cleaner` executable's `main`. It is the only
place allowed to import every target and construct concrete adapters. Everything below
receives dependencies through initializers/`PluginContext` — no service locator, no global
singletons (they defeat the dependency rule and hurt testability).

```swift
// executable target `cleaner` — the ONLY module that sees all layers.
@main struct Cleaner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleaner",
        subcommands: [Scan.self, Clean.self, Rollback.self, Doctor.self, Config.self]
    )
}

// Composition root: build the object graph once, inject downward.
struct CompositionRoot {
    func makeRunCoordinator(_ env: ProcessEnvironment) -> RunCoordinator {
        // L5 — concrete platform adapters (the only `import DiskArbitration` etc.)
        let fs         = DarwinFileSystemProvider()
        let volumes    = DiskArbitrationVolumeProvider()
        let metadata   = SpotlightMetadataProvider()
        let launchSvc  = LaunchServicesProvider()
        let trash      = NSWorkspaceTrashProvider()
        let auth       = AuthorizationServicesProvider()
        let clock      = SystemClockProvider()
        let audit      = NDJSONAuditSink(url: env.cleanerHome.appending("logs/audit"))

        // L3 — engine wired to adapters + shared safety components
        let guardEngine = ProtectedPathGuard(denyList: .constitutional, volumes: volumes)
        let scorer      = SafetyScorer(clock: clock, metadata: metadata)
        let staging     = StagingManager(fs: fs, home: env.cleanerHome)   // actor
        let scan        = ScanEngine(fs: fs, volumes: volumes, limiter: .init(volumes))
        let cleanup     = CleanupEngine(guard: guardEngine, staging: staging, audit: audit)

        // L4 — static plugin registry (compile-time; CC-8). See spec 13.
        let registry    = PluginRegistry(manifests: BuiltinPlugins.all)

        // Providers bundled for injection into each PluginContext.
        let providers   = ProviderBundle(fs: fs, volumes: volumes, metadata: metadata,
                                         launchServices: launchSvc, trash: trash,
                                         process: SandboxedProcessRunner(), clock: clock)

        return RunCoordinator(registry: registry, resolver: PluginResolver(registry),
                              scan: scan, scorer: scorer, guard: guardEngine,
                              cleanup: cleanup, providers: providers,
                              reportBuilder: ReportBuilder(), audit: audit)
    }
}
```

Properties this buys:

- **Testability:** any layer is instantiated in a test with fake providers (an in-memory
  `FileSystemProvider`, a `FixedClock`) — no disk, no OS (tech-stack §9's virtual FS
  fixtures). The composition root is the *only* thing that names real adapters.
- **Determinism:** the graph is built once, front-to-back, no lazy globals whose init order
  could vary (principle 5).
- **Static plugin wiring (CC-8):** `BuiltinPlugins.all` is a compile-time array; discovery is
  a lookup, not a filesystem/dlopen scan. Forward path to dynamic loading is a v2/v3 concern
  (spec 13 §5).

## 10. Open Questions

- **OQ-11.1** Should the `Presenter` boundary be a single `AsyncStream<RunEvent>` consumer,
  or a richer bidirectional channel so the TUI can push *selection edits* back mid-scan?
  Leaning: one-way events out for v1; interactive selection happens after scan completes.
  Revisit if live-during-scan selection becomes a UX requirement (spec 25).
- **OQ-11.2** Where does incremental-scan cache (spec 17) sit — inside `ScanEngine` (L3) or a
  dedicated L5 provider? Leaning: an `L5 ScanCacheProvider` so the engine stays pure.
- **OQ-11.3** Do we need a distinct `SessionController` between the CLI command structs and
  `RunCoordinator`, or is the coordinator sufficient? Leaning: fold session lifecycle
  (UUID, log scoping) into the coordinator for v1; split only if commands diverge.
- **OQ-11.4** Should `--json` stream NDJSON events live, or emit a single JSON document at the
  end? Leaning: both — NDJSON events for progress, a final JSON `SessionReport`; gated by
  `--json-stream`. Confirm against spec 26 CLI UX.

## 11. Dependencies

**Consumes:** 00 (layers must enforce Articles 1, 4.4, 5, 7), 07 (streaming/cancellation
NFRs shape §6), 10 (all primitive choices: Swift Concurrency, ArgumentParser, swift-log).
**Feeds:** 12 (this layering becomes the SPM target graph), 13 (the plugin/SDK boundary and
`PluginContext` originate here), 14–21 (each engine is a named L3 component here), 24
(config load step), 25/26 (Presenter boundary), 27 (error-path → exit-code mapping), 28
(audit sink placement).
