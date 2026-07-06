import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Cleans the npm/yarn/pnpm download caches — content-addressable stores the package managers
/// re-fetch on demand. 🟢 Safe: no project data, fully re-downloadable
/// (specs/plugins/plugin-node.md, v0.1 subset). One finding per cache store found.
public struct NpmCachePlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.node.cache"), name: "Node package caches",
              category: .developerCache, defaultRisk: .safe)
    }

    /// Well-known cache stores (resolved against home). Absolute → the guard verifies them.
    private func stores(_ c: PluginContext) -> [(path: String, label: String)] {
        [
            (c.home + "/.npm/_cacache", "npm cache"),
            (c.home + "/Library/Caches/Yarn", "Yarn cache"),
            (c.home + "/Library/pnpm/store", "pnpm store"),
            (c.home + "/.pnpm-store", "pnpm store (legacy)"),
        ]
    }

    public func declaredRoots(_ context: PluginContext) -> [String] {
        stores(context).map(\.path)
    }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        stores(context).compactMap { store in
            PluginSupport.finding(
                path: store.path, context: context, plugin: metadata, category: .developerCache,
                score: 95, recoverability: .manual, disposition: .stage,
                rationale: "re-downloaded automatically on next install", title: store.label)
        }
    }
}
