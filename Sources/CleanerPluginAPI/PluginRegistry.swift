import CleanerCore

/// The static, compile-time set of available plugins (CC-8). Discovery for v1 is just "whatever
/// was linked in and registered here" — no dynamic loading (that is a v2 concern).
public struct PluginRegistry: Sendable {
    public let plugins: [any CleanerPlugin]

    public init(_ plugins: [any CleanerPlugin]) {
        self.plugins = plugins
    }

    public func plugin(id: PluginID) -> (any CleanerPlugin)? {
        plugins.first { $0.metadata.id == id }
    }

    /// Resolve the active plugin set from `--include`/`--exclude` selectors.
    /// `include == nil` means "all"; exclude always wins.
    public func selected(include: Set<PluginID>? = nil,
                         exclude: Set<PluginID> = []) -> [any CleanerPlugin] {
        plugins.filter { p in
            let id = p.metadata.id
            if exclude.contains(id) { return false }
            if let include { return include.contains(id) }
            return true
        }
    }

    public var ids: [PluginID] { plugins.map { $0.metadata.id } }
}

/// A reusable contract check every plugin must satisfy (specs/13 §contract tests). Used by
/// plugin unit tests to guarantee no plugin can smuggle absolute paths or violate basics.
public enum PluginContract {
    /// Returns a list of contract violations (empty == compliant).
    public static func violations(of plugin: any CleanerPlugin, context: PluginContext) -> [String] {
        var problems: [String] = []
        let roots = plugin.declaredRoots(context)
        if roots.isEmpty {
            // A plugin with no roots (e.g. a shell-only plugin) is allowed, but note it.
        }
        for r in roots where !r.hasPrefix("/") {
            problems.append("declared root is not absolute: \(r)")
        }
        if plugin.metadata.id.rawValue.isEmpty {
            problems.append("plugin id is empty")
        }
        return problems
    }
}
