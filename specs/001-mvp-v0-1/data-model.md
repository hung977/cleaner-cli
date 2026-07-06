# Phase 1 Data Model: MVP v0.1

**Feature**: `001-mvp-v0-1` | **Date**: 2026-07-06

The concrete Swift 6 value types needed for v0.1 — a **subset** of `specs/14-domain-model.md`.
Type, field, and enum names match spec 14 **exactly** (this is the single source of truth;
downstream code MUST use these names). All domain types are `Sendable` value types
(`struct`/`enum`), immutable after construction, `Codable` for JSON/NDJSON serialization.
`FilePath` is `System.FilePath`. Fields not required by the v0.1 stories are omitted here and
added in v0.5 (marked *(v0.5+)* where a spec-14 field is intentionally deferred).

Ownership: types live in `CleanerCore` unless noted (staging/engine types live in
`CleanerEngine`, plugin metadata in `CleanerPluginAPI`).

---

## 1. Identifiers (`CleanerCore/Ids.swift`)

```swift
struct FindingID:  Hashable, Sendable, Codable { let raw: String }   // deterministic (DM-7)
struct ItemID:     Hashable, Sendable, Codable { let raw: String }
struct PluginID:   Hashable, Sendable, Codable { let raw: String }   // reverse-DNS
struct SessionID:  Hashable, Sendable, Codable { let uuid: UUID }
struct CategoryID: Hashable, Sendable, Codable { let raw: String }
```

**Invariants**: `FindingID` is derived from `PluginID` + canonicalized primary path (never a
random UUID) so it is stable across scans (DM-7, idempotence). v0.1 plugin IDs: `dev.cleaner.trash`,
`dev.cleaner.xcode`, `dev.cleaner.npm`.

---

## 2. Safety enums (`CleanerCore`)

```swift
enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case safe        // 🟢
    case medium      // 🟡
    case dangerous   // 🔴
    var icon: String { switch self { case .safe: "🟢"; case .medium: "🟡"; case .dangerous: "🔴" } }
    // Comparable: safe < medium < dangerous
}

struct SafetyScore: Hashable, Sendable, Codable, Comparable {
    let value: Int                      // INVARIANT: 0...100 (precondition at init)
    var riskLevel: RiskLevel {          // ≥85 safe / 50–84 medium / <50 dangerous
        switch value { case 85...100: .safe; case 50...84: .medium; default: .dangerous }
    }
}

enum Recoverability: String, Codable, Sendable, CaseIterable {
    case instant   // staged; one-command rollback
    case manual    // re-downloadable / re-buildable
    case hard      // external source needed
    case none      // irreversible — FORCES RiskLevel.dangerous (DM-1)
}

enum Disposition: String, Codable, Sendable, CaseIterable {
    case stage     // DEFAULT — reversible
    case trash     // macOS Trash (v0.1: not a headline path; NpmCache/DerivedData use .stage)
    case purge     // permanent — only irreversible disposition (Trash plugin uses this)
    case skip
}
```

**Invariants**: `SafetyScore.value` ∈ 0…100; risk mapping is fixed here and shared by all specs.
`Recoverability.none ⇒ RiskLevel.dangerous` (DM-1). `.purge` is only reachable via explicit
escalation or purging already-staged items (Article 4.4).

---

## 3. `Category` (`CleanerCore/Category.swift`)

```swift
struct Category: Hashable, Sendable, Codable, Identifiable {
    let id: CategoryID          // v0.1: "developer-cache", "trash"
    let displayName: String
    let parent: CategoryID?
    let defaultRisk: RiskLevel
}
```

v0.1 categories: `developer-cache` (DerivedData + npm cache), `trash`.

---

## 4. `Evidence` — v0.1 subset (`CleanerCore/Evidence.swift`)

Only the fields the three plugins + reclaim accounting + safety gates need. Every field is
optional (`nil` = "not gathered / not applicable", never "zero").

```swift
struct Evidence: Sendable, Codable, Hashable {
    var mtime: Date?                 // content modification (recency signal)
    var size: Int64?                 // logical byte length (context only)
    var allocatedSize: Int64?        // on-disk allocation — reclaim authority (CC-10)
    var isSymlink: Bool?             // never followed out of a root; guard input
    var isClone: Bool?               // APFS clone — shared-block correction
    var isSparse: Bool?              // allocatedSize < size
    var isHardlink: Bool?            // st_nlink > 1 — shared-block correction
    var hardlinkCount: Int?          // st_nlink
    var isDataless: Bool?            // iCloud placeholder — 0 reclaim, never materialize
    var isOpenOrLocked: Bool?        // in-use → .inUse gate

    // Deferred to v0.5 (present in spec 14, omitted in v0.1):
    // atime, ctime, birthtime, spotlightKind, lastUsedDate, whereFroms, launchServicesInfo,
    // xattrs, quarantine, finderTags, snapshotRef, ownerUID/GID, posixPermissions, isWritableByUser
}
```

