import Testing
@testable import CleanerEngine
import CleanerCore

@Suite("Engine: SafetyScorer (specs/22)")
struct SafetyScorerTests {
    let scorer = SafetyScorer()

    @Test("DerivedData-like signals score Safe (matches v0.1 hand-score band)")
    func derivedDataSafe() {
        let s = SafetySignals(regenerability: 1.0, userAuthoredAbsence: 1.0,
                              recoverability: .manual, pathConfidence: 1.0, recency: 1.0)
        let score = scorer.score(s)
        #expect(score.impliedRisk == .safe)      // ~95, safe band
        #expect(score.value >= 85)
    }

    @Test("Trash-like signals score Medium")
    func trashMedium() {
        // Already-deleted content: some user-authored possibility, manual recoverability.
        let s = SafetySignals(regenerability: 0.3, userAuthoredAbsence: 0.5,
                              recoverability: .manual, pathConfidence: 1.0, recency: 0.8)
        #expect(scorer.score(s).impliedRisk == .medium)
    }

    @Test("irreversible recoverability is gated to Dangerous regardless of other signals")
    func irreversibleDangerous() {
        let s = SafetySignals(regenerability: 1.0, userAuthoredAbsence: 1.0,
                              recoverability: .none, pathConfidence: 1.0, recency: 1.0)
        #expect(scorer.score(s).impliedRisk == .dangerous)
        #expect(scorer.score(s).value <= 40)
    }

    @Test("protected path is gated to 0 (Dangerous) no matter what")
    func protectedZero() {
        let s = SafetySignals(regenerability: 1.0, userAuthoredAbsence: 1.0,
                              recoverability: .instant, isProtected: true)
        #expect(scorer.score(s).value == 0)
    }

    @Test("dataless (iCloud) is gated to Dangerous")
    func datalessGated() {
        let s = SafetySignals(regenerability: 1.0, userAuthoredAbsence: 1.0,
                              recoverability: .manual, isDataless: true)
        #expect(scorer.score(s).impliedRisk == .dangerous)
    }

    @Test("gates only lower, never raise")
    func gatesMonotone() {
        let base = SafetySignals(regenerability: 0.9, userAuthoredAbsence: 0.9,
                                 recoverability: .manual)
        let gated = SafetySignals(regenerability: 0.9, userAuthoredAbsence: 0.9,
                                  recoverability: .manual, inUse: true)
        #expect(scorer.score(gated).value <= scorer.score(base).value)
    }
}
