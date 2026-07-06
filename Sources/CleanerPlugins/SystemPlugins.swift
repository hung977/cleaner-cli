import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Generic application caches under ~/Library/Caches (specs/plugins). 🟡 Medium — most apps
/// rebuild these, but some keep light state, so it's never auto-cleaned. Dev-tool and browser
/// caches are excluded here because dedicated plugins own them (no double counting).
public struct AppCachePlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.appcache"), name: "Application caches",
              category: .appCache, defaultRisk: .medium)
    }

    private func root(_ c: PluginContext) -> String { c.home + "/Library/Caches" }

    /// Owned by other plugins → skip to avoid double counting.
    private static let excluded: Set<String> = [
        "org.swift.swiftpm", "CocoaPods", "pip", "Homebrew", "Yarn",     // dev tools
        "com.apple.Safari", "Google", "Mozilla", "Firefox",             // browsers
        "com.microsoft.edgemac", "BraveSoftware", "com.operasoftware.Opera",
    ]

    public func declaredRoots(_ context: PluginContext) -> [String] { [root(context)] }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        PluginSupport.children(of: root(context), context).compactMap { path in
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") || Self.excluded.contains(name) { return nil }
            return PluginSupport.finding(
                path: path, context: context, plugin: metadata, category: .appCache,
                score: 70, recoverability: .manual, disposition: .stage,
                rationale: "app cache — rebuilt automatically when the app runs")
        }
    }
}

/// User application logs & crash reports under ~/Library/Logs. 🟡 Medium — safe to remove but
/// occasionally useful for debugging, so not auto-cleaned.
public struct LogsPlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.logs"), name: "Logs & crash reports",
              category: .logs, defaultRisk: .medium)
    }

    private func root(_ c: PluginContext) -> String { c.home + "/Library/Logs" }

    public func declaredRoots(_ context: PluginContext) -> [String] { [root(context)] }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        PluginSupport.children(of: root(context), context).compactMap { path in
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") { return nil }
            return PluginSupport.finding(
                path: path, context: context, plugin: metadata, category: .logs,
                score: 72, recoverability: .manual, disposition: .stage,
                rationale: "log/diagnostic files — regenerated as needed")
        }
    }
}