> Note: the **restore** path (StagingManifestEntry, §11) *does* capture ownership/mode/xattrs/
> flags/timestamps at stage-time even though `Evidence` omits them — those live on the manifest
> entry, not on the scan-time `Evidence`.

---

## 5. `Item` (`CleanerCore/Item.swift`)

```swift
struct Item: Sendable, Codable, Hashable, Identifiable {
    let id: ItemID
    let primaryPath: FilePath        // canonicalized, symlink-resolved
    let paths: [FilePath]            // INVARIANT: non-empty; contains primaryPath
    let kind: ItemKind
    let size: Int64                  // logical sum over paths
    let allocatedSize: Int64         // on-disk sum, clone/hardlink-corrected
    let volumeID: VolumeID           // all paths on one volume (DM-6)
}

enum ItemKind: String, Codable, Sendable { case file, directory, group }
```

**Invariants**: `paths` non-empty and contains `primaryPath` (DM-6); all paths on one `volumeID`
(cross-volume groups split by the scan engine). `VolumeID` is defined in `CleanerPlatform`
(DiskArbitration UUID wrapper) and referenced by name.

---

## 6. `Finding` (`CleanerCore/Finding.swift`)

```swift
struct Finding: Sendable, Codable, Hashable, Identifiable {
    let id: FindingID                // deterministic
    let item: Item
    let producedBy: PluginID
    let category: CategoryID
    let risk: RiskLevel              // == safetyScore.riskLevel unless stricter with evidence
    let safetyScore: SafetyScore
    let recoverability: Recoverability
    let rationale: String            // "why this is junk" — shown in preview
    let evidence: Evidence
    let reclaim: ReclaimEstimate     // from allocatedSize
    let suggestedDisposition: Disposition
    let isProtected: Bool            // set by engine (allow ∩ roots − deny); display-only if true
}
```

**Invariants (engine-enforced, spec 22)**: (DM-1) `recoverability == .none ⇒ risk == .dangerous`;
(DM-3) `risk` consistent with `safetyScore.riskLevel`, plugins may present *stricter* only;
(DM-4) `isProtected == true ⇒ no PlannedAction targets it`; `suggestedDisposition == .purge` is
rejected at plan time without escalation.

---

## 7. Reclaim accounting (`CleanerCore/Reclaim.swift`)

```swift
struct ReclaimEstimate: Sendable, Codable, Hashable {
    let logicalBytes: Int64          // naive sum — context only
    let onDiskBytes: Int64           // allocatedSize, clone/hardlink corrected — headline
    let sharedBytesExcluded: Int64   // blocks NOT counted (clones/hardlinks)
    let confidence: ReclaimConfidence
}

struct ReclaimActual: Sendable, Codable, Hashable {
    let onDiskBytesFreed: Int64      // MEASURED delta (statfs + per-item accounting)
    let logicalBytesRemoved: Int64
}

enum ReclaimConfidence: String, Codable, Sendable { case exact, estimated, unknown }
```

**Invariants (DM-8/9)**: reclaim is computed from `allocatedSize` with shared-block exclusion,
never raw `size`; dry-run and real-run use the identical measurement code path.

---

## 8. `ScanResult` (`CleanerCore/ScanResult.swift`)

```swift
struct ScanResult: Sendable, Codable {
    let sessionID: SessionID
    let startedAt: Date
    let finishedAt: Date
    let findings: [Finding]
    let byCategory: [CategoryID: [FindingID]]
    let totals: ScanTotals
    let skipped: [SkippedPath]                 // report what we could NOT scan (Principle 3)
    let pluginRuns: [PluginRunSummary]
    let wasCancelled: Bool
    // Deferred v0.5+: cacheStats (incremental scan)
}

struct ScanTotals: Sendable, Codable, Hashable {
    let findingCount: Int
    let reclaimable: ReclaimEstimate           // aggregate, shared-block de-duplicated
    let byRisk: [RiskLevel: Int]
}

struct SkippedPath: Sendable, Codable, Hashable { let path: FilePath; let reason: SkipReason }

enum SkipReason: String, Codable, Sendable {
    case permissionDenied, protectedPath, dataless, snapshot, ioError, cycle, tooDeep, cancelled
}

struct PluginRunSummary: Sendable, Codable, Hashable {
    let plugin: PluginID
    let duration: Duration
    let findingCount: Int
    let error: String?                          // non-fatal plugin error (→ exit 3/7)
}
```

---

## 9. `CleanPlan` (`CleanerCore/CleanPlan.swift`)

