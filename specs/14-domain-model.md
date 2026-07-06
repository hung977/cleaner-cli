# 14 — Domain Model

> **Phase D · Depends on:** 00-constitution, 10-tech-stack, 13-plugin-architecture ·
> **Depended on by:** 15 (data model), 16 (filesystem), 17 (scan), 18 (rules), 19 (detection),
> 20 (cleanup), 21 (rollback), 22 (safety), 24 (config), 25 (TUI), 28 (logging).

## 1. Purpose & scope

This spec defines the **core domain language** of cleaner-cli as Swift 6 value types. It is the
single source of truth for the entity names, their fields, their relationships, and their
invariants. Every downstream spec MUST use these exact type names. The types shown are
*illustrative sketches* — field lists and invariants are normative; exact property attributes
(access control, `Codable` conformance placement, memberwise-init tweaks) are settled during
implementation. Persistence shapes for these entities live in spec 15; how their metadata is
gathered from the filesystem lives in spec 16.

Design rules inherited from the Constitution:

- **Value semantics.** Domain entities are `struct`/`enum`, `Sendable`, immutable after
  construction where practical. Mutation happens by producing a new value, never by aliasing.
  This makes them safe to pass across `actor` boundaries (CC-3) and trivially snapshot-able.
- **Truth in reporting** (Principle 3, CC-10). Size is always two numbers: logical `size` and
  on-disk `allocatedSize`. Reclaim is computed from `allocatedSize` with clone/hardlink
  correction (see § 6). No entity stores a single ambiguous "size".
- **Reversibility** (Principle 2). `Disposition` defaults to `.stage` for **every** actioned item,
  so cleaning is reversible via `cleaner undo` regardless of an item's content-level
  `Recoverability`.
- **User-driven selection** (spec 22). What gets cleaned is chosen by the user (`clean all` /
  `select each` / `--yes`), **not** by a risk tier. `RiskLevel`/`SafetyScore` are retained as
  vestigial internal metadata (§ 4.2/§ 4.3) and no longer govern selection, gating, or display.

## 2. Ubiquitous language (domain terms → types)

Extends Constitution Article 3. Where Article 3 and this table overlap, Article 3 wins on
*meaning* and this table binds the meaning to a *type*.

| Term | Type | One-line meaning |
|---|---|---|
| Item | `Item` | The atomic thing acted on: a file, directory, or logical group of paths. |
| Finding | `Finding` | An `Item` + a plugin's assessment (recoverability, rationale, reclaim). |
| Risk level | `RiskLevel` | *Vestigial internal metadata* (safe/medium/dangerous); not surfaced or used for selection. |
| Safety score | `SafetyScore` | *Vestigial internal metadata* (0–100); not surfaced or used for selection. |
| Recoverability | `Recoverability` | instant / manual / hard / none (descriptive; staging makes every item recoverable). |
| Disposition | `Disposition` | What to do with an Item: stage / trash / purge / skip. |
| Evidence | `Evidence` | The metadata bag justifying a Finding. |
| Category | `Category` | The bucket a Finding belongs to (developer-cache, browser-cache, …). |
| Plugin (metadata) | `PluginDescriptor` | Static identity + capability declaration of a plugin. |
| Scan result | `ScanResult` | The complete output of one read-only scan pass. |
| Clean plan | `CleanPlan` | The confirmed, ordered set of dispositions to execute. |
| Clean report | `CleanReport` | What actually happened after executing a plan. |
| Session | `Session` | One process invocation, with UUID, logs, and a report. |
| Profile | `Profile` | A named saved set of plugin selections + options. |
| Reclaim | `ReclaimEstimate` / `ReclaimActual` | Estimated vs realized on-disk space freed. |

## 3. Entity relationship diagram

