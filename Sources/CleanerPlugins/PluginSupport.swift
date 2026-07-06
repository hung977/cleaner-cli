import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Shared helpers for the bundled plugins: turn a filesystem path into a `Finding` with a
/// consistent id and truthful measurement. Keeps each plugin small and focused on *what* to
/// target and *why it's safe* rather than boilerplate.
enum PluginSupport {
    /// Build a finding for `path` if it exists and is non-empty. Returns nil otherwise.
    static func finding(
        path: String,
        context: PluginContext,
        plugin: PluginMetadata,
        category: FindingCategory,
        score: Int,
        recoverability: Recoverability,
        disposition: Disposition,
        rationale: String,
        title: String? = nil
    ) -> Finding? {
        guard context.fs.exists(path) else { return nil }
        guard let evidence = try? context.fs.measure(path), evidence.allocatedSize > .zero else {
            return nil
        }
        let name = title ?? (path as NSString).lastPathComponent
        // Namespaced, deterministic id (stable across runs for the same path).
        let id = ItemID(plugin.id.rawValue + ":" + name)
        let item = Item(id: id, title: name, path: path, evidence: evidence)
        return Finding(item: item, pluginID: plugin.id, category: category,
                       safetyScore: SafetyScore(score), recoverability: recoverability,
                       proposedDisposition: disposition, rationale: rationale)
    }

    /// Immediate children of `root`, or [] if it doesn't exist.
    static func children(of root: String, _ context: PluginContext) -> [String] {
        guard context.fs.exists(root) else { return [] }
        return (try? context.fs.children(of: root)) ?? []
    }
}

/// The compile-time set of plugins shipped with v0.1 (CC-8, static registry).
public enum BundledPlugins {
    public static func all() -> [any CleanerPlugin] {
        [XcodeDerivedDataPlugin(), NpmCachePlugin(), TrashPlugin()]
    }
}
