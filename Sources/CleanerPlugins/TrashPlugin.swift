import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Empties the macOS Trash. 🟡 Medium: the Trash *is* the recoverable buffer, so emptying it is
/// permanent — it uses the `purge` disposition and requires confirmation (never auto-cleaned
/// under `--yes`). One finding per top-level entry so we purge contents, never `~/.Trash` itself
/// (specs/plugins/plugin-trash.md).
public struct TrashPlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.trash"), name: "Trash",
              category: .trash, defaultRisk: .medium)
    }

    private func root(_ c: PluginContext) -> String { c.home + "/.Trash" }

    public func declaredRoots(_ context: PluginContext) -> [String] { [root(context)] }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        PluginSupport.children(of: root(context), context).compactMap { path in
            PluginSupport.finding(
                path: path, context: context, plugin: metadata, category: .trash,
                score: 70,                       // 🟡 medium — see Art. 4.2 mapping
                recoverability: .manual,         // could restore from Trash until purged
                disposition: .purge,             // emptying Trash is permanent
                rationale: "already in Trash; emptying frees the space permanently")
        }
    }
}
