# 13 — Plugin Architecture

> **Phase C · Depends on:** 00-constitution (Art. 4, 5, 7; CC-8), 10-tech-stack, 11, 12 ·
> **Depended on by:** 14 (domain model), 17–22 (engines & safety), 36 (threat model),
> and every per-plugin spec in `specs/plugins/`.

## 1. Purpose

This is **the** extensibility spec. It defines the `CleanerPlugin` protocol, the
`PluginContext` a plugin runs inside, the lifecycle from discovery to disposal, the v1
static registration mechanism (and the v2/v3 dynamic forward path), capability negotiation,
how the engine enforces safety *on top of* untrusted plugin output, API versioning, error
isolation, and the trust model — with two worked examples (`TrashPlugin`, `XcodePlugin`).

The governing principle is Constitution Article 4.4: **plugins propose, the engine disposes.**
A plugin is a *detector and advisor*, not an actor on the filesystem. It answers "where is
this category of junk and why is it junk?"; it never answers "delete it." Every deletion goes
through the engine's guard and staging (spec 11 §5, spec 20). All names here match the domain
model spec 14 will formalize: `Finding`, `Item`, `Disposition`, `RiskLevel`, `SafetyScore`,
`Evidence`.

## 2. The plugin contract at a glance

```
        ┌──────────────────── a plugin can do exactly this ────────────────────┐
        │  READ the filesystem (via injected providers)                         │
        │  PRODUCE Findings (Item + proposed RiskLevel + Evidence + rationale)  │
        │  optionally ESTIMATE reclaim, describe a rollback HINT, AUDIT-annotate │
        │  when told to clean, IDENTIFY which staged Items to hand the engine    │
        └───────────────────────────────────────────────────────────────────────┘
        ┌──────────────────── a plugin can NEVER do this ──────────────────────┐
        │  call unlink/rename/FileManager directly (no such API in its context) │
        │  reach the OS directly (no `import Foundation` framework calls)        │
        │  raise its own SafetyScore above the engine scorer's ceiling          │
        │  touch a path outside its declared roots ∩ allow-space − deny-list    │
        │  bypass staging, or purge anything                                     │
        └───────────────────────────────────────────────────────────────────────┘
```

## 3. `CleanerPlugin` protocol

Lives in `CleanerPluginAPI` (spec 12 §5), semver'd as the third-party contract. Illustrative
signatures — not full implementations.

```swift
public protocol CleanerPlugin: Sendable {

    // ── Metadata (static identity; also mirrored in the manifest, §4) ──────────
    static var manifest: PluginManifest { get }        // id, name, category, apiVersion…
    var id: PluginID { get }                            // stable, reverse-DNS: "dev.cleaner.xcode"
    var category: Category { get }                      // grouping in preview (spec 09)
    var version: SemVer { get }                         // the plugin's own version
    var declaredRoots: [RootSpec] { get }               // where it looks; engine intersects w/ allow-space
    var defaultRisk: RiskLevel { get }                  // 🟢/🟡/🔴 baseline (Art. 4.1); engine may lower

    // ── Capabilities the plugin advertises (negotiation, §7) ───────────────────
    var capabilities: CapabilitySet { get }             // {dryRun, estimate, rollback, audit, incremental}

    // ── Configuration (called once after registration, before scan) ────────────
    func configure(_ slice: ConfigSlice) throws         // read its own config sub-tree; validate

    // ── Core capability: read-only scan → a stream of Findings ─────────────────
    func scan(_ context: PluginContext) -> AsyncThrowingStream<Finding, Error>

    // ── Core capability: clean confirmed Items. MUST NOT delete; it tells the ──
    //    engine how to dispose. Default impl below routes everything to .stage.  ─
    func clean(_ items: [Item], _ context: PluginContext) async throws -> [CleanDirective]

    // ── Optional capabilities (guarded by CapabilitySet; default impls provided)─
    func estimate(_ items: [Item], _ context: PluginContext) async throws -> ReclaimEstimate
    func audit(_ finding: Finding, _ context: PluginContext) async -> [Evidence]  // enrich record
    func rollbackHint(_ item: Item) -> RollbackHint?    // how to restore, if non-default
    func dispose() async                                // release scanners/handles (lifecycle §5)
}

// A plugin's "clean" output — a PROPOSAL, not an action. The engine validates & executes.
public struct CleanDirective: Sendable {
    public let item: Item
    public let proposedDisposition: Disposition         // usually .stage; .trash for TrashPlugin
    public let rollbackHint: RollbackHint?
}

public struct CapabilitySet: OptionSet, Sendable {
    public static let dryRun      = CapabilitySet(rawValue: 1 << 0)  // supports no-op preview
    public static let estimate    = CapabilitySet(rawValue: 1 << 1)  // fast size estimate w/o full scan
    public static let rollback    = CapabilitySet(rawValue: 1 << 2)  // items are restorable
    public static let audit       = CapabilitySet(rawValue: 1 << 3)  // enriches Evidence
    public static let incremental = CapabilitySet(rawValue: 1 << 4)  // honors scan cache (spec 17)
    public static let elevation   = CapabilitySet(rawValue: 1 << 5)  // may need admin paths (spec 23)
}
```

