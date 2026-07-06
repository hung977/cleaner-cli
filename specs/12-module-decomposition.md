# 12 — Module Decomposition

> **Phase C · Depends on:** 00-constitution, 10-tech-stack, 11-architecture-overview ·
> **Depended on by:** 13 (plugins), 14–21 (engines), 31 (testing), 32 (packaging), 34 (CI).

## 1. Purpose

Turn the layered architecture (spec 11) into a concrete **SPM package graph**: every target,
its single responsibility, its public API surface, and its allowed dependency edges. The
target boundaries *are* the enforcement mechanism for the dependency rule (spec 11 §4) — the
compiler refuses an illegal `import`, so the architecture cannot silently rot. This spec also
maps each functional-requirement area (spec 06) onto an owning target for traceability
(Constitution Article 9).

## 2. Target inventory

One SPM package, `cleaner-cli`, containing **10 library targets + 1 executable + their test
targets**. Each library maps to a layer in spec 11.

| Target | Kind | Layer | Responsibility (one sentence) |
|---|---|---|---|
| `CleanerCore` | library | L3 domain | The shared vocabulary: `Finding`, `Item`, `Disposition`, `RiskLevel`, `SafetyScore`, `Evidence`, `CleanerError`, `ExitCode` — pure value types, no I/O. |
| `CleanerPlatform` | library | L5 | Native-API adapters behind `Sendable` provider protocols (FS, volumes, Spotlight, LaunchServices, Trash, Authorization, clock, process). |
| `CleanerConfig` | library | L2/L3 | Load, merge, and validate `config.yml`, profiles, env, and CLI overrides into an `EffectiveConfig`. |
| `CleanerLogging` | library | cross-cut | `swift-log` bootstrap + the append-only NDJSON audit sink. |
| `CleanerPluginAPI` | library | L4 boundary | The stable **SDK**: `CleanerPlugin`, `PluginContext`, `PluginManifest`, capability flags, provider protocols plugins are handed. |
| `CleanerEngine` | library | L3 | The algorithms: `ScanEngine`, `RuleEngine`, `SafetyScorer`, `ProtectedPathGuard`, `CleanupEngine`, `StagingManager`, `RollbackEngine`. |
| `CleanerPlugins` | library | L4 | Bundled first-party plugins (Trash, Xcode, Browser, Docker, Logs, Duplicates, LargeOld, Simulators…), each in its own source dir. |
| `CleanerReport` | library | L2 | Assemble `SessionReport`; serialize to human text, JSON, Markdown, HTML. |
| `CleanerTUI` | library | L1 | The owned component layer over ANSI (spec 25): renderer, widgets, key routing, non-TTY fallback. |
| `CleanerApp` | library | L2 | Orchestration: `RunCoordinator`, `PluginResolver`, `ConfirmationPolicy`, `Presenter` protocol, `RunMode` policy. |
| `cleaner` | **executable** | L1 | ArgumentParser command tree + the single composition root (spec 11 §9). |

Why split orchestration (`CleanerApp`) out of the executable: the coordinator is the most
test-heavy piece (all the run-mode/policy logic), and a library is far easier to unit-test
than an `@main`. The executable stays a thin wiring shell.

Test targets (spec 31): one per library plus integration/e2e.

| Test target | Tests | Notable fixtures |
|---|---|---|
| `CleanerCoreTests` | value semantics, `Codable`, risk/score mapping | none (pure) |
| `CleanerPlatformTests` | adapter contract tests | temp dirs, `VirtualFileSystem` |
| `CleanerConfigTests` | YAML parse/merge/validate, bad-config → exit 6 | fixture YAMLs |
| `CleanerEngineTests` | scan/score/guard/stage/rollback | `VirtualFileSystem`, `FixedClock` |
| `CleanerPluginAPITests` | manifest validation, capability negotiation | fake `PluginContext` |
| `CleanerPluginsTests` | per-plugin scan/clean against synthesized trees | plugin fixtures |
| `CleanerReportTests` | snapshot of text/JSON/MD/HTML output | golden files |
| `CleanerTUITests` | rendered-frame snapshots, width/emoji, resize | golden frames |
| `CleanerAppTests` | run-mode policy, dry-run == plan, error aggregation | fake engine + providers |
| `CleanerIntegrationTests` | full `clean` on a synthesized volume, exit codes | large synthetic tree |

## 3. Package graph (dependency edges)

Arrows = "depends on / may import". The graph is a **DAG**; the compiler enforces it.

