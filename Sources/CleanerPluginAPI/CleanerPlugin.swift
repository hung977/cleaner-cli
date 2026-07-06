import Foundation
import CleanerCore
import CleanerPlatform

/// Whether a plugin proposes cleanups or only surfaces information (specs/13).
public enum PluginKind: String, Sendable, Hashable, Codable {
    /// Proposes items to clean; part of the default scan/clean pipeline.
    case cleaner
    /// Read-only insight (large files, duplicates). Findings are informational — they may point
    /// at user files anywhere, are never auto-cleaned, and run via their own commands, not the
    /// default `analyze`/`clean` scan.
    case detector
}

/// Identity + defaults a plugin advertises (specs/13).
public struct PluginMetadata: Sendable, Hashable {
    public let id: PluginID
    public let name: String
    public let category: FindingCategory
    public let defaultRisk: RiskLevel
    public let kind: PluginKind
    public let version: String

    public init(id: PluginID, name: String, category: FindingCategory,
                defaultRisk: RiskLevel, kind: PluginKind = .cleaner, version: String = "0.1.0") {
        self.id = id
        self.name = name
        self.category = category
        self.defaultRisk = defaultRisk
        self.kind = kind
        self.version = version
    }
}

/// Everything a plugin is allowed to touch, injected by the engine so plugins never reach the OS
/// directly (testability + safety). A plugin resolves its paths from `home` and reads via `fs`.
public struct PluginContext: Sendable {
    public let fs: FilesystemProviding
    public let home: String
    public let now: Date               // injected clock (deterministic in tests)
    /// External-tool runner for shell-adapter plugins (docker/brew/xcrun). Nil in unit tests
    /// unless a mock is supplied; a plugin needing it must degrade gracefully when absent.
    public let shell: ShellRunning?
    private let logger: @Sendable (String) -> Void

    public init(fs: FilesystemProviding, home: String, now: Date,
                shell: ShellRunning? = nil,
                logger: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fs = fs
        self.home = home
        self.now = now
        self.shell = shell
        self.logger = logger
    }

    public func log(_ message: String) { logger(message) }
}

/// A plugin's *proposal* to dispose of one finding. Plugins propose; the engine disposes
/// (Constitution IV). A directive is never executed without passing the engine's safety funnel.
public struct CleanDirective: Sendable {
    public let finding: Finding
    public let disposition: Disposition
    public init(finding: Finding, disposition: Disposition) {
        self.finding = finding
        self.disposition = disposition
    }
}

/// The contract every cleaning capability implements (specs/13). In-process, statically
/// registered for v1 (CC-8). Sendable so the engine can fan out plugins concurrently.
public protocol CleanerPlugin: Sendable {
    var metadata: PluginMetadata { get }

    /// Absolute roots this plugin may operate within, resolved against `context.home`. The engine
    /// intersects these with the allowed space and passes them to the ProtectedPathGuard.
    func declaredRoots(_ context: PluginContext) -> [String]

    /// Read-only discovery. Returns findings; must not mutate the filesystem (specs/17).
    /// v0.1 returns an array; streaming (`AsyncThrowingStream`) is a v0.5 refinement.
    func scan(_ context: PluginContext) async throws -> [Finding]

    /// Propose how to dispose of the selected findings. Pure; no IO (specs/20).
    func plan(for selected: [Finding], context: PluginContext) -> [CleanDirective]
}

public extension CleanerPlugin {
    /// Default: stage every selected finding (the safe, recoverable default).
    func plan(for selected: [Finding], context: PluginContext) -> [CleanDirective] {
        selected.map { CleanDirective(finding: $0, disposition: $0.proposedDisposition) }
    }
}
