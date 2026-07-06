import Testing
import Foundation
@testable import CleanerEngine
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// The 100% safety gate (specs/31). Every protected-path class × every disposition MUST be
/// refused by the engine and leave the target byte-for-byte untouched. If any case here fails,
/// the build does not ship. These use a synthesized home — no real user data is involved.
@Suite("SAFETY GATE: protected paths are never deleted")
struct SafetyGateTests {
    let fs = SystemFilesystem()
    let clock = EngineClock.fixed(Date(timeIntervalSince1970: 0))

    private func harness() throws -> (home: String, engine: CleanupEngine, guard_: ProtectedPathGuard) {
        let base = NSTemporaryDirectory() + "cleaner-safety-" + UUID().uuidString
        let home = base + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let guard_ = ProtectedPathGuard(home: home)
        let staging = StagingManager(stagingRoot: home + "/.cleaner/staging", fs: fs)
        let audit = AuditLog(path: home + "/.cleaner/logs/audit.ndjson")
        let engine = CleanupEngine(fs: fs, guard_: guard_, staging: staging, audit: audit, clock: clock)
        return (home, engine, guard_)
    }

    private func makeDir(_ path: String, bytes: Int = 1024) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/payload.bin",
                                       contents: Data(repeating: 9, count: bytes))
    }

    private func finding(_ path: String) -> Finding {
        Finding(item: Item(id: ItemID("x"), title: "x", path: path,
                           evidence: Evidence(allocatedSize: 1024)),
                pluginID: PluginID("rogue"), category: .developerCache,
                safetyScore: SafetyScore(99), recoverability: .manual, rationale: "")
    }

    /// Relative protected locations we synthesize under the fake home.
    static let protectedRelPaths = [
        "Documents/important", "Desktop/work", "Pictures/album",
        ".ssh", ".gnupg/keys", "Library/Keychains/login.keychain-db",
        "secret.pem", ".aws/credentials",
    ]

    @Test("every protected path × every disposition is blocked and untouched",
          arguments: protectedRelPaths, Disposition.allCases)
    func protectedNeverDeleted(rel: String, disposition: Disposition) throws {
        guard disposition != .skip else { return }   // skip is a no-op by definition
        let (home, engine, _) = try harness()
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

        let target = home + "/" + rel
        makeDir(target)
        // allowedRoots is deliberately broad (the whole home) so ONLY the deny-list can protect.
        let plan = CleanPlan(actions: [.init(finding: finding(target), disposition: disposition)])
        let report = engine.execute(plan, session: SessionID("s"), allowedRoots: [home])

        #expect(report.blocked.count == 1, "\(rel) via \(disposition) should be blocked")
        #expect(report.totalReclaimed == .zero)
        #expect(fs.exists(target), "\(rel) must still exist")
    }

    @Test("a path outside every allowed root is blocked")
    func outsideRootsBlocked() throws {
        let (home, engine, _) = try harness()
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let target = home + "/Library/Caches/legit"
        makeDir(target)
        let plan = CleanPlan(actions: [.init(finding: finding(target), disposition: .stage)])
        // allowedRoots does NOT include the target's parent.
        let report = engine.execute(plan, session: SessionID("s"),
                                    allowedRoots: [home + "/SomethingElse"])
        #expect(report.blocked.count == 1)
        #expect(fs.exists(target))
    }

    @Test("purging a symlink never touches its (protected) target")
    func symlinkTargetSurvives() throws {
        let (home, engine, guard_) = try harness()
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let secret = home + "/Documents/secret"
        makeDir(secret)
        let cache = home + "/Library/Caches"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let link = cache + "/link-to-secret"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secret)

        // The link lives in an allowed root; disposing it must not follow to the target.
        _ = guard_
        let plan = CleanPlan(actions: [.init(finding: finding(link), disposition: .purge)])
        _ = engine.execute(plan, session: SessionID("s"), allowedRoots: [cache])
        #expect(fs.exists(secret), "symlink target (protected) must survive")
        #expect(fs.exists(secret + "/payload.bin"))
    }

    @Test("dry-run over protected paths mutates nothing")
    func dryRunNeverMutates() throws {
        let (home, engine, _) = try harness()
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let target = home + "/Documents/keepme"
        makeDir(target)
        let plan = CleanPlan(actions: [.init(finding: finding(target), disposition: .purge)],
                             dryRun: true)
        _ = engine.execute(plan, session: SessionID("s"), allowedRoots: [home])
        #expect(fs.exists(target))
    }
}
