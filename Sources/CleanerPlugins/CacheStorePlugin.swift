import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// A generic Safe (🟢) cache-store plugin: it reports one finding per configured store directory
/// that exists and is non-empty, all staged and re-obtainable. Most developer caches fit this
/// shape, so the concrete plugins below are just configuration (specs/13, specs/plugins/*).
public struct CacheStorePlugin: CleanerPlugin {
    public let metadata: PluginMetadata
    private let storesProvider: @Sendable (PluginContext) -> [(path: String, label: String)]
    private let score: Int
    private let rationale: String

    public init(metadata: PluginMetadata, score: Int, rationale: String,
                stores: @escaping @Sendable (PluginContext) -> [(path: String, label: String)]) {
        self.metadata = metadata
        self.score = score
        self.rationale = rationale
        self.storesProvider = stores
    }

    public func declaredRoots(_ context: PluginContext) -> [String] {
        storesProvider(context).map(\.path)
    }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        storesProvider(context).compactMap { store in
            PluginSupport.finding(
                path: store.path, context: context, plugin: metadata,
                category: .developerCache, score: score, recoverability: .manual,
                disposition: .stage, rationale: rationale, title: store.label)
        }
    }
}

// MARK: - The v0.5 Safe cache plugins (configuration only)

public enum DevCachePlugins {
    public static func swiftPM() -> CacheStorePlugin {
        CacheStorePlugin(
            metadata: .init(id: PluginID("dev.cleaner.swiftpm.cache"), name: "SwiftPM cache",
                            category: .developerCache, defaultRisk: .safe),
            score: 95, rationale: "re-resolved/re-downloaded by Swift Package Manager on next build"
        ) { c in [
            (c.home + "/Library/Caches/org.swift.swiftpm", "SwiftPM cache"),
            (c.home + "/Library/org.swift.swiftpm/security", "SwiftPM security cache"),
        ] }
    }

    public static func cocoaPods() -> CacheStorePlugin {
        CacheStorePlugin(
            metadata: .init(id: PluginID("dev.cleaner.cocoapods.cache"), name: "CocoaPods cache",
                            category: .developerCache, defaultRisk: .safe),
            score: 94, rationale: "re-downloaded by CocoaPods on next `pod install`"
        ) { c in [
            (c.home + "/Library/Caches/CocoaPods", "CocoaPods cache"),
        ] }
    }

    public static func python() -> CacheStorePlugin {
        CacheStorePlugin(
            metadata: .init(id: PluginID("dev.cleaner.python.cache"), name: "Python (pip) cache",
                            category: .developerCache, defaultRisk: .safe),
            score: 95, rationale: "re-downloaded by pip on next install"
        ) { c in [
            (c.home + "/Library/Caches/pip", "pip cache"),
        ] }
    }

    public static func gradle() -> CacheStorePlugin {
        CacheStorePlugin(
            metadata: .init(id: PluginID("dev.cleaner.gradle.cache"), name: "Gradle cache",
                            category: .developerCache, defaultRisk: .safe),
            score: 93, rationale: "re-downloaded/re-built by Gradle on next build"
        ) { c in [
            (c.home + "/.gradle/caches", "Gradle caches"),
        ] }
    }

    public static func homebrew() -> CacheStorePlugin {
        CacheStorePlugin(
            metadata: .init(id: PluginID("dev.cleaner.homebrew.cache"), name: "Homebrew download cache",
                            category: .developerCache, defaultRisk: .safe),
            score: 94, rationale: "re-downloaded by Homebrew on next install/upgrade"
        ) { c in
            let env = ProcessInfo.processInfo.environment["HOMEBREW_CACHE"]
            let brewCache = env ?? (c.home + "/Library/Caches/Homebrew")
            return [(brewCache, "Homebrew cache")]
        }
    }

    public static func all() -> [any CleanerPlugin] {
        [swiftPM(), cocoaPods(), python(), gradle(), homebrew()]
    }
}