```
                          ┌──────────────┐
                          │   Session    │  UUID, startedAt, host env
                          │              │  profile?, config snapshot
                          └──────┬───────┘
                                 │ 1
              ┌──────────────────┼───────────────────┐
              │ 1                │ 0..1               │ 0..1
              ▼                  ▼                    ▼
        ┌───────────┐      ┌───────────┐        ┌────────────┐
        │ScanResult │      │ CleanPlan │        │ CleanReport│
        └─────┬─────┘      └─────┬─────┘        └──────┬─────┘
              │ *                │ *                   │ *
              ▼                  ▼                     ▼
        ┌───────────┐      ┌────────────┐       ┌──────────────┐
        │  Finding  │◄─────│PlannedAction│──────►│ ActionOutcome│
        └─────┬─────┘  ref └─────┬──────┘  ref   └──────────────┘
              │ 1               │ carries Disposition
        ┌─────┴─────┐
        │           │
        ▼           ▼
   ┌────────┐  ┌──────────┐
   │  Item  │  │ Evidence │
   └───┬────┘  └──────────┘
       │ produced by
       ▼
 ┌──────────────┐        Finding also carries:
 │PluginDescriptor│        Recoverability, Category, rationale,
 └──────────────┘        reclaim (+ vestigial RiskLevel/SafetyScore)

 Profile ──selects──► [PluginID] + options   (persisted, spec 15)
```

Cardinality summary:

- A `Session` has exactly one `ScanResult`, at most one `CleanPlan`, at most one `CleanReport`
  (a pure `scan` session has no plan/report; a `clean` session has all three).
- A `ScanResult` has 0..N `Finding`s.
- A `Finding` has exactly one `Item` and one `Evidence` bag, and references one
  `PluginDescriptor` (by `PluginID`).
- A `CleanPlan` has 0..N `PlannedAction`s, each referencing exactly one `Finding` (by
  `FindingID`) and carrying one `Disposition`.
- A `CleanReport` has 0..N `ActionOutcome`s, each referencing one `PlannedAction`.

## 4. Core value types

### 4.1 Identifiers

```swift
/// Stable, content-derived where possible; otherwise UUID. Sendable value wrappers.
struct FindingID: Hashable, Sendable, Codable { let raw: String }   // e.g. "xcode-derived:<hash>"
struct ItemID:    Hashable, Sendable, Codable { let raw: String }
struct PluginID:  Hashable, Sendable, Codable { let raw: String }   // reverse-DNS, e.g. "dev.cleaner.xcode"
struct SessionID: Hashable, Sendable, Codable { let uuid: UUID }
struct CategoryID: Hashable, Sendable, Codable { let raw: String }  // e.g. "developer-cache"
```

`FindingID` MUST be **deterministic** for the same logical item across scans (Principle 5,
idempotence): it is derived from `PluginID` + a canonicalized primary path (+ discriminator for
grouped items), *not* from a random UUID. This lets incremental scans (spec 17) and rollback
(spec 21) correlate findings across runs.

### 4.2 `RiskLevel` — vestigial internal metadata

> **As-built (v0.6):** `RiskLevel` is **retained in the code but removed from the product**. There
> are no user-facing Safe/Medium/Dangerous tiers, no 🟢/🟡/🔴 icons in the renderer, no risk-based
> default selection, and no "dangerous is never auto-cleaned" behavior. A `Finding` still carries a
> `risk` and a plugin may attach one, but it does **not** drive selection, ordering, confirmation,
> disposition, gating, or display. Selection is user-driven and the only hard gate is the
> `ProtectedPathGuard` (spec 22 § 6). The type is kept to avoid a wide breaking change to
> `Finding`, JSON schemas, and plugin signatures.

```swift
enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case safe        // regenerated automatically; no user data
    case medium      // regenerated but costs time (re-download, re-index, re-build)
    case dangerous   // could contain irreplaceable data or break tools if wrong
    // Comparable: safe < medium < dangerous (ascending). Internal only in v0.6.
}
```

### 4.3 `SafetyScore` — vestigial internal metadata

> **As-built (v0.6):** like `RiskLevel`, `SafetyScore` is inert product-wise. The old weighted
> `SafetyScorer` (spec 22) still compiles but is **not invoked** by the scan/clean flow, and the
> score→risk mapping below no longer gates anything. The score is not surfaced as a safety
> affordance.

