import Testing
import Foundation
@testable import CleanerCore

@Suite("Domain: risk & safety scoring")
struct RiskAndScoreTests {
    @Test("score maps to the fixed risk bands (Art. 4.2)")
    func scoreBands() {
        #expect(SafetyScore(100).impliedRisk == .safe)
        #expect(SafetyScore(85).impliedRisk == .safe)
        #expect(SafetyScore(84).impliedRisk == .medium)
        #expect(SafetyScore(50).impliedRisk == .medium)
        #expect(SafetyScore(49).impliedRisk == .dangerous)
        #expect(SafetyScore(0).impliedRisk == .dangerous)
    }

    @Test("score clamps to 0...100")
    func scoreClamp() {
        #expect(SafetyScore(999).value == 100)
        #expect(SafetyScore(-5).value == 0)
    }

    @Test("risk ordering: safe < medium < dangerous; max finds riskiest")
    func riskOrder() {
        #expect(RiskLevel.safe < .medium)
        #expect(RiskLevel.medium < .dangerous)
        #expect([RiskLevel.safe, .dangerous, .medium].max() == .dangerous)
        #expect(RiskLevel.safe.isPreselected)
        #expect(!RiskLevel.dangerous.isAutoCleanable)
    }
}

@Suite("Domain: Finding derivation invariants")
struct FindingTests {
    private func item(_ bytes: Int64) -> Item {
        Item(id: ItemID("x"), title: "t", path: "/tmp/x",
             evidence: Evidence(allocatedSize: ByteCount(bytes)))
    }

    @Test("non-recoverable finding is forced to dangerous (Art. 4.3)")
    func forcesDangerous() {
        let f = Finding(item: item(10), pluginID: PluginID("p"), category: .trash,
                        safetyScore: SafetyScore(100), recoverability: .none,
                        rationale: "x")
        #expect(f.risk == .dangerous)  // despite score 100
    }

    @Test("risk override may only tighten, never loosen")
    func tightenOnly() {
        let tightened = Finding(item: item(10), pluginID: PluginID("p"), category: .trash,
                                safetyScore: SafetyScore(100), recoverability: .instant,
                                rationale: "x", riskOverride: .medium)
        #expect(tightened.risk == .medium)
        let notLoosened = Finding(item: item(10), pluginID: PluginID("p"), category: .trash,
                                  safetyScore: SafetyScore(0), recoverability: .manual,
                                  rationale: "x", riskOverride: .safe)
        #expect(notLoosened.risk == .dangerous)
    }
}

@Suite("Domain: reclaim accounting & grouping")
struct ReclaimTests {
    @Test("reclaim uses allocated size and totals correctly")
    func totals() {
        let a = Finding(item: Item(id: ItemID("a"), title: "a", path: "/a",
                        evidence: Evidence(logicalSize: 100, allocatedSize: 200)),
                        pluginID: PluginID("p"), category: .developerCache,
                        safetyScore: SafetyScore(90), recoverability: .manual, rationale: "")
        let b = Finding(item: Item(id: ItemID("b"), title: "b", path: "/b",
                        evidence: Evidence(allocatedSize: 300)),
                        pluginID: PluginID("p"), category: .trash,
                        safetyScore: SafetyScore(90), recoverability: .manual, rationale: "")
        let r = ScanResult(findings: [a, b])
        #expect(r.totalReclaimable == ByteCount(500))       // allocated, not logical
        #expect(r.byCategory().first?.total == ByteCount(300)) // largest category first
    }

    @Test("byte formatting is deterministic")
    func formatting() {
        #expect(ByteCount(512).formatted == "512 B")
        #expect(ByteCount(1024).formatted == "1.0 KB")
        #expect(ByteCount(23 * 1024 * 1024 * 1024).formatted == "23.0 GB")
    }
}

@Suite("Domain: plan & report")
struct PlanReportTests {
    @Test("dry-run plan estimate ignores skips; report flags partial")
    func planReport() {
        let f = Finding(item: Item(id: ItemID("a"), title: "a", path: "/a",
                        evidence: Evidence(allocatedSize: 1000)),
                        pluginID: PluginID("p"), category: .trash,
                        safetyScore: SafetyScore(90), recoverability: .instant, rationale: "")
        let plan = CleanPlan(actions: [.init(finding: f, disposition: .stage)], dryRun: true)
        #expect(plan.estimatedReclaim == ByteCount(1000))

        var report = CleanReport(sessionID: SessionID("s"), dryRun: false)
        report.outcomes = [
            .init(itemID: ItemID("a"), path: "/a", status: .staged, reclaimed: ByteCount(1000)),
            .init(itemID: ItemID("b"), path: "/b", status: .failed, detail: "vanished"),
        ]
        #expect(report.totalReclaimed == ByteCount(1000))
        #expect(report.isPartial)
    }

    @Test("exit codes match the Constitution")
    func exitCodes() {
        #expect(CleanerExitCode.ok.rawValue == 0)
        #expect(CleanerExitCode.partial.rawValue == 3)
        #expect(CleanerExitCode.safety.rawValue == 8)
        #expect(CleanerExitCode.entitlement.rawValue == 11)
    }

    @Test("report → exit code mapping: safety wins over partial")
    func exitMapping() {
        func rep(_ statuses: [CleanReport.Outcome.Status]) -> CleanReport {
            var r = CleanReport(sessionID: SessionID("s"))
            r.outcomes = statuses.enumerated().map {
                .init(itemID: ItemID("\($0.offset)"), path: "/p", status: $0.element)
            }
            return r
        }
        #expect(rep([.staged, .staged]).resolvedExitCode == .ok)
        #expect(rep([.staged, .failed]).resolvedExitCode == .partial)
        #expect(rep([.staged, .blockedBySafety]).resolvedExitCode == .safety)
        // safety beats partial when both present
        #expect(rep([.failed, .blockedBySafety]).resolvedExitCode == .safety)
        #expect(ScanResult(findings: [], skipped: [.init(pluginID: PluginID("p"), reason: "x")])
                    .resolvedExitCode == .partial)
    }
}