Default protocol extension provides `estimate` (sum allocated sizes via provider),
`audit` (returns `[]`), `rollbackHint` (nil → engine uses default staging restore),
`dispose` (no-op), and `clean` (maps every Item to `.stage`). A minimal plugin therefore
implements only `manifest`, `declaredRoots`, and `scan`.

## 4. `PluginManifest` — static declaration

The manifest is the plugin's *passport*, read at registration before any code from the plugin
runs the filesystem. It is what the resolver validates (§6) and the compile-time registry
stores (§5).

```swift
public struct PluginManifest: Sendable, Codable {
    public let id: PluginID                    // "dev.cleaner.xcode"  (unique; reverse-DNS)
    public let name: String                    // "Xcode Junk"
    public let category: Category              // .developer
    public let apiVersion: SemVer              // the CleanerPluginAPI version it was built against
    public let pluginVersion: SemVer
    public let declaredRoots: [RootSpec]       // e.g. ["~/Library/Developer/Xcode/DerivedData/**"]
    public let defaultRisk: RiskLevel
    public let capabilities: CapabilitySet
    public let requiresElevation: Bool         // maps to CapabilitySet.elevation
    public let trust: TrustLevel               // .firstParty / .signedThirdParty / .unsigned (spec 36)
}

public struct RootSpec: Sendable, Codable {    // a scoping declaration, not a free path
    public let base: RootBase                  // .home, .libraryCaches, .developer, .tmp — symbolic anchors
    public let glob: String                    // relative pattern under the anchor
}
```

`RootSpec` uses **symbolic anchors** (`.libraryCaches`, `.developer`), never absolute strings,
so the engine resolves them against the real user and can guarantee they land inside the
allow-space (Constitution Art. 5). A plugin declaring `base: .home, glob: "Documents/**"`
is *rejected at validation* because `~/Documents` is a protected root.

## 5. Lifecycle

```
 discover ──▶ validate ──▶ register ──▶ configure ──▶ scan ──▶ (preview/confirm) ──▶ clean ──▶ dispose
    │            │            │            │           │                              │          │
 v1: static   manifest     into the     ConfigSlice  AsyncStream                 CleanDirective release
 registry     checks       PluginRegistry handed     <Finding>   engine guards +   (proposal)  handles
 (BuiltinPlugins.all)      (id unique)   & validated  (read-only) stages           → engine acts
```

| Phase | Who runs it | What happens | Failure → |
|---|---|---|---|
| **discover** | `PluginRegistry` | v1: enumerate the compile-time `BuiltinPlugins.all` array. No dlopen, no FS scan (CC-8). | — |
| **validate** | `PluginResolver` | manifest well-formed; `id` unique; `apiVersion` compatible (§8); `declaredRoots` ⊆ allow-space − deny-list; `requiresElevation` consistent. | exit 7 (skip plugin) |
| **register** | `PluginRegistry` | store validated plugin keyed by `PluginID`. | exit 7 |
| **configure** | resolver | hand the plugin its `ConfigSlice`; plugin validates its own options. | exit 6 (config) |
| **scan** | `ScanEngine` | call `scan(context)`; consume the `AsyncThrowingStream<Finding>`; engine re-scores + guards each Finding. | isolate (§9) |
| **clean** | `CleanupEngine` | pass confirmed Items to `clean(items,ctx)`; receive `[CleanDirective]`; **engine** re-validates & stages. | isolate → exit 3 |
| **dispose** | coordinator | `dispose()` releases handles; happens even on cancellation (structured). | logged only |