```swift
/// 0…100. Immutable, validated at init. Internal metadata only in v0.6.
struct SafetyScore: Hashable, Sendable, Codable, Comparable {
    let value: Int   // INVARIANT: 0...100

    init(_ v: Int) { precondition((0...100).contains(v)); value = v }

    /// Retained mapping (no longer authoritative — spec 22 § 10).
    var riskLevel: RiskLevel {
        switch value {
        case 85...100: .safe
        case 50...84:  .medium
        default:       .dangerous   // 0...49
        }
    }
}
```

### 4.4 `Recoverability`

```swift
enum Recoverability: String, Codable, Sendable, CaseIterable {
    case instant   // staged; one-command `cleaner undo`
    case manual    // re-downloadable / re-buildable by the user
    case hard      // external source needed (e.g. re-clone a repo)
    case none      // no external source to restore the content from
}
```

Descriptive metadata for the rationale/reports. Because the default `Disposition` is `.stage`
(§ 4.5), **every actioned item is recoverable via `cleaner undo`** until its staging session is
purged — regardless of this content-level class. (Historically `.none` forced `RiskLevel.dangerous`;
with risk tiers removed in v0.6 it no longer changes whether or how an item is cleaned.)

### 4.5 `Disposition`

```swift
enum Disposition: String, Codable, Sendable, CaseIterable {
    case stage   // DEFAULT — move to tool-managed staging (reversible). Principle 2.
    case trash   // move to macOS Trash via FileManager.trashItem / NSWorkspace.recycle
    case purge   // permanent deletion — the ONLY irreversible disposition
    case skip    // do nothing (kept for audit/report completeness)
}
```

`.stage` is the **universal default** for every actioned item. `.purge` is only reachable via
explicit escalation (`--no-stage` + confirmation, or purging already-staged items); never a
scan/plan default (Constitution Article 4.4). Note: cleaning the macOS Trash also uses `.stage`
(not `.purge`) — the Trash plugin moves items into staging so "empty Trash" is itself reversible
via `cleaner undo`; the tool never empties the Trash irreversibly on the user's behalf.

### 4.6 `Category`

```swift
struct Category: Hashable, Sendable, Codable, Identifiable {
    let id: CategoryID            // "developer-cache", "browser-cache", "logs", "duplicates", …
    let displayName: String      // "Developer Caches"
    let parent: CategoryID?      // shallow hierarchy for grouping (spec 25)
    let defaultRisk: RiskLevel   // vestigial baseline (§ 4.2); not surfaced or acted on
}
```

Categories are a *taxonomy for presentation and bulk selection*, not a safety authority. In v0.6
safety rests on user consent, staging-by-default, and the `ProtectedPathGuard` (spec 22); neither a
category label nor the vestigial per-`Finding` `RiskLevel`/`SafetyScore` authorizes an action.

### 4.7 `Evidence`

The metadata bag a plugin gathered (Article 3). Populated from the filesystem layer (spec 16).
Every field is optional because acquisition can be gated by permissions or API availability; a
`nil` field means "not gathered / not applicable", never "zero".