```
                              ┌───────────────┐
                              │   cleaner     │  (executable, composition root)
                              │  (L1 + wiring)│
                              └──────┬────────┘
             ┌───────────────┬───────┼────────┬───────────────┬──────────────┐
             ▼               ▼       ▼        ▼               ▼              ▼
        CleanerApp      CleanerTUI  CleanerReport  CleanerPlugins   CleanerConfig  CleanerLogging
             │               │       │             │                 │
     ┌───────┼───────┐       │       │        ┌────┴─────┐           │
     ▼       ▼       ▼       ▼       ▼        ▼          ▼           ▼
 CleanerEngine  CleanerPluginAPI   CleanerPlatform   CleanerPluginAPI  (Yams)
     │  │   │        │                  │                 │
     ▼  ▼   ▼        ▼                  ▼                 ▼
 CleanerPlatform  CleanerCore ◀────────────────────────── CleanerCore
     │                                                        ▲
     └──────────────────────▶ CleanerCore ────────────────────┘

Legend of the load-bearing edges:
  CleanerCore        → (nothing but stdlib + System)          ← the sink of the DAG
  CleanerPluginAPI   → CleanerCore                            (SDK sees vocabulary only)
  CleanerPlatform    → CleanerCore
  CleanerEngine      → CleanerCore, CleanerPlatform, CleanerPluginAPI(types)
  CleanerPlugins     → CleanerPluginAPI, CleanerCore          (NOT CleanerEngine!)
  CleanerApp         → CleanerEngine, CleanerPluginAPI, CleanerCore, CleanerReport
  cleaner (exe)      → everything (only place allowed to)
```

The single most important edge that is **absent**: `CleanerPlugins ─X→ CleanerEngine`.
A bundled plugin cannot import the engine; it links only the SDK. This is the compiler-level
guarantee behind "plugins propose, engine disposes" (spec 11 §3, Constitution Art. 4.4).

## 4. `Package.swift` sketch

Illustrative — not the final pinned manifest (versions live in tech-stack §11).

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cleaner-cli",
    platforms: [.macOS(.v13)],                                   // Constitution Art.6
    products: [
        .executable(name: "cleaner", targets: ["cleaner"]),
        .library(name: "CleanerPluginAPI", targets: ["CleanerPluginAPI"]), // third-party SDK
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-metrics", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.4.0"), // test-only
    ],
    targets: [
        // ── L3 domain ────────────────────────────────────────────────────────
        .target(name: "CleanerCore",
                dependencies: [.product(name: "SystemPackage", package: "swift-system")]),

        // ── L5 platform adapters (only these import native frameworks) ────────
        .target(name: "CleanerPlatform",
                dependencies: ["CleanerCore",
                               .product(name: "Collections", package: "swift-collections")]),

        // ── cross-cut ─────────────────────────────────────────────────────────
        .target(name: "CleanerLogging",
                dependencies: ["CleanerCore",
                               .product(name: "Logging", package: "swift-log"),
                               .product(name: "Metrics", package: "swift-metrics")]),
        .target(name: "CleanerConfig",
                dependencies: ["CleanerCore", .product(name: "Yams", package: "Yams")]),

        // ── L4 SDK (the stable surface third parties link) ────────────────────
        .target(name: "CleanerPluginAPI", dependencies: ["CleanerCore"]),

        // ── L3 engine ─────────────────────────────────────────────────────────
        .target(name: "CleanerEngine",
                dependencies: ["CleanerCore", "CleanerPlatform",
                               "CleanerPluginAPI", "CleanerLogging"]),

        // ── L4 bundled plugins — SDK only, NOT the engine ─────────────────────
        .target(name: "CleanerPlugins",
                dependencies: ["CleanerPluginAPI", "CleanerCore"]),

        // ── L2 report + orchestration ─────────────────────────────────────────
        .target(name: "CleanerReport", dependencies: ["CleanerCore"]),
        .target(name: "CleanerApp",
                dependencies: ["CleanerEngine", "CleanerPluginAPI",
                               "CleanerCore", "CleanerReport", "CleanerConfig",
                               "CleanerLogging"]),

        // ── L1 TUI ────────────────────────────────────────────────────────────
        .target(name: "CleanerTUI", dependencies: ["CleanerCore", "CleanerReport"]),

        // ── L1 executable = composition root ──────────────────────────────────
        .executableTarget(name: "cleaner",
                dependencies: ["CleanerApp", "CleanerTUI", "CleanerPlugins",
                               "CleanerPlatform", "CleanerConfig", "CleanerReport",
                               "CleanerLogging",
                               .product(name: "ArgumentParser", package: "swift-argument-parser")]),

        // ── tests (one per lib + integration) ─────────────────────────────────
        .testTarget(name: "CleanerCoreTests",     dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerEngineTests",   dependencies: ["CleanerEngine", "CleanerTestKit"]),
        .testTarget(name: "CleanerAppTests",      dependencies: ["CleanerApp", "CleanerTestKit"]),
        .testTarget(name: "CleanerPluginsTests",  dependencies: ["CleanerPlugins", "CleanerTestKit"]),
        // … one per library …
        // shared fixtures: VirtualFileSystem, FixedClock, FakeProviders
        .target(name: "CleanerTestKit",
                dependencies: ["CleanerCore", "CleanerPluginAPI"]),
        .benchmarkTarget?(name: "ScanBench", dependencies: ["CleanerEngine"]),  // spec 30
    ]
)
```

## 5. Per-target public vs internal surface

Only what the layer *above* legitimately needs is `public`; everything else is `internal`
(default) or `package` (visible within the package but not to third-party SDK consumers).

### `CleanerCore` (widest public surface — it's the shared vocabulary)
```swift
public struct Item: Sendable, Hashable, Codable { … }        // atomic unit (glossary)
public struct Finding: Sendable, Codable { public let item: Item; public let risk: RiskLevel
        public let score: SafetyScore; public let evidence: [Evidence]; public let rationale: String }
