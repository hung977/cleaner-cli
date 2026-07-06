import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Cleans Xcode DerivedData — build intermediates & indexes Xcode regenerates automatically.
/// 🟢 Safe: no user source, fully rebuildable. One finding per project's DerivedData folder
/// (specs/plugins/plugin-xcode.md, v0.1 subset).
public struct XcodeDerivedDataPlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.xcode.deriveddata"), name: "Xcode DerivedData",
              category: .developerCache, defaultRisk: .safe)
    }

    private func root(_ c: PluginContext) -> String {
        c.home + "/Library/Developer/Xcode/DerivedData"
    }

    public func declaredRoots(_ context: PluginContext) -> [String] { [root(context)] }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        PluginSupport.children(of: root(context), context).compactMap { path in
            let name = (path as NSString).lastPathComponent
            // Skip Finder/OS cruft that isn't ours to describe as a build product.
            if name == ".DS_Store" || name.hasPrefix(".") { return nil }
            return PluginSupport.finding(
                path: path, context: context, plugin: metadata, category: .developerCache,
                score: 96, recoverability: .manual, disposition: .stage,
                rationale: "Xcode regenerates this on next build")
        }
    }
}