```swift
struct Evidence: Sendable, Codable, Hashable {
    // Timestamps (nil if unreadable)
    var mtime: Date?                 // content modification
    var atime: Date?                 // last access (note: relatime; treat as lower-bound)
    var ctime: Date?                 // inode change
    var birthtime: Date?             // creation (APFS)

    // Size — ALWAYS both numbers (Principle 3, CC-10)
    var size: Int64?                 // logical byte length (st_size)
    var allocatedSize: Int64?        // actual on-disk allocation (blocks), APFS-aware

    // Spotlight / Launch Services (CoreServices, spec 16)
    var spotlightKind: String?       // kMDItemKind, e.g. "Disk Image"
    var lastUsedDate: Date?          // kMDItemLastUsedDate (stronger than atime)
    var whereFroms: [String]?        // com.apple.metadata:kMDItemWhereFroms (download origin)
    var launchServicesInfo: LaunchServicesInfo?

    // Extended attributes
    var xattrs: [String: Data]?      // raw xattr map (bounded; large values elided — spec 16)
    var quarantine: QuarantineInfo?  // com.apple.quarantine parsed
    var finderTags: [String]?        // com.apple.metadata:_kMDItemUserTags

    // Filesystem shape flags (drive reclaim correctness — § 6, spec 16)
    var isSymlink: Bool?
    var isHardlink: Bool?            // st_nlink > 1
    var hardlinkCount: Int?          // st_nlink
    var isSparse: Bool?              // allocatedSize < size
    var isClone: Bool?              // shares blocks via APFS clonefile
    var isDataless: Bool?            // iCloud/placeholder — MUST NOT trigger download (spec 16)
    var snapshotRef: SnapshotRef?    // if the path is within a local TM snapshot mount

    // Ownership / access (for restore fidelity — spec 15)
    var ownerUID: uid_t?
    var ownerGID: gid_t?
    var posixPermissions: UInt16?
    var isWritableByUser: Bool?
    var isOpenOrLocked: Bool?        // in-use detection (Article 4.4)
}

struct LaunchServicesInfo: Sendable, Codable, Hashable {
    var bundleID: String?
    var isRegisteredApp: Bool?
    var appIsInstalled: Bool?        // owning app still present?
    var lastUsedByApp: Date?
}

struct QuarantineInfo: Sendable, Codable, Hashable {
    var agentName: String?           // e.g. "Safari"
    var timestamp: Date?
    var originURL: String?
}

/// Reference to a local Time Machine / APFS snapshot. Read-only, NEVER deleted (Article 5).
struct SnapshotRef: Sendable, Codable, Hashable {
    var snapshotName: String         // e.g. "com.apple.TimeMachine.2026-07-06-…"
    var mountPoint: String?
}
```

### 4.8 `Item`

```swift
/// The atomic unit a plugin reports and the engine acts on.
struct Item: Sendable, Codable, Hashable, Identifiable {
    let id: ItemID
    /// Canonicalized, symlink-resolved (spec 16 § path safety). The one path used for FindingID.
    let primaryPath: FilePath
    /// For grouped items (e.g. "DerivedData for project X" spanning many files).
    let paths: [FilePath]            // INVARIANT: non-empty; contains primaryPath
    let kind: ItemKind
    /// Truthful size pair — see § 6. Both are sums over `paths` with clone/hardlink correction.
    let size: Int64                  // logical sum
    let allocatedSize: Int64         // on-disk sum, clone/hardlink-corrected
    let volumeID: VolumeID           // which volume these paths live on (spec 16, DiskArbitration)
}

enum ItemKind: String, Codable, Sendable {
    case file, directory, group      // `group` = logical bundle spanning multiple paths
}
```

Invariants: `paths` is non-empty and contains `primaryPath`; all `paths` reside on one
`volumeID` (a group spanning volumes is split into per-volume Items by the scan engine, spec 17).

### 4.9 `Finding`

```swift
/// An Item plus a plugin's assessment — the unit the user previews and selects.
struct Finding: Sendable, Codable, Hashable, Identifiable {
    let id: FindingID                // deterministic (§ 4.1)
    let item: Item
    let producedBy: PluginID
    let category: CategoryID

    let recoverability: Recoverability
    let rationale: String            // human-readable "why this is junk" (shown in preview)
    let evidence: Evidence

    /// Estimated reclaim if this finding is cleaned (Principle 3 — from allocatedSize).
    let reclaim: ReclaimEstimate

    /// Suggested disposition (usually .stage). The user/plan may change it.
    let suggestedDisposition: Disposition
    /// Set by engine, not plugin: is this path allowed (allowedRoots − denyList)? (Article 5)
    let isProtected: Bool

    // ── Vestigial internal metadata (§ 4.2/§ 4.3) — NOT surfaced, NOT used for selection. ──
    let risk: RiskLevel              // inert; a plugin may attach a tightened value
    let safetyScore: SafetyScore     // inert
}
```

Invariants (engine-enforced):

1. `isProtected == true` ⇒ the Finding is **display-only**; no `PlannedAction` may target it
   (the `ProtectedPathGuard`, spec 22 § 6, is the sole hard gate). Enforced by the cleanup engine.
