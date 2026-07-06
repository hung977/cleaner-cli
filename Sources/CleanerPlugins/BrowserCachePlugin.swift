import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Browser HTTP caches (Chrome/Safari/Firefox/Edge/Brave). 🟡 Medium — rebuilt as you browse.
///
/// SAFETY BOUNDARY (specs/plugins/plugin-browser.md): this plugin targets ONLY cache directories
/// under ~/Library/Caches. It MUST NEVER touch cookies, history, passwords, bookmarks, or any
/// profile data (those live under ~/Library/Application Support / ~/Library/Safari, which this
/// plugin never lists). The declared roots are the exact cache leaves, nothing broader.
public struct BrowserCachePlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.browser.cache"), name: "Browser caches",
              category: .browser, defaultRisk: .medium)
    }

    private func caches(_ c: PluginContext) -> [(path: String, label: String)] {
        let base = c.home + "/Library/Caches"
        return [
            (base + "/Google/Chrome", "Chrome cache"),
            (base + "/com.apple.Safari", "Safari cache"),
            (base + "/Firefox", "Firefox cache"),
            (base + "/com.microsoft.edgemac", "Edge cache"),
            (base + "/BraveSoftware", "Brave cache"),
        ]
    }

    public func declaredRoots(_ context: PluginContext) -> [String] { caches(context).map(\.path) }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        caches(context).compactMap { store in
            PluginSupport.finding(
                path: store.path, context: context, plugin: metadata, category: .browser,
                score: 72, recoverability: .manual, disposition: .stage,
                rationale: "cache only (never cookies/history/passwords) — rebuilt as you browse",
                title: store.label)
        }
    }
}