```swift
struct CleanPlan: Sendable, Codable {
    let id: UUID
    let sessionID: SessionID
    let createdAt: Date
    let actions: [PlannedAction]                // ordered children→parents, safe→risky (spec 20)
    let projectedReclaim: ReclaimEstimate       // shared-block corrected
    let requiresConfirmation: Bool
    // Deferred v0.5+: policyRef (signed automation policy)
}

struct PlannedAction: Sendable, Codable, Hashable, Identifiable {
    let id: UUID
    let finding: FindingID
    let disposition: Disposition
    let confirmed: ConfirmationState
}

enum ConfirmationState: String, Codable, Sendable {
    case preselected            // 🟢 default-selected, plain confirm
    case explicitInteractive    // user selected
    case typedConfirmation      // 🔴 typed confirm (scaffolded; no 🔴 plugin ships in v0.1)
    case automationPolicy       // (v0.5+)
}
```

**Invariant (DM-5)**: a `.purge` action or one targeting a `.dangerous` Finding MUST have
`confirmed ∈ {typedConfirmation, automationPolicy}`. Enforced by `CleanupEngine`. For v0.1 the
only `.purge` path is the Trash plugin (🟡) emptying the user's Trash, which requires interactive
confirmation or `--yes --include medium`.

---

## 10. `CleanReport` (`CleanerCore/CleanReport.swift`)

```swift
struct CleanReport: Sendable, Codable {
    let schemaVersion: Int                       // = 1 in v0.1
    let sessionID: SessionID
    let plan: UUID
    let startedAt: Date
    let finishedAt: Date
    let outcomes: [ActionOutcome]
    let realizedReclaim: ReclaimActual           // MEASURED
    let projectedReclaim: ReclaimEstimate        // for estimate-vs-actual truth delta
    let stagingSessionPath: FilePath?
    let exitCode: Int                            // Article 7
}

struct ActionOutcome: Sendable, Codable, Hashable {
    let action: UUID
    let finding: FindingID
    let result: ActionResult
    let disposition: Disposition
    let reclaimed: ReclaimActual?                // nil if skipped/failed
    let stagedAs: StagedRef?                     // rollback handle
    let error: String?
}

enum ActionResult: String, Codable, Sendable {
    case staged, trashed, purged, skipped, failed, blockedBySafety   // blockedBySafety → exit 8
}

struct StagedRef: Sendable, Codable, Hashable {
    let manifestEntryID: UUID
    let stagedPath: FilePath
}
```

---

## 11. Staging & rollback (`CleanerEngine`)

```swift
/// One line in ~/.cleaner/staging/<session-uuid>/manifest.ndjson. Captured BEFORE the move.
struct StagingManifestEntry: Sendable, Codable, Hashable, Identifiable {
    let id: UUID                                 // == StagedRef.manifestEntryID
    let sessionID: SessionID
    let finding: FindingID
    let originalPath: FilePath                   // where it must be restored
    let relativePath: String                     // path under files/ (self-describing)
    let volumeUUID: String                       // match-or-warn on restore
    let kind: ItemKind
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let checksum: String                         // sha256 (file) / tree-manifest hash (dir)
    // Metadata captured for byte-exact restore (spec 21):
    let posixPermissions: UInt16?
    let ownerUID: UInt32?
    let ownerGID: UInt32?
    let xattrs: [String: String]?                // base64 values
    let flags: UInt32?                           // st_flags (uchg/hidden/…)
    let mtime: Date?
    let atime: Date?
    let birthtime: Date?
    let symlinkTarget: String?
    let hardlinkCount: Int?
    let stagedAt: Date
}

/// Reduced view of a staging session for `staging list`.
struct StagingSessionSummary: Sendable, Codable, Hashable, Identifiable {
    let id: SessionID
    let stagedAt: Date
    let itemCount: Int
    let totalStagedBytes: Int64                  // allocated
    let originalPaths: [FilePath]
    let expiresAt: Date?                         // retention (default 14 days)
    let integrityOK: Bool
}

enum RestoreTarget: Sendable { case session(SessionID), entry(UUID), last }

struct RestoreOptions: Sendable {
    var remapTo: FilePath? = nil
    var collision: CollisionPolicy = .fail       // fail | rename | overwrite
    var dryRun: Bool = false
    var force: Bool = false
}
enum CollisionPolicy: String, Sendable, Codable { case fail, rename, overwrite }

struct RestoreReport: Sendable, Codable {
    let session: SessionID
    let restored: [UUID]
    let skippedCollision: [UUID]
    let failedIntegrity: [UUID]
    let warnings: [RestoreWarning]
    let exitCode: Int                            // 0 all / 3 partial / 8 protected breach
}

struct RestoreWarning: Sendable, Codable, Hashable { let entry: UUID; let kind: WarningKind }
enum WarningKind: String, Sendable, Codable {
    case ownershipNotRestored, birthtimeNotSet, hardlinkNotReconstructed,
         xattrTruncated, volumeChanged, cloneShapeLost
}
```

