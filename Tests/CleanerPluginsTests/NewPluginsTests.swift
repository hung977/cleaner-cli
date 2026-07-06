import Testing
import Foundation
@testable import CleanerPlugins
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

@Suite("Plugins: system, browser & Xcode extras")
struct NewPluginsTests {
    let fs = SystemFilesystem()

    private func home() throws -> (base: String, ctx: PluginContext) {
        let base = NSTemporaryDirectory() + "cleaner-new-" + UUID().uuidString
        let h = base + "/home"
        try FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
        return (base, PluginContext(fs: fs, home: h, now: Date(timeIntervalSince1970: 0)))
    }
    private func mk(_ ctx: PluginContext, _ rel: String, _ bytes: Int = 4096) {
        let p = ctx.home + "/" + rel + "/f"
        try? FileManager.default.createDirectory(atPath: ctx.home + "/" + rel, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 7, count: bytes))
    }

    @Test("app-cache reports generic caches but excludes dev/browser dirs")
    func appCache() async throws {
        let (base, ctx) = try home(); defer { try? FileManager.default.removeItem(atPath: base) }
        mk(ctx, "Library/Caches/com.spotify.client")
        mk(ctx, "Library/Caches/Homebrew")          // excluded (dev)
        mk(ctx, "Library/Caches/Google")            // excluded (browser)
        let f = try await AppCachePlugin().scan(ctx)
        #expect(f.map { $0.item.title }.sorted() == ["com.spotify.client"])
        #expect(f.allSatisfy { $0.risk == .medium })
    }

    @Test("browser plugin targets ONLY cache dirs, never profile data")
    func browserSafety() async throws {
        let (base, ctx) = try home(); defer { try? FileManager.default.removeItem(atPath: base) }
        mk(ctx, "Library/Caches/Google/Chrome")
        mk(ctx, "Library/Application Support/Google/Chrome/Default")   // cookies/history — must be ignored
        let plugin = BrowserCachePlugin()
        // No declared root may point outside ~/Library/Caches.
        #expect(plugin.declaredRoots(ctx).allSatisfy { $0.contains("/Library/Caches/") })
        #expect(plugin.declaredRoots(ctx).allSatisfy { !$0.contains("Application Support") })
        let f = try await plugin.scan(ctx)
        #expect(f.contains { $0.item.title == "Chrome cache" })
        #expect(f.allSatisfy { $0.item.path.contains("/Library/Caches/") })
        #expect(f.allSatisfy { $0.risk == .medium })
    }

    @Test("logs are Medium")
    func logs() async throws {
        let (base, ctx) = try home(); defer { try? FileManager.default.removeItem(atPath: base) }
        mk(ctx, "Library/Logs/MyApp")
        let f = try await LogsPlugin().scan(ctx)
        #expect(!f.isEmpty && f.allSatisfy { $0.risk == .medium })
    }

    @Test("Xcode Archives are Dangerous (never auto-cleaned)")
    func archives() async throws {
        let (base, ctx) = try home(); defer { try? FileManager.default.removeItem(atPath: base) }
        mk(ctx, "Library/Developer/Xcode/Archives/2026-01-01")
        let f = try await XcodeArchivesPlugin().scan(ctx)
        #expect(f.count == 1)
        let a = try #require(f.first)
        #expect(a.risk == .dangerous)
        #expect(!a.risk.isAutoCleanable)          // never under --yes/--all
        #expect(a.recoverability == .hard)
    }

    @Test("DeviceSupport is Medium, labelled by OS+version")
    func deviceSupport() async throws {
        let (base, ctx) = try home(); defer { try? FileManager.default.removeItem(atPath: base) }
        mk(ctx, "Library/Developer/Xcode/iOS DeviceSupport/17.0")
        let f = try await XcodeDeviceSupportPlugin().scan(ctx)
        #expect(f.count == 1)
        #expect(f.first?.item.title == "iOS 17.0")
        #expect(f.first?.risk == .medium)
    }
}