### v1 registration: static, compile-time (CC-8)

```swift
// In CleanerPlugins — the compile-time registry the composition root injects (spec 11 §9).
public enum BuiltinPlugins {
    public static let all: [any CleanerPlugin] = [
        TrashPlugin(), XcodePlugin(), BrowserPlugin(), DevCachePlugin(),
        LogsPlugin(), DuplicatePlugin(), LargeOldPlugin(), SimulatorPlugin(), DockerPlugin(),
    ]
}
```

**Why static/in-process for v1** (Constitution CC-8, ADR-0008): safety and performance. An
in-process, statically-linked plugin shares the engine's address space, so there is no IPC
cost on the hot scan path (principle 9), and — crucially — the plugin has **no independent
filesystem authority**: it can only act through the injected providers and can only *propose*
via `CleanDirective`. There is no dynamic code to sign, sandbox, or trust at load time, which
collapses a large threat surface (spec 36) for v1. The cost is that adding a third-party
plugin requires a rebuild — acceptable for v1's first-party-only bundle.

### Forward path: dynamic / out-of-process (v2/v3)

Deferred, referenced so v1 doesn't paint us into a corner. The `CleanerPluginAPI` target is
already a standalone product (spec 12 §4) precisely so external plugins can link it.

| Option | Mechanism | Pros | Cons | Target release |
|---|---|---|---|---|
| **Dynamic dylib** | `dlopen` a `.dylib` exporting a `makePlugin()` C-ABI entry; plugin links `CleanerPluginAPI`. | No IPC cost; near-static ergonomics; hot-add without core rebuild. | Shares address space → a crash takes down the host; must code-sign & notarize each dylib; ABI stability burden. | v2 |
| **Out-of-process (XPC)** | Each plugin is a separate helper; engine talks over an XPC `NSXPCConnection` / Mach service with a typed proxy of the SDK. | True fault + privilege isolation (a crashing plugin cannot kill the host — §9); can drop each helper's sandbox entitlements independently. | IPC serialization cost on the streaming path; more moving parts; `Finding` must cross a process boundary (already `Codable`, so feasible). | v3 |

The trade-off axis is **isolation vs. throughput**. v1 buys maximum throughput and a tiny
trust surface by being static; v3's XPC buys maximum isolation at IPC cost. Because plugins
already never call the OS directly (providers are injected) and already only *propose*
(`CleanDirective`), moving to XPC is a transport swap of the `PluginContext`, not a redesign.

## 6. `PluginContext` — the sandbox of injected capability

The context is how a plugin reaches the world *without* reaching the OS. Every provider is a
narrow, `Sendable` protocol from `CleanerPluginAPI`; the concrete adapter (from
`CleanerPlatform`) is chosen by the composition root (spec 11 §9). In tests, fakes are
injected — a plugin never touches a real disk in a unit test (spec 12 §7).

```swift
public struct PluginContext: Sendable {
    // Read-mostly filesystem — enumeration, stat, allocated-size, xattr READ. No delete API.
    public let fs: FileSystemReading
    // Native metadata, all read-only: Spotlight kind/last-used/whereFroms, volume type.
    public let metadata: MetadataReading
    public let volumes: VolumeReading
    public let launchServices: LaunchServicesReading   // "is this app installed/used?"
    // Sandboxed, timeout-bounded shell fallback for tools with no native API (simctl, docker).
    public let process: ProcessRunning                 // arg-escaped, no shell string (spec 36)
    // Structured logging scoped to this plugin's id; feeds the audit trail (spec 28).
    public let log: PluginLogger
    // The plugin's own config sub-tree only — cannot see other plugins' config.
    public let config: ConfigSlice
    // Cooperative cancellation — plugins MUST check at directory boundaries (spec 17).
    public let cancellation: CancellationToken
    // The engine's clock (injected for determinism; recency scoring uses it — principle 5).
    public let clock: ClockReading
    // The plugin's resolved, guarded roots (already ∩ allow-space − deny-list).
    public let allowedRoots: [ResolvedRoot]
}
```