public enum Disposition: Sendable, Codable { case stage, trash, purge, skip }
public enum RiskLevel: Sendable, Codable { case safe, medium, dangerous }   // 🟢🟡🔴 Art.4.1
public struct SafetyScore: Sendable, Codable { public let value: Int /*0…100*/ }
public struct Evidence: Sendable, Codable { public let kind: EvidenceKind; public let detail: String }
public protocol CleanerError: Error, Sendable { var exitCode: ExitCode { get } }
public enum ExitCode: Int32, Sendable { case ok = 0, general = 1, usage = 2, partial = 3,
        permission = 4, cancelled = 5, config = 6, plugin = 7, safety = 8, precondition = 10 }
```
Internal: none of substance — Core is almost entirely public by design.

### `CleanerPluginAPI` (the second-widest — it is the third-party contract, semver'd)
```swift
public protocol CleanerPlugin: Sendable { /* full protocol in spec 13 */ }
public struct PluginManifest: Sendable { public let id, name: String; public let apiVersion: SemVer
        public let category: Category; public let declaredRoots: [RootSpec]
        public let defaultRisk: RiskLevel; public let capabilities: CapabilitySet }
public struct PluginContext: Sendable { /* injected providers + config slice, spec 13 */ }
// Provider protocols plugins receive (subset of Platform's, narrowed & read-mostly):
public protocol FileSystemReading: Sendable { … }
public protocol MetadataReading: Sendable { … }
```
Internal: nothing — every symbol here is a contract point.

### `CleanerEngine` (narrow public surface — it hands out *behaviors*, hides *algorithms*)
```swift
public actor StagingManager { public func stage(_:Item) async throws -> StagedRecord }
public struct ScanEngine: Sendable { public func scan(_ plugin: any CleanerPlugin,
        _ ctx: PluginContext) -> AsyncThrowingStream<Finding, Error> }
