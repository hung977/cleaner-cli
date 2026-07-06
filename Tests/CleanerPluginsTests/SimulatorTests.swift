import Testing
import Foundation
@testable import CleanerPlugins
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// A shell mock that returns a canned simctl JSON payload.
private struct MockShell: ShellRunning {
    let json: String
    func available(_ tool: String) -> Bool { true }
    func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> ShellResult {
        ShellResult(exitCode: 0, stdout: json, stderr: "", timedOut: false)
    }
}

@Suite("Plugins: Simulator (orphaned devices)")
struct SimulatorTests {
    let fs = SystemFilesystem()

    @Test("reports only unavailable devices that still have files, as Medium/stage")
    func orphaned() async throws {
        let base = NSTemporaryDirectory() + "cleaner-sim-" + UUID().uuidString
        let home = base + "/home"
        let devices = home + "/Library/Developer/CoreSimulator/Devices"
        let deadUDID = "DEAD-1111", liveUDID = "LIVE-2222"
        for u in [deadUDID, liveUDID] {
            try FileManager.default.createDirectory(atPath: devices + "/" + u, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: devices + "/" + u + "/data.bin",
                                           contents: Data(repeating: 1, count: 50_000))
        }
        defer { try? FileManager.default.removeItem(atPath: base) }

        let json = """
        { "devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-15-0 (unavailable)": [
            { "udid": "\(deadUDID)", "name": "iPhone 12", "isAvailable": false }
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            { "udid": "\(liveUDID)", "name": "iPhone 15", "isAvailable": true }
          ]
        } }
        """
        let ctx = PluginContext(fs: fs, home: home, now: Date(timeIntervalSince1970: 0),
                                shell: MockShell(json: json))
        let findings = try await SimulatorPlugin().scan(ctx)
        #expect(findings.count == 1)                         // only the orphaned one
        let f = try #require(findings.first)
        #expect(f.item.path.hasSuffix(deadUDID))
        #expect(f.risk == .medium && f.proposedDisposition == .stage)
    }

    @Test("no shell → no findings (degrades gracefully)")
    func noShell() async throws {
        let ctx = PluginContext(fs: fs, home: "/tmp/none-\(UUID().uuidString)",
                                now: Date(timeIntervalSince1970: 0))
        #expect(try await SimulatorPlugin().scan(ctx).isEmpty)
    }
}