Design guarantees:

- **No mutation capability exists in the context.** `FileSystemReading` has no `remove`,
  `move`, or `unlink`. The only way a byte is deleted is the engine acting on a
  `CleanDirective`. This is enforced by the *type*, not by policy.
- **No direct framework import.** A plugin never writes `import DiskArbitration`; it calls
  `context.volumes.kind(of:)`. This is what makes plugins testable and what lets v3 move them
  out-of-process transparently.
- **Scoped config & logging.** A plugin sees only its own config slice and logs under its own
  id, so one plugin can't read another's secrets or spoof another's audit lines.
- **`allowedRoots` are pre-guarded.** By the time a plugin scans, its roots are already
  intersected with the allow-space and had the deny-list subtracted — so even a buggy glob
  can't wander into `~/.ssh`.

## 7. Capability negotiation

A plugin advertises what it can do via `CapabilitySet` in its manifest; the engine queries
these flags and adapts, rather than assuming every plugin supports everything.

```
 engine wants to …            checks capability      if absent, engine …
 ─────────────────────────────────────────────────────────────────────────
 show a dry-run preview       .dryRun                falls back to a full scan + no-op stage
 give fast pre-scan sizes     .estimate              skips the estimate row (shows "—")
 offer one-command rollback   .rollback              stages anyway (staging is universal) but
                                                     labels recoverability=manual not instant
 enrich the audit record      .audit                 records only the base Evidence
 use the incremental cache    .incremental           does a full scan (correctness over speed)
 request admin-owned paths    .elevation             lazily prompts for authorization (spec 23)
```

Negotiation is **advisory to the plugin, authoritative in the engine**: even if a plugin
claims `.rollback`, staging is always performed by the engine (reversibility is a Constitution
default, principle 2, not a plugin favor). Capability flags let the engine *optimize and label
honestly* (principle 3) — e.g. it won't promise "instant rollback" in the preview for a plugin
that only supports `manual` recoverability.

## 8. Versioning & compatibility

The `CleanerPluginAPI` surface is **semantically versioned**; `PluginManifest.apiVersion`
records the API a plugin was built against.

```
 compatibility check at validate (§5):
   host API = 1.4.0
   plugin built against …
     1.2.0  → OK  (same major, host ≥ plugin minor: additive-only changes)
     1.4.0  → OK
     1.5.0  → REJECT exit 7 "built against newer API 1.5.0; host is 1.4.0"
     2.0.0  → REJECT exit 7 "major mismatch"
```

- **MAJOR** bump = a breaking change to `CleanerPlugin`/`PluginContext`/`Finding`
  (removed/renamed member, changed semantics). Incompatible plugins are rejected, not
  silently degraded.
- **MINOR** bump = additive (a new optional protocol member with a default impl, a new
  `CapabilitySet` flag, a new provider on `PluginContext`). Old plugins keep working because
  new members have defaults and new capabilities are opt-in.
- **PATCH** = doc/impl-only, no surface change.
- **Capability flags are the fine-grained escape valve within a major**: rather than bump
  major to add "supports X", the engine adds a `CapabilitySet` flag; plugins that don't set it
  are handled by the fallback column (§7). This keeps the major version stable for years.

## 9. Error isolation — a bad plugin degrades to a skip

A plugin is untrusted code on the hot path; one misbehaving plugin must never corrupt a run or
the disk. Isolation is layered (v1 in-process → catch; v3 out-of-process → process crash
containment).

