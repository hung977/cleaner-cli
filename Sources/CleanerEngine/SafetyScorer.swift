import Foundation
import CleanerCore

/// The weighted signal inputs a scorer combines into a SafetyScore (specs/22 §4.2). Each 0…1
/// signal is "how safe" along that axis (1 = safest). Booleans are hard modifiers.
public struct SafetySignals: Sendable {
    /// 1 = fully regenerated automatically; 0 = never regenerated.
    public var regenerability: Double
    /// 1 = contains no user-authored content; 0 = clearly user content.
    public var userAuthoredAbsence: Double
    public var recoverability: Recoverability
    /// 1 = we're certain this path is what we think it is.
    public var pathConfidence: Double
    /// 1 = not accessed recently (stale); 0 = active.
    public var recency: Double
    /// Currently open/locked/in use.
    public var inUse: Bool
    /// iCloud placeholder — must not be deleted.
    public var isDataless: Bool
    /// The engine already knows this is a protected path.
    public var isProtected: Bool

    public init(regenerability: Double, userAuthoredAbsence: Double,
                recoverability: Recoverability, pathConfidence: Double = 1,
                recency: Double = 1, inUse: Bool = false,
                isDataless: Bool = false, isProtected: Bool = false) {
        self.regenerability = regenerability
        self.userAuthoredAbsence = userAuthoredAbsence
        self.recoverability = recoverability
        self.pathConfidence = pathConfidence
        self.recency = recency
        self.inUse = inUse
        self.isDataless = isDataless
        self.isProtected = isProtected
    }
}

/// Deterministic, pure scorer (specs/22). `S_raw = 100 · Σ(wᵢ·sᵢ)`, then monotonic-downward
/// gates that can only *lower* the score, never raise it. Mirrors the hand-scores v0.1 plugins
/// assign, so it can replace them without changing behavior.
public struct SafetyScorer: Sendable {
    // Weights (sum to 1.0) — specs/22 §4.2.
    static let wRegen = 0.30, wAuthored = 0.25, wRecover = 0.15,
               wPath = 0.15, wRecency = 0.10, wLock = 0.05

    public init() {}

    private func recoverScore(_ r: Recoverability) -> Double {
        switch r {
        case .instant: return 1.0
        case .manual: return 0.7
        case .hard: return 0.4
        case .none: return 0.0
        }
    }

    public func score(_ s: SafetySignals) -> SafetyScore {
        let clamp: (Double) -> Double = { max(0, min(1, $0)) }
        let raw = 100 * (
            Self.wRegen * clamp(s.regenerability)
            + Self.wAuthored * clamp(s.userAuthoredAbsence)
            + Self.wRecover * recoverScore(s.recoverability)
            + Self.wPath * clamp(s.pathConfidence)
            + Self.wRecency * clamp(s.recency)
            + Self.wLock * (s.inUse ? 0 : 1)
        )
        var value = Int(raw.rounded())

        // Monotonic-downward gates — each can only lower the score.
        if s.isProtected { value = min(value, 0) }               // → dangerous
        if s.recoverability.forcesDangerous { value = min(value, 40) }
        if s.isDataless { value = min(value, 40) }               // never delete iCloud placeholders
        if s.inUse { value = min(value, 60) }

        return SafetyScore(value)
    }
}