2. `suggestedDisposition == .purge` is rejected at plan time unless explicit escalation
   (`--no-stage` + consent, or purging already-staged items).
3. `risk`/`safetyScore` are **not** consulted for selection, ordering, or gating in v0.6 — they are
   vestigial. Selection is user-driven (spec 22 § 4). (The historical "`recoverability == .none` ⇒
   `risk == .dangerous`" and "risk matches `safetyScore.riskLevel`" invariants are dropped with the
   risk tiers.)

### 4.10 `ReclaimEstimate` / `ReclaimActual`

```swift
/// Truthful reclaim accounting (CC-10, § 6). Estimate is pre-clean; Actual is measured post-clean.
struct ReclaimEstimate: Sendable, Codable, Hashable {
    let logicalBytes: Int64          // naive st_size sum — for display context only
    let onDiskBytes: Int64           // allocatedSize sum, clone/hardlink corrected — the headline
    let sharedBytesExcluded: Int64   // blocks NOT counted because shared (clones/hardlinks)
    let confidence: ReclaimConfidence
}

struct ReclaimActual: Sendable, Codable, Hashable {
    let onDiskBytesFreed: Int64      // measured delta (statfs before/after or per-item accounting)
    let logicalBytesRemoved: Int64
}

enum ReclaimConfidence: String, Codable, Sendable { case exact, estimated, unknown }
```

### 4.11 `PluginDescriptor`

Static plugin metadata (full contract in spec 13). Domain-level shape only:

```swift
struct PluginDescriptor: Sendable, Codable, Hashable, Identifiable {
    let id: PluginID                 // reverse-DNS, e.g. "dev.cleaner.xcode"
    let displayName: String
    let version: SemanticVersion
    let categories: [CategoryID]     // categories this plugin can produce
    let declaredRoots: [FilePath]    // roots it scans (engine intersects w/ allow-space, Article 5)
    let capabilities: PluginCapabilities
    let defaultRisk: RiskLevel
    let requiresFullDiskAccess: Bool
    let usesShellOut: Bool           // true ⇒ must be a justified fallback adapter (spec 13)
}

struct PluginCapabilities: OptionSet, Sendable, Codable {
    let rawValue: Int
    static let scan       = PluginCapabilities(rawValue: 1 << 0)
    static let clean      = PluginCapabilities(rawValue: 1 << 1)
    static let sizeOnly   = PluginCapabilities(rawValue: 1 << 2)  // reports size, can't clean
    static let incremental = PluginCapabilities(rawValue: 1 << 3) // supports incremental scan cache
}

struct SemanticVersion: Sendable, Codable, Hashable, Comparable {
    let major, minor, patch: Int
}
```

### 4.12 `ScanResult`

```swift
struct ScanResult: Sendable, Codable {
    let sessionID: SessionID
    let startedAt: Date
    let finishedAt: Date
    let findings: [Finding]
    let byCategory: [CategoryID: [FindingID]]   // index for TUI grouping
    let totals: ScanTotals
    let skipped: [SkippedPath]                  // Principle 3 — report what we could NOT scan
    let pluginRuns: [PluginRunSummary]          // per-plugin timing, counts, errors
    let cacheStats: ScanCacheStats?             // incremental scan hit/miss (spec 15/17)
    let wasCancelled: Bool
}

struct ScanTotals: Sendable, Codable, Hashable {
    let findingCount: Int
    let reclaimable: ReclaimEstimate            // aggregate, de-duplicated for shared blocks
    let byCategory: [CategoryID: Int]           // counts per source/category (shown to the user)
    // NOTE: no per-risk-tier breakdown is surfaced in v0.6 (risk tiers removed, § 4.2).
}

struct SkippedPath: Sendable, Codable, Hashable {
    let path: FilePath
    let reason: SkipReason                       // permissionDenied, protected, dataless, ioError, …
}

enum SkipReason: String, Codable, Sendable {
    case permissionDenied, protectedPath, dataless, snapshot, ioError, cycle, tooDeep, cancelled
}

struct PluginRunSummary: Sendable, Codable, Hashable {
    let plugin: PluginID
    let duration: Duration
    let findingCount: Int
    let error: String?                           // non-fatal plugin error text (exit code 3/7 upstream)
}
```