```
 scan  ── plugin throws / stream errors ──▶ ScanEngine catches ──▶ drop that plugin's
                                                                    partial Findings for the
                                                                    failed root, emit
                                                                    RunEvent.pluginFailed(id),
                                                                    continue other plugins
                                                                    → terminal exit 7 (plugin)
 clean ── plugin throws in clean(items) ──▶ CleanupEngine catches ─▶ mark those Items skipped,
                                                                    already-staged Items stay
                                                                    staged, continue
                                                                    → terminal exit 3 (partial)
 plugin proposes a bad CleanDirective  ──▶ ProtectedPathGuard REJECTS (path outside roots /
   (e.g. a path it never declared)          protected / symlink escape) ──▶ exit 8 (safety),
                                            action refused, run aborts — this is a contract
                                            violation, not a soft skip (Art. 4.4)
 plugin hangs                          ──▶ per-plugin scan deadline (from ConcurrencyLimiter);
                                            cancellation token fires → plugin's stream ends,
                                            treated as pluginFailed → exit 7
```

Exit-code mapping (Constitution Art. 7): a *failing/crashing* plugin → **7** if it broke at
load/scan/contract level, **3** if it merely couldn't finish cleaning some items. A plugin
that tries to escape its sandbox (protected path, undeclared path) → **8 (safety)**, which is
fatal by design. In v3 (XPC), a plugin *process crash* is caught as a broken connection and
mapped identically to `pluginFailed` → 7, giving true fault isolation.

## 10. How the engine enforces safety on top of plugins

The whole point: **the engine does not trust plugin output.** Every Finding and every
`CleanDirective` re-enters the engine's safety funnel (spec 11 §5, Constitution Art. 4.4/5).

```
 plugin's Finding (proposed risk, proposed score)
        │
        ▼
 ① SafetyScorer  — recomputes SafetyScore from shared signals (spec 22). A plugin may LOWER
                   the score with Evidence; it may NOT raise it above the scorer's ceiling
                   (Art. 4.2). Score → RiskLevel mapping is the engine's, not the plugin's.
        │
        ▼
 ② RuleEngine    — applies user whitelist/blacklist/target rules (spec 18). Whitelisted paths
                   are dropped even if a plugin found them.
        │
        ▼
 ③ ProtectedPathGuard — roots ∩ allow-space − deny-list; refuses symlink escapes, mount roots,
                   `/`, system volumes (Art. 4.4/5). Runs at scan AND again at clean (TOCTOU).
        │
        ▼
 ④ CleanupEngine — ignores the plugin's disposition if it conflicts with policy: default
                   forces .stage; .purge is impossible from a plugin; .trash allowed only for
                   the TrashPlugin category. Stages, measures reclaim (CC-10), audits.
```

So a plugin can be wrong, greedy, or malicious and the worst it achieves is a rejected action
(exit 8) — never an unstaged delete, never a protected-path touch. Plugins are advisory; the
four gates are authoritative.

## 11. Worked example A — minimal `TrashPlugin`

Empties the macOS Trash. Simplest possible plugin: read the trash dir, propose `.trash`
disposition (the one category allowed to bypass staging, since Trash *is* already a recovery
buffer — Art. 3 glossary).

```swift
public struct TrashPlugin: CleanerPlugin {
    public static let manifest = PluginManifest(
        id: "dev.cleaner.trash", name: "Empty Trash", category: .system,
        apiVersion: "1.4.0", pluginVersion: "1.0.0",
        declaredRoots: [RootSpec(base: .home, glob: ".Trash/**")],
        defaultRisk: .safe,                             // 🟢 already-trashed by the user
        capabilities: [.estimate],                      // sizes are cheap; no rollback (Trash IS the buffer)
        requiresElevation: false, trust: .firstParty)

    public var id: PluginID { Self.manifest.id }
    public var category: Category { .system }
    public var version: SemVer { Self.manifest.pluginVersion }
    public var declaredRoots: [RootSpec] { Self.manifest.declaredRoots }
    public var defaultRisk: RiskLevel { .safe }
    public var capabilities: CapabilitySet { Self.manifest.capabilities }

    public func configure(_ slice: ConfigSlice) throws {}

    public func scan(_ ctx: PluginContext) -> AsyncThrowingStream<Finding, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for root in ctx.allowedRoots {
                    for try await entry in ctx.fs.enumerate(root, options: .topLevel) {
                        try ctx.cancellation.check()
                        let size = try await ctx.fs.allocatedSize(of: entry.path)
                        let item = Item(id: .init(path: entry.path), size: size, paths: [entry.path])
                        continuation.yield(Finding(
                            item: item, risk: .safe, score: SafetyScore(value: 95),
                            evidence: [Evidence(kind: .location, detail: "in user Trash")],
                            rationale: "Already moved to Trash by the user."))
                    }
                }
                continuation.finish()
            }
        }
    }

    // Propose Trash disposition; engine still validates the path is really under ~/.Trash.
    public func clean(_ items: [Item], _ ctx: PluginContext) async throws -> [CleanDirective] {
        items.map { CleanDirective(item: $0, proposedDisposition: .trash, rollbackHint: nil) }
    }
}
```

