import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI
import CleanerEngine
import CleanerPlugins
import CleanerReport
import CleanerConfig

/// The composition root: wires the real services together for a CLI run (specs/11 §DI).
/// Everything below is constructor-injected so the same graph is exercised by tests.
struct Runtime {
    let home: String
    let toolHome: String
    let session: SessionID
    let fs: SystemFilesystem
    let clock: EngineClock
    let guard_: ProtectedPathGuard
    let staging: StagingManager
    let audit: AuditLog
    let registry: PluginRegistry
    let scanEngine: ScanEngine
    let cleanupEngine: CleanupEngine
    let renderer: SummaryRenderer
    let config: CleanerConfiguration
    let configError: Error?

    init(useColor: Bool) {
        let env = ProcessInfo.processInfo.environment
        self.home = env["CLEANER_TEST_HOME"] ?? NSHomeDirectory()
        self.toolHome = env["CLEANER_HOME"] ?? (home + "/.cleaner")
        self.fs = SystemFilesystem()
        self.clock = EngineClock()

        // Session id: sortable date + short random suffix (from UUID, not a hot loop).
        let stamp = Self.compactStamp(clock.now)
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        self.session = SessionID("\(stamp)-\(suffix)")

        self.guard_ = ProtectedPathGuard(home: home, toolHome: toolHome)
        self.staging = StagingManager(stagingRoot: toolHome + "/staging", fs: fs)
        self.audit = AuditLog(path: toolHome + "/logs/audit/"
                              + String(stamp.prefix(8)) + ".ndjson")
        self.registry = PluginRegistry(BundledPlugins.all())
        self.scanEngine = ScanEngine(guard_: guard_)
        self.cleanupEngine = CleanupEngine(fs: fs, guard_: guard_, staging: staging,
                                           audit: audit, clock: clock)
        self.renderer = SummaryRenderer(useColor: useColor)

        do { self.config = try ConfigLoader().load(path: toolHome + "/config.yml"); self.configError = nil }
        catch { self.config = .empty; self.configError = error }
    }

    /// Drop findings excluded by the user's `ignore`/`whitelist` globs (specs/24).
    func applyConfig(_ result: ScanResult) -> ScanResult {
        var r = result
        r.findings = result.findings.filter { f in
            !f.item.allPaths.contains { config.excludes($0) }
        }
        return r
    }

    func context() -> PluginContext {
        PluginContext(fs: fs, home: home, now: clock.now, shell: ShellAdapter(),
                      logger: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    }

    /// Map of plugin id → human name, for collapsing findings by source in the summary.
    func pluginNames() -> [PluginID: String] {
        Dictionary(uniqueKeysWithValues: registry.plugins.map { ($0.metadata.id, $0.metadata.name) })
    }

    /// Union of all declared roots — the allow-space the cleanup guard validates against.
    func allowedRoots(_ plugins: [any CleanerPlugin], _ ctx: PluginContext) -> [String] {
        plugins.flatMap { $0.declaredRoots(ctx) }
    }

    private static func compactStamp(_ date: Date) -> String {
        // yyyymmdd-hhmmss without a shared DateFormatter (Sendable-safe).
        let c = Calendar(identifier: .gregorian)
        let p = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func z(_ n: Int?, _ w: Int) -> String { String(format: "%0\(w)d", n ?? 0) }
        return "\(z(p.year,4))\(z(p.month,2))\(z(p.day,2))-\(z(p.hour,2))\(z(p.minute,2))\(z(p.second,2))"
    }
}

/// Error resolving a `--profile` selection (maps to exit 6).
struct SelectionError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Combine a `--profile` with CLI `--include/--exclude` (CLI always wins). Returns the effective
/// include/exclude selectors and whether the profile requests risky (Medium) cleaning.
func resolveSelection(config: CleanerConfiguration, profileName: String?,
                      include: String?, exclude: String?) throws -> (include: String?, exclude: String?, risky: Bool) {
    guard let name = profileName else { return (include, exclude, false) }
    guard let p = config.profiles[name] else {
        throw SelectionError(message: "unknown profile '\(name)' — see: cleaner profile list")
    }
    let inc = include ?? (p.include.isEmpty ? nil : p.include.joined(separator: ","))
    let exc = exclude ?? (p.exclude.isEmpty ? nil : p.exclude.joined(separator: ","))
    return (inc, exc, p.risky)
}

/// Resolve `--include`/`--exclude` (comma-separated plugin ids) into a selected plugin set.
func selectPlugins(_ registry: PluginRegistry, include: String?, exclude: String?) -> [any CleanerPlugin] {
    func ids(_ s: String?) -> Set<PluginID>? {
        guard let s, !s.isEmpty else { return nil }
        return Set(s.split(separator: ",").map { PluginID(String($0).trimmingCharacters(in: .whitespaces)) })
    }
    return registry.selected(include: ids(include), exclude: ids(exclude) ?? [])
}