### 4.13 `CleanPlan`

```swift
/// The confirmed, ordered set of actions. Produced from a ScanResult + user selection.
struct CleanPlan: Sendable, Codable {
    let id: UUID
    let sessionID: SessionID
    let createdAt: Date
    let actions: [PlannedAction]                 // ordered (safe→risky, spec 20)
    let projectedReclaim: ReclaimEstimate        // sum, shared-block-corrected
    let requiresConfirmation: Bool               // true if any dangerous / any purge
    let policyRef: PolicyRef?                    // signed automation policy that authorized this (spec 23)
}

struct PlannedAction: Sendable, Codable, Hashable, Identifiable {
    let id: UUID
    let finding: FindingID                        // reference into the ScanResult
    let disposition: Disposition                  // stage / trash / purge / skip
    let confirmed: ConfirmationState              // how consent was obtained
}

enum ConfirmationState: String, Codable, Sendable {
    case preselected            // bulk "clean all" (interactive `Y` or `--yes`)
    case explicitInteractive    // user selected this source via `select each` (`s` → `y`)
    case typedConfirmation      // escalated confirmation (e.g. --no-stage purge)
    case automationPolicy       // authorized by a signed policy (spec 23)
}
```

Consent is **user-driven** (spec 22 § 4): after the preview the flow asks
`Clean all X? [Y = all · s = select each · n = cancel]`, `--yes` grants blanket consent, and
`--dry-run` acts on nothing. Every `PlannedAction` records how consent was obtained in `confirmed`;
the cleanup engine refuses to execute an action with unrecorded consent (spec 20). A
`disposition == .purge` still requires explicit escalation (`--no-stage` + consent, spec 22 § 5.3),
never a default.

### 4.14 `CleanReport`

```swift
/// What actually happened. Same measurement code as the estimate (Principle 3).
struct CleanReport: Sendable, Codable {
    let schemaVersion: Int                        // versioned; see spec 15
    let sessionID: SessionID
    let plan: UUID                                // the CleanPlan executed
    let startedAt: Date
    let finishedAt: Date
    let outcomes: [ActionOutcome]
    let realizedReclaim: ReclaimActual            // MEASURED, not projected
    let projectedReclaim: ReclaimEstimate         // for truthful estimate-vs-actual delta
    let stagingSessionPath: FilePath?             // where staged items now live (spec 21)
    let exitCode: Int                             // Constitution Article 7
}

struct ActionOutcome: Sendable, Codable, Hashable {
    let action: UUID                              // PlannedAction.id
    let finding: FindingID
    let result: ActionResult
    let disposition: Disposition
    let reclaimed: ReclaimActual?                 // per-item measured (nil if skipped/failed)
    let stagedAs: StagedRef?                      // manifest handle for rollback (spec 15/21)
    let error: String?
}

enum ActionResult: String, Codable, Sendable {
    case staged, trashed, purged, skipped, failed, blockedBySafety   // blockedBySafety → exit 8
}

/// Handle into the staging manifest (spec 15) that lets rollback restore the item.
struct StagedRef: Sendable, Codable, Hashable {
    let manifestEntryID: UUID
    let stagedPath: FilePath
}
```

### 4.15 `Session`

```swift
/// One invocation of the tool, process-start to exit. Owns UUID, logs, report.
struct Session: Sendable, Codable {
    let id: SessionID
    let startedAt: Date
    let command: String                           // "scan", "clean", "rollback", …
    let argv: [String]                            // sanitized (no secrets) for audit
    let profile: ProfileID?                       // profile in effect, if any
    let configSnapshot: ConfigDigest              // hash/summary of resolved config (spec 24)
    let osVersion: String
    let toolVersion: SemanticVersion
    let scan: ScanResult?
    let plan: CleanPlan?
    let report: CleanReport?
    let finishedAt: Date?
    let exitCode: Int?
}

struct ConfigDigest: Sendable, Codable, Hashable {
    let sha256: String
    let sourcePath: FilePath?
}
```