## 12. Worked example B — `XcodePlugin` sketch (complex)

Multiple root types with different risks, Evidence from Launch Services and project detection,
capability-rich, uses the process fallback for `simctl`-adjacent data.

```swift
public struct XcodePlugin: CleanerPlugin {
    public static let manifest = PluginManifest(
        id: "dev.cleaner.xcode", name: "Xcode Junk", category: .developer,
        apiVersion: "1.4.0", pluginVersion: "2.1.0",
        declaredRoots: [
            RootSpec(base: .developer, glob: "Xcode/DerivedData/**"),      // 🟢 rebuildable
            RootSpec(base: .developer, glob: "Xcode/iOS DeviceSupport/**"),// 🟡 re-downloaded per device
            RootSpec(base: .developer, glob: "CoreSimulator/Caches/**"),   // 🟢
            RootSpec(base: .libraryCaches, glob: "com.apple.dt.Xcode/**"), // 🟢
            RootSpec(base: .developer, glob: "Xcode/Archives/**"),         // 🔴 shippable artifacts!
        ],
        defaultRisk: .safe,
        capabilities: [.dryRun, .estimate, .rollback, .audit, .incremental],
        requiresElevation: false, trust: .firstParty)

    // metadata mirrors omitted for brevity …

    public func scan(_ ctx: PluginContext) -> AsyncThrowingStream<Finding, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for root in ctx.allowedRoots {
                    for try await dir in ctx.fs.enumerate(root, options: .directoriesOnly) {
                        try ctx.cancellation.check()

                        // Per-root risk: Archives are DANGEROUS (may be a shippable build).
                        let baseRisk: RiskLevel = root.matches("Archives") ? .dangerous
                                                : root.matches("DeviceSupport") ? .medium : .safe

                        // Evidence: last-used via Spotlight; is the owning project still present?
                        let lastUsed = try? await ctx.metadata.lastUsedDate(of: dir.path)
                        let stale = lastUsed.map { ctx.clock.now.timeIntervalSince($0) > 30*86400 } ?? true
                        var evidence: [Evidence] = [
                            Evidence(kind: .lastUsed, detail: lastUsed?.description ?? "unknown"),
                            Evidence(kind: .regenerability, detail: "rebuilt by `xcodebuild`")]

                        // DerivedData folder name encodes the project hash — check the project still exists.
                        if let proj = derivedDataProject(dir), await !ctx.fs.exists(proj) {
                            evidence.append(Evidence(kind: .orphaned, detail: "source project gone: \(proj)"))
                        }

                        let size = try await ctx.fs.allocatedSize(of: dir.path)
                        let item = Item(id: .init(path: dir.path), size: size, paths: [dir.path])
                        continuation.yield(Finding(
                            item: item,
                            risk: (baseRisk == .safe && stale) ? .safe : baseRisk,   // engine may still lower/keep
                            score: SafetyScore(value: baseRisk == .dangerous ? 30 : (stale ? 90 : 70)),
                            evidence: evidence,
                            rationale: baseRisk == .dangerous
                                ? "Xcode Archive — may be a shipped/notarized build; confirm explicitly."
                                : "Xcode build cache; regenerated on next build."))
                    }
                }
                continuation.finish()
            }
        }
    }

    public func rollbackHint(_ item: Item) -> RollbackHint? {
        RollbackHint(strategy: .restoreFromStaging,
                     note: "DerivedData rebuilds automatically; restore only if a build is mid-flight.")
    }

    public func clean(_ items: [Item], _ ctx: PluginContext) async throws -> [CleanDirective] {
        // Everything to staging (engine default). Archives, if confirmed, still only stage — never purge.
        items.map { CleanDirective(item: $0, proposedDisposition: .stage,
                                   rollbackHint: rollbackHint($0)) }
    }
}
```

