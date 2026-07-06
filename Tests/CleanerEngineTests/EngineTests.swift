import Testing
import Foundation
@testable import CleanerEngine
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// A stub plugin that reports each immediate child of a root as a Safe, stageable finding.
private struct StubPlugin: CleanerPlugin {
    let root: String
    let risk: RiskLevel
    var metadata: PluginMetadata {
        .init(id: PluginID("stub"), name: "Stub", category: .developerCache, defaultRisk: risk)
    }
    func declaredRoots(_ context: PluginContext) -> [String] { [root] }
    func scan(_ context: PluginContext) async throws -> [Finding] {
        guard context.fs.exists(root) else { return [] }
        return try context.fs.children(of: root).map { path in
            let e = try context.fs.measure(path)
            let item = Item(id: ItemID((path as NSString).lastPathComponent),
                            title: (path as NSString).lastPathComponent, path: path, evidence: e)
            return Finding(item: item, pluginID: metadata.id, category: .developerCache,
                           safetyScore: SafetyScore(95), recoverability: .manual,
                           proposedDisposition: .stage, rationale: "regenerated on next build")
        }
    }
}

@Suite("Engine: scan + cleanup end to end")
struct EngineTests {
    let fs = SystemFilesystem()
    let clock = EngineClock.fixed(Date(timeIntervalSince1970: 0))

    private func sandbox() throws -> (root: String, ctx: PluginContext, engine: (ScanEngine, CleanupEngine, StagingManager)) {
        let base = NSTemporaryDirectory() + "cleaner-eng-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let home = base + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let guard_ = ProtectedPathGuard(home: home)
        let staging = StagingManager(stagingRoot: home + "/.cleaner/staging", fs: fs)
        let audit = AuditLog(path: home + "/.cleaner/logs/audit.ndjson")
        let ctx = PluginContext(fs: fs, home: home, now: clock.now)
        return (base, ctx, (ScanEngine(guard_: guard_),
                            CleanupEngine(fs: fs, guard_: guard_, staging: staging,
                                          audit: audit, clock: clock), staging))
    }

    private func makeCache(_ root: String, _ names: [(String, Int)]) throws {
        for (n, bytes) in names {
            let p = root + "/" + n + "/data.bin"
            try FileManager.default.createDirectory(atPath: root + "/" + n, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: p, contents: Data(repeating: 1, count: bytes))
        }
    }

    @Test("scan finds items sorted by reclaim, cleanup stages them and tallies")
    func scanThenClean() async throws {
        let (base, ctx, (scanE, cleanE, staging)) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let cacheRoot = ctx.home + "/Library/Caches/dev"
        try makeCache(cacheRoot, [("small", 1000), ("big", 50_000)])

        let plugin = StubPlugin(root: cacheRoot, risk: .safe)
        let result = await scanE.scan(plugins: [plugin], context: ctx)
        #expect(result.findings.count == 2)
        #expect(result.findings.first?.item.title == "big")     // largest first

        let plan = CleanPlan(actions: result.findings.map { .init(finding: $0, disposition: .stage) })
        let report = cleanE.execute(plan, session: SessionID("s"), allowedRoots: [cacheRoot])
        #expect(report.succeeded.count == 2)
        #expect(!report.isPartial)
        #expect(report.totalReclaimed.bytes >= 51_000)
        #expect(!ctx.fs.exists(cacheRoot + "/big"))             // actually moved out
        #expect(try staging.allEntries().count == 2)            // recoverable
    }

    @Test("dry-run reports identical reclaim but mutates nothing (DM-9)")
    func dryRunNoMutation() async throws {
        let (base, ctx, (scanE, cleanE, _)) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let cacheRoot = ctx.home + "/Library/Caches/dev"
        try makeCache(cacheRoot, [("a", 4096), ("b", 8192)])

        let result = await scanE.scan(plugins: [StubPlugin(root: cacheRoot, risk: .safe)], context: ctx)
        let realPlan = CleanPlan(actions: result.findings.map { .init(finding: $0, disposition: .stage) })
        let dryPlan = CleanPlan(actions: realPlan.actions, dryRun: true)

        let dry = cleanE.execute(dryPlan, session: SessionID("s"), allowedRoots: [cacheRoot])
        #expect(ctx.fs.exists(cacheRoot + "/a"))                // nothing moved
        #expect(ctx.fs.exists(cacheRoot + "/b"))
        #expect(dry.dryRun)
        #expect(dry.totalReclaimed == result.totalReclaimable)  // identical numbers
    }

    @Test("cleanup refuses a path outside the allowed roots (exit 8 territory)")
    func cleanupBlocksProtected() async throws {
        let (base, ctx, (_, cleanE, _)) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        // Fabricate a finding pointing at the user's Documents (protected) — as if a rogue plugin.
        let evil = ctx.home + "/Documents/important"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        let f = Finding(item: Item(id: ItemID("evil"), title: "important", path: evil,
                        evidence: Evidence(allocatedSize: 1000)),
                        pluginID: PluginID("stub"), category: .developerCache,
                        safetyScore: SafetyScore(95), recoverability: .manual, rationale: "")
        let plan = CleanPlan(actions: [.init(finding: f, disposition: .stage)])
        let report = cleanE.execute(plan, session: SessionID("s"),
                                    allowedRoots: [ctx.home + "/Library/Caches"])
        #expect(report.blocked.count == 1)
        #expect(ctx.fs.exists(evil))                            // untouched
    }

    @Test("a throwing plugin is isolated as skipped, not a crash (exit 3/7)")
    func pluginIsolation() async throws {
        struct BoomPlugin: CleanerPlugin {
            var metadata: PluginMetadata { .init(id: PluginID("boom"), name: "Boom",
                                                 category: .trash, defaultRisk: .safe) }
            func declaredRoots(_ c: PluginContext) -> [String] { ["/tmp"] }
            func scan(_ c: PluginContext) async throws -> [Finding] {
                throw FilesystemError.notReadable("boom") }
        }
        let (base, ctx, (scanE, _, _)) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let result = await scanE.scan(plugins: [BoomPlugin()], context: ctx)
        #expect(result.findings.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.pluginID == PluginID("boom"))
    }
}