### 4.16 `Profile`

```swift
struct ProfileID: Hashable, Sendable, Codable { let raw: String }  // e.g. "developer-daily"

/// A named saved set of plugin selections + options. Persisted under ~/.cleaner/profiles (spec 15).
struct Profile: Sendable, Codable, Hashable, Identifiable {
    var id: ProfileID
    var displayName: String
    var enabledPlugins: Set<PluginID>
    var defaultDisposition: Disposition           // usually .stage
    var pluginOptions: [PluginID: PluginOptionMap] // opaque per-plugin option bags
    var extraTargets: [FilePath]                   // user blacklist/target rules (Article 3)
    var extraProtected: [FilePath]                 // user additions to the whitelist
    var createdAt: Date
    var updatedAt: Date
}

/// Opaque, YAML/JSON-round-trippable option bag owned by each plugin (validated by the plugin).
struct PluginOptionMap: Sendable, Codable, Hashable {
    var values: [String: OptionValue]
}
enum OptionValue: Sendable, Codable, Hashable {
    case bool(Bool), int(Int), string(String), list([String])
}
```

Note: `FilePath` is `System.FilePath` (CC / spec 10) for allocation-light, canonicalizable paths.
`VolumeID`, `PolicyRef`, `ScanCacheStats`, and `PolicyRef` are defined in specs 16, 23, and 15
respectively and referenced here by name.

## 5. Invariants (normative) & where enforced

| # | Invariant | Enforced in |
|---|---|---|
| DM-1 | *(Retired — risk tiers removed.)* `Recoverability`/`RiskLevel`/`SafetyScore` are vestigial and gate nothing (§ 4.2/§ 4.3, spec 22 § 10). | n/a |
| DM-2 | *(Retired — risk tiers removed.)* No scorer ceiling gates cleaning; the `SafetyScorer` is not invoked. | n/a |
| DM-3 | *(Retired — risk tiers removed.)* `Finding.risk` is inert metadata, not consistency-checked against a score. | n/a |
| DM-4 | Protected findings (`isProtected`) produce no `PlannedAction`; the `ProtectedPathGuard` is the sole hard gate. | Cleanup engine / guard (20, spec 22 § 6) |
| DM-5 | `.purge` action ⇒ `confirmed ∈ {typedConfirmation, automationPolicy}` via explicit escalation; never a default. | Cleanup engine (spec 20) |
| DM-6 | All `Item.paths` on one `VolumeID`; cross-volume groups are split. | Scan engine (spec 17) |
| DM-7 | `FindingID` deterministic for the same logical item across scans. | Detection (spec 19) |
| DM-8 | Reclaim is computed from `allocatedSize` with shared-block exclusion, never raw `size`. | § 6, spec 16/20 |
| DM-9 | Dry-run and real-run reclaim use the identical measurement code path. | Spec 20/30 |
| DM-10 | Domain types are `Sendable` value types; no reference-type aliasing across actors. | Compiler (Swift 6 strict concurrency) |

## 6. Size vs. allocatedSize — truthful reclaim (Constitution CC-10)

The tool reports **two** sizes for every Item and derives reclaim from the on-disk one:

- **`size` (logical).** `st_size` / `URLResourceValues.fileSize` — the byte length of the
  content. Useful context, but *lies* about space actually occupied on APFS: a sparse file
  reports a large logical size but occupies few blocks; a cloned file reports its full size but
  shares blocks with its origin, so deleting it frees little or nothing.

- **`allocatedSize` (on-disk).** `URLResourceValues.totalFileAllocatedSize` (recursive,
  directories) / `fileAllocatedSize` (single file) — the actual block allocation. This is the
  headline number for reclaim (CC-10, spec 16 § 3).

**Shared-block correction.** Two mechanisms cause block sharing; both are corrected so we never
overstate savings (Principle 3):

1. **APFS clones** (`Evidence.isClone`). Files created via `clonefile(2)` share extents until
   copy-on-write. If both a finding and a retained file reference the same extents, deleting the
   finding frees *only its unshared* blocks. The scan engine tracks extent/inode identity within
   a volume and records shared bytes in `ReclaimEstimate.sharedBytesExcluded`.

