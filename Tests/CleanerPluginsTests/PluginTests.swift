import Testing
import Foundation
@testable import CleanerPlugins
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

@Suite("Plugins: bundled v0.1 plugins")
struct PluginTests {
    let fs = SystemFilesystem()

    private func homeWithFixtures() throws -> (base: String, ctx: PluginContext) {
        let base = NSTemporaryDirectory() + "cleaner-plug-" + UUID().uuidString
        let home = base + "/home"
        func mk(_ rel: String, bytes: Int) {
            let p = home + "/" + rel
            try? FileManager.default.createDirectory(
                atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: p, contents: Data(repeating: 7, count: bytes))
        }
        mk("Library/Developer/Xcode/DerivedData/MyApp-abc123/Build/x.o", bytes: 40_000)
        mk(".npm/_cacache/index-v5/aa/data", bytes: 20_000)
        mk(".Trash/oldfile.zip", bytes: 10_000)
        let ctx = PluginContext(fs: fs, home: home, now: Date(timeIntervalSince1970: 0))
        return (base, ctx)
    }

    @Test("all bundled plugins satisfy the contract & declare absolute roots")
    func contract() throws {
        let (base, ctx) = try homeWithFixtures()
        defer { try? FileManager.default.removeItem(atPath: base) }
        for plugin in BundledPlugins.all() {
            #expect(PluginContract.violations(of: plugin, context: ctx).isEmpty)
            #expect(plugin.declaredRoots(ctx).allSatisfy { $0.hasPrefix("/") })
        }
    }

    @Test("Xcode DerivedData is Safe and stageable")
    func xcode() async throws {
        let (base, ctx) = try homeWithFixtures()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let findings = try await XcodeDerivedDataPlugin().scan(ctx)
        #expect(findings.count == 1)
        let f = try #require(findings.first)
        #expect(f.risk == .safe)
        #expect(f.proposedDisposition == .stage)
        #expect(f.reclaimableSize.bytes >= 40_000)
    }

    @Test("npm cache is Safe and stageable")
    func npm() async throws {
        let (base, ctx) = try homeWithFixtures()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let findings = try await NpmCachePlugin().scan(ctx)
        #expect(findings.contains { $0.item.title == "npm cache" })
        #expect(findings.allSatisfy { $0.risk == .safe && $0.proposedDisposition == .stage })
    }

    @Test("Trash is Medium risk and uses purge (never auto-cleaned)")
    func trash() async throws {
        let (base, ctx) = try homeWithFixtures()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let findings = try await TrashPlugin().scan(ctx)
        #expect(findings.count == 1)
        let f = try #require(findings.first)
        #expect(f.risk == .medium)
        #expect(f.proposedDisposition == .purge)
        #expect(!f.risk.isAutoCleanable)          // never under --yes
    }

    @Test("plugins report nothing when their roots are absent")
    func emptyWhenAbsent() async throws {
        let empty = PluginContext(fs: fs, home: "/nonexistent-\(UUID().uuidString)",
                                  now: Date(timeIntervalSince1970: 0))
        for plugin in BundledPlugins.all() {
            #expect(try await plugin.scan(empty).isEmpty)
        }
    }
}
