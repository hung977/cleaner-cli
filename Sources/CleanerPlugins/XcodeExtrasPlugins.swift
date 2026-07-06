import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Xcode Archives (~/Library/Developer/Xcode/Archives). 🔴 Dangerous — each archive holds a
/// shipped build + dSYMs you may need to re-symbolicate crash reports or re-export an .ipa.
/// Never auto-cleaned; requires typed confirmation (specs/plugins/plugin-xcode.md).
public struct XcodeArchivesPlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.xcode.archives"), name: "Xcode Archives",
              category: .developerCache, defaultRisk: .dangerous)
    }

    private func root(_ c: PluginContext) -> String { c.home + "/Library/Developer/Xcode/Archives" }

    public func declaredRoots(_ context: PluginContext) -> [String] { [root(context)] }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        PluginSupport.children(of: root(context), context).compactMap { path in
            PluginSupport.finding(
                path: path, context: context, plugin: metadata, category: .developerCache,
                score: 30, recoverability: .hard, disposition: .stage,
                rationale: "shipped build + dSYMs — keep if you may re-symbolicate or re-export")
        }
    }
}

/// Xcode device-support caches (iOS/watchOS/tvOS DeviceSupport). 🟡 Medium — re-created when you
/// next connect a device running that OS version. Old OS versions are dead weight.
public struct XcodeDeviceSupportPlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.xcode.devicesupport"), name: "Xcode DeviceSupport",
              category: .developerCache, defaultRisk: .medium)
    }

    private func roots(_ c: PluginContext) -> [String] {
        let base = c.home + "/Library/Developer/Xcode"
        return ["\(base)/iOS DeviceSupport", "\(base)/watchOS DeviceSupport", "\(base)/tvOS DeviceSupport"]
    }

    public func declaredRoots(_ context: PluginContext) -> [String] { roots(context) }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        roots(context).flatMap { root -> [Finding] in
            let os = (root as NSString).lastPathComponent.replacingOccurrences(of: " DeviceSupport", with: "")
            return PluginSupport.children(of: root, context).compactMap { path in
                let ver = (path as NSString).lastPathComponent
                return PluginSupport.finding(
                    path: path, context: context, plugin: metadata, category: .developerCache,
                    score: 66, recoverability: .manual, disposition: .stage,
                    rationale: "re-created when you connect a device on that OS",
                    title: "\(os) \(ver)")
            }
        }
    }
}