Note both examples only *propose*. `XcodePlugin` can flag an Archive as `.dangerous` and a
`SafetyScore` of 30, but it is the engine's `SafetyScorer` (spec 22) that finalizes the score,
the `RuleEngine` that honors any user whitelist of a specific archive, and the
`ProtectedPathGuard` that confirms every path is under `~/Library/Developer` before a single
byte moves.

## 13. Third-party plugin trust model

For v1, only first-party bundled plugins ship (CC-8), so `TrustLevel` is `.firstParty` for
all of them and the compile-time registry is the trust boundary — there is no untrusted code
to load. The full model for third-party plugins (signing, notarization requirement, capability
attestation, the reduced-privilege sandbox for `.unsigned`, and the XPC isolation that makes
untrusted plugins tolerable) is specified in **spec 36 (Threat Model)** and gated to v2/v3
alongside the dynamic-loading forward path (§5). This spec fixes the *hooks* that make that
possible: `PluginManifest.trust`, `CapabilitySet.elevation`, injected-only capability
(`PluginContext`), and propose-only cleaning (`CleanDirective`).

## 14. Open Questions

- **OQ-13.1** Should `scan` return `AsyncThrowingStream<Finding>` (current) or
  `AsyncStream<Result<Finding, Error>>` so a single bad entry doesn't tear down the whole
  stream? Leaning: throwing stream for v1 (simpler), with the engine treating a mid-stream
  throw as "keep the Findings emitted so far, mark plugin partial." Revisit for robustness.
- **OQ-13.2** Do we let a plugin declare *dynamic* roots discovered at scan time (e.g. read
  `~/.docker/config` to find data dirs), or must all roots be static in the manifest? Static
  is safer for the guard; dynamic needs a "propose-root-for-validation" callback. Leaning:
  static manifest roots for v1; a `proposeRoot(_:) throws` validation hook in v2.
- **OQ-13.3** Where does per-plugin *ordering / dependency* live if two plugins overlap (e.g.
  DevCache and Xcode both touch `~/Library/Caches`)? Leaning: the engine de-duplicates Items
  by canonical path after scan; first-Finding-wins with a merged Evidence set. Confirm in
  spec 17/19.
- **OQ-13.4** Should `CapabilitySet` be extensible by third parties (raw flag space) or a
  closed enum owned by the SDK? Leaning: closed for v1 (the engine must understand every
  flag); reserve a `.custom(String)` side-channel in v2.
- **OQ-13.5** Exact deadline/back-pressure policy for a slow plugin `scan` stream — fixed
  per-plugin timeout vs. adaptive from the `ConcurrencyLimiter`. Defer detail to spec 17.

## 15. Dependencies

**Consumes:** 00 (Art. 4.2/4.4 the propose-vs-dispose split, Art. 5 protected paths, Art. 7
exit codes, CC-8 static in-process decision), 10 (native providers wrapped by Platform;
process-fallback sandboxing), 11 (the `PluginContext` boundary and the four-gate safety funnel
originate in the flow there), 12 (`CleanerPluginAPI` is the SDK target; `Plugins`↛`Engine`
edge). **Feeds:** 14 (`Finding`/`Item`/`Disposition`/`RiskLevel`/`SafetyScore`/`Evidence`
formalized), 17 (scan streaming/cancellation/dedup), 18 (RuleEngine gate), 20 (CleanupEngine
executes `CleanDirective`), 21 (rollback from `RollbackHint`), 22 (SafetyScorer ceiling), 23
(elevation capability), 36 (third-party trust, dynamic-load threat surface), and every
`specs/plugins/*` detailed design.