public struct CleanupEngine: Sendable { public func dispose(_:Item, as:Disposition) async throws }
public struct ProtectedPathGuard: Sendable { public func validate(_:Item) throws }
// INTERNAL: the scoring weights, the getattrlistbulk enumerator, the TOCTOU re-check,
// the staging directory layout — all `internal`, swappable without an API break.
```

### `CleanerPlatform`
Public: the provider *protocols* and their concrete adapters (so the composition root can
construct them). Internal: every raw `import DiskArbitration`/`CoreServices` call site.

### `CleanerApp`, `CleanerTUI`, `CleanerReport`, `CleanerConfig`, `CleanerLogging`
Public: the one entry type each (`RunCoordinator`, `TerminalRenderer`/`Presenter` conformer,
`ReportBuilder`, `ConfigLoader`, `LoggingBootstrap`). Everything else internal.

Rule of thumb encoded in review (spec 31/34): a symbol is `public` only if a target *above*
it in §3 names it. CI runs a linter that flags gratuitous `public`.

## 6. Mapping FR-areas (spec 06) to owning targets

Each capability-matrix area (Constitution §2, detailed in spec 06) has exactly one *owning*
target, satisfying the traceability rule (Art. 9: every FR → ≥1 owning module).

| FR area (spec 06) | Category | Owning target | Collaborators |
|---|---|---|---|
| Developer caches (npm, pip, gradle, SPM…) | plugin | `CleanerPlugins/DevCache` | Engine, Platform |
| Build artifacts / DerivedData | plugin | `CleanerPlugins/Xcode` | Platform (LaunchServices) |
| Browser caches | plugin | `CleanerPlugins/Browser` | Platform (FS) |
| Logs (system/app/`~/Library/Logs`) | plugin | `CleanerPlugins/Logs` | Engine |
| Duplicates | plugin | `CleanerPlugins/Duplicates` | Platform (CryptoKit), Engine |
| Large / old files | plugin | `CleanerPlugins/LargeOld` | Platform (Spotlight) |
| Stale SDKs & simulators | plugin | `CleanerPlugins/Simulators` | Platform (process: `simctl`) |
| Docker / container junk | plugin | `CleanerPlugins/Docker` | Platform (process, fallback) |
| Trash emptying | plugin | `CleanerPlugins/Trash` | Platform (NSWorkspace) |
| Scan enumeration & incremental cache | engine | `CleanerEngine` (ScanEngine) | Platform |
| Rule engine (whitelist/blacklist/target rules) | engine | `CleanerEngine` (RuleEngine) | Config |
| Safety scoring | engine | `CleanerEngine` (SafetyScorer) | Core, Platform |
| Staging / purge / rollback | engine | `CleanerEngine` (Staging/Cleanup/Rollback) | Platform, Logging |
| Protected-path enforcement | engine | `CleanerEngine` (ProtectedPathGuard) | Core, Platform |
| Preview / confirm / interactive select | ux | `CleanerTUI` + `CleanerApp` | Report |
| `--json` / report export | ux | `CleanerReport` | Core |
| Config & profiles | config | `CleanerConfig` | Core |
| Permissions / elevation | platform | `CleanerPlatform` (Authorization) | App |
| Logging & audit | observability | `CleanerLogging` | all mutating paths |
| Command tree / arg parsing | cli | `cleaner` (exe) | App |

The full FR-###-to-target rows land in spec 06's traceability matrix; this table is the
module-side half.

## 7. Build-time and testability benefits of the split

**Incremental build.** The DAG's leaf, `CleanerCore`, changes rarely; the churny targets
(`CleanerPlugins`, `CleanerTUI`) sit at the top. Editing a plugin recompiles that one target
and the executable — not the engine, not the domain. A one-line TUI tweak never rebuilds the
scan engine. On CI, targets build in parallel across the DAG's width (spec 34 caches per-
target module artifacts).

**Compile-time architecture enforcement.** The missing `Plugins→Engine` edge (§3) is not a
convention someone can forget — it is absent from `Package.swift`, so an attempt to
`import CleanerEngine` from a plugin fails to compile. The dependency rule (spec 11 §4) is
mechanically guaranteed.

**Testability.**
- `CleanerCore` and `CleanerConfig` are pure/near-pure → sub-second unit suites, no disk.
- `CleanerEngine`/`CleanerApp` tests inject `CleanerTestKit`'s `VirtualFileSystem`,
  `FixedClock`, and `FakeProviders` — the engine never sees a real syscall in a unit test
  (tech-stack §9). This is only possible because Platform is a separate, protocol-fronted
  target.
- Each bundled plugin is testable in isolation against a synthesized tree with a fake
  `PluginContext`, because it depends only on the SDK.
- The `cleaner` executable has almost no logic to test (it's wiring), so the untestable
  `@main` surface is minimized.

**SDK stability / distribution.** `CleanerPluginAPI` is a *product* (§4) — third parties can
depend on just it (spec 13 §5 forward path). Keeping it a standalone target with a
semver'd surface means the rest of the package can refactor freely without breaking plugin
authors.

**Parallelizable ownership.** Teams/agents own targets with crisp contracts; a plugin author
never needs to read engine internals, only the SDK.

## 8. Open Questions

- **OQ-12.1** Split `CleanerPlugins` into one SPM target *per plugin* now, or keep a single
  target with per-plugin source dirs until dynamic loading (v2)? Leaning: single target, sub-
  directories, for v1 (simpler graph, faster builds); split when a plugin needs distinct
  dependencies (e.g. Docker's process adapter).
- **OQ-12.2** Is `CleanerTestKit` a `.target` shipped in the package or a separate test-only
  module? Leaning: internal `.target` gated so it never links into `cleaner`.
- **OQ-12.3** Should `CleanerReport`'s HTML export (heavy templating) be its own target to
  keep the core report light? Leaning: sub-module for now, split if template deps grow.
- **OQ-12.4** Does `CleanerConfig` belong to L2 or L3? It's consumed by both App and Engine
  (RuleEngine). Leaning: keep it dependency-light (Core + Yams only) so either may use it.

## 9. Dependencies

**Consumes:** 00 (Art. 6 naming, Art. 9 traceability), 10 (the pinned dependency set and
native frameworks that Platform wraps), 11 (the five layers become these targets; the
dependency rule becomes the DAG). **Feeds:** 13 (the `CleanerPluginAPI` surface and the
`Plugins`/`Engine` boundary), 14–21 (each engine spec elaborates a `CleanerEngine`
sub-component named here), 31 (the test targets and `CleanerTestKit`), 32 (products &
artifacts to package), 34 (per-target build/cache matrix).