**Invariants**: manifest is append-only, `fsync`-per-record, single-writer via
`manifest.ndjson.lock`; restore verifies `checksum` before moving back and re-applies metadata in
the order ownership → mode → ACL → xattrs → flags → timestamps; every mutation appends an audit
event (FR-099). A restore whose payload fails its checksum is refused (never silently restored).

---

## 12. `Session` (`CleanerCore/Session.swift`)

```swift
struct Session: Sendable, Codable {
    let id: SessionID
    let startedAt: Date
    let command: String                          // "analyze", "clean", "staging-restore"
    let argv: [String]                           // sanitized for audit
    let osVersion: String
    let toolVersion: SemanticVersion
    let scan: ScanResult?
    let plan: CleanPlan?
    let report: CleanReport?
    let finishedAt: Date?
    let exitCode: Int?
    // Deferred v0.5+: profile, configSnapshot (ConfigDigest)
}
```

---

## 13. Plugin metadata (`CleanerPluginAPI`)

```swift
struct PluginDescriptor: Sendable, Codable, Hashable, Identifiable {
    let id: PluginID
    let displayName: String
    let version: SemanticVersion
    let categories: [CategoryID]
    let declaredRoots: [RootSpec]                // symbolic-anchored; engine intersects w/ allow-space
    let capabilities: PluginCapabilities
    let defaultRisk: RiskLevel
    let requiresFullDiskAccess: Bool
    let usesShellOut: Bool                       // false for all v0.1 plugins (native-only)
}

struct PluginCapabilities: OptionSet, Sendable, Codable {
    let rawValue: Int
    static let scan  = PluginCapabilities(rawValue: 1 << 0)
    static let clean = PluginCapabilities(rawValue: 1 << 1)
    // sizeOnly, incremental → v0.5+
}

struct RootSpec: Sendable, Codable, Hashable {
    let base: RootBase                           // .home, .libraryCaches, .developer, .tmp
    let glob: String                             // relative pattern
}
enum RootBase: String, Sendable, Codable { case home, libraryCaches, developer, tmp }

struct SemanticVersion: Sendable, Codable, Hashable, Comparable { let major, minor, patch: Int }
```

v0.1 descriptors:

| Plugin | id | category | declaredRoots (base/glob) | defaultRisk | disposition |
|---|---|---|---|---|---|
| `TrashPlugin` | `dev.cleaner.trash` | `trash` | `.home`/`.Trash`, per-volume `.Trashes` | 🟡 medium | `purge` |
| `DerivedDataPlugin` | `dev.cleaner.xcode` | `developer-cache` | `.developer`/`Xcode/DerivedData/**` | 🟢 safe | `stage` |
| `NpmCachePlugin` | `dev.cleaner.npm` | `developer-cache` | `.home`/`.npm/_cacache/**` | 🟢 safe | `stage` |

---

## 14. Errors & exit codes (`CleanerCore`)

```swift
protocol CleanerError: Error, Sendable { var exitCode: ExitCode { get } }

enum ExitCode: Int32, Sendable {
    case ok = 0, general = 1, usage = 2, partial = 3, permission = 4,
         cancelled = 5, config = 6, plugin = 7, safety = 8, precondition = 10
}
```

Exact reuse of Constitution Article 7 — no new codes. `blockedBySafety`/protected-path attempts →
`ExitCode.safety` (8); permission-denied roots → `partial` (3) on scan, `permission` (4) when a
whole needed root is inaccessible; plugin contract violation → `plugin` (7); user cancel → `5`.

---

## 15. Normative invariant summary (subset of spec 14 §5)

| # | Invariant | Enforced in |
|---|---|---|
| DM-1 | `Recoverability.none ⇒ RiskLevel.dangerous` | Finding init / SafetyScorer |
| DM-2 | Plugin may lower, never raise, `SafetyScore` above the scorer ceiling | SafetyFunnel (ScanEngine) |
| DM-3 | `Finding.risk` matches `safetyScore.riskLevel` (stricter allowed w/ evidence) | SafetyScorer |
| DM-4 | Protected findings produce no `PlannedAction` | ProtectedPathGuard / CleanupEngine |
| DM-5 | `.purge`/`.dangerous` action ⇒ typed/automation confirmation | CleanupEngine |
| DM-6 | All `Item.paths` on one `VolumeID`; cross-volume groups split | ScanEngine |
| DM-7 | `FindingID` deterministic across scans | plugin FindingID derivation |
| DM-8 | Reclaim from `allocatedSize` with shared-block exclusion, never raw `size` | FilesystemService / CleanupEngine |
| DM-9 | Dry-run and real-run reclaim use identical measurement code | CleanupEngine |
| DM-10 | Domain types are `Sendable` value types | Swift 6 compiler |