2. **Hardlinks** (`Evidence.isHardlink`, `hardlinkCount`). A file with `st_nlink > 1` still
   occupies its blocks until the *last* link is removed. Reclaim only credits the blocks if the
   plan removes all links within the allowed roots; otherwise the bytes are excluded.

**Aggregation rule.** `ScanTotals.reclaimable` and `CleanPlan.projectedReclaim` de-duplicate
shared extents across findings so summing findings never double-counts. `ReclaimActual` in the
report is the **measured** delta (per-item accounting cross-checked against volume `statfs`
before/after, spec 20), and `CleanReport` surfaces the estimate-vs-actual gap so the user sees
the truth if an estimate was off.

**Sparse & dataless.** Sparse files (`isSparse`) contribute their *allocated* blocks only.
Dataless/iCloud placeholders (`isDataless`) contribute **0** reclaim and are never actioned in a
way that would materialize them (spec 16 forbids triggering downloads). Local snapshots
(`snapshotRef`) are reported for context but contribute 0 reclaim and are never deleted
(Article 5).

## 7. Value-semantics & lifecycle notes

- Entities flow **forward and immutable**: `Finding` (from scan) → referenced by
  `PlannedAction` (in plan) → referenced by `ActionOutcome` (in report). Later stages reference
  earlier IDs rather than mutating earlier structs, so a `Session` is an append-only record.
- Cross-`actor` transfer relies on `Sendable`. The mutable accumulators (`ScanAccumulator`,
  `StagingManager`) are actors (spec 10 § 5) that *produce* these immutable values.
- `Codable` conformance is what spec 15 serializes to disk. The domain types here are the
  in-memory truth; spec 15 defines their on-disk envelopes, `schemaVersion`, and migration.

## Open Questions

- **OQ-14.1** Should `FindingID` derivation include a content hash for file-type findings (more
  stable across renames) or stay path-based (cheaper, deterministic)? *Leaning: path-based
  primary, optional content-hash discriminator for duplicate-detection findings only.*
- **OQ-14.2** Do grouped `Item`s need a nested child breakdown (per-path sizes) in the domain
  model, or is that a presentation concern the TUI derives on demand from `paths`? *Leaning:
  presentation concern; keep domain lean.*
- **OQ-14.3** Should `SafetyScore` be an `Int` or a fixed-point/`Double` to allow finer scorer
  weighting? *Leaning: `Int` 0–100 per Article 4.2; scorer can compute in `Double` internally.*
- **OQ-14.4** Is `atime` worth storing given `relatime`/noatime mounts make it unreliable, or
  should we rely solely on `kMDItemLastUsedDate`? *Leaning: store both, treat `atime` as a
  lower-bound hint only.*
- **OQ-14.5** Where does the estimate-vs-actual tolerance threshold (when to warn the user of a
  large gap) live — here as a constant or in the safety model (spec 22)? *Leaning: spec 22.*

## Dependencies

**Consumes:** 00-constitution (Articles 3–5 glossary, safety constants, protected paths),
10-tech-stack (Swift 6 value types, `System.FilePath`, `Codable`), 13-plugin-architecture
(`PluginDescriptor` full contract).

**Feeds:** 15-data-model (persisted envelopes & schemaVersion for these types),
16-filesystem-strategy (populates `Evidence`, `Item` sizes, `VolumeID`), 17-scan-engine
(produces `ScanResult`/`Finding`, enforces DM-2/6/7), 18-rule-engine (`isProtected`, targets),
19-detection-algorithms (`FindingID` derivation), 20-cleanup-engine (executes `CleanPlan`,
enforces DM-4/5/8/9), 21-rollback-design (`StagedRef`, staging, `undo`), 22-safety-model
(the three guarantees; `RiskLevel`/`SafetyScore` retained as vestigial metadata), 24-config
(`Profile`, `ConfigDigest`), 25-tui (`Category` grouping; no risk colouring), 28-logging
(audit of `ActionOutcome`).
