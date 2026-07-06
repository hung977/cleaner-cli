import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Cleans orphaned iOS Simulator devices — those whose runtime was removed (`isAvailable == false`),
/// so they can never boot again (specs/plugins/plugin-simulator.md). Detection is read-only via
/// `xcrun simctl list devices --json`; the reclaim is file-based (stage the device directory under
/// CoreSimulator/Devices), so it flows through the normal staging + rollback path. 🟡 Medium
/// (a device may hold app data) — never auto-cleaned under `--yes`.
public struct SimulatorPlugin: CleanerPlugin {
    public init() {}

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.simulator"), name: "Simulator (orphaned devices)",
              category: .developerCache, defaultRisk: .medium)
    }

    private func devicesRoot(_ c: PluginContext) -> String {
        c.home + "/Library/Developer/CoreSimulator/Devices"
    }

    public func declaredRoots(_ context: PluginContext) -> [String] { [devicesRoot(context)] }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        guard let shell = context.shell, shell.available("xcrun") else { return [] }
        let result = shell.run("xcrun", ["simctl", "list", "devices", "--json"], timeout: 20)
        guard result.ok else { return [] }
        return findings(fromJSON: result.stdout, context: context)
    }

    /// Parse simctl JSON and build a finding per unavailable (orphaned) device that still has files.
    func findings(fromJSON json: String, context: PluginContext) -> [Finding] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return [] }

        var out: [Finding] = []
        for (_, list) in devices {
            guard let arr = list as? [[String: Any]] else { continue }
            for dev in arr {
                let available = dev["isAvailable"] as? Bool ?? true
                guard available == false, let udid = dev["udid"] as? String else { continue }
                let name = dev["name"] as? String ?? udid
                let path = devicesRoot(context) + "/" + udid
                if let f = PluginSupport.finding(
                    path: path, context: context, plugin: metadata, category: .developerCache,
                    score: 65, recoverability: .manual, disposition: .stage,
                    rationale: "orphaned simulator — its runtime was removed",
                    title: "\(name) (removed runtime)") {
                    out.append(f)
                }
            }
        }
        return out
    }
}
