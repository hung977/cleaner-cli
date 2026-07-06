/// A 0–100 confidence that removing an item is harmless (Constitution Art. 4.2, specs/22).
///
/// Mapping to risk is fixed: `>=85 → safe`, `50…84 → medium`, `<50 → dangerous`.
public struct SafetyScore: Sendable, Hashable, Codable, Comparable {
    public let value: Int

    /// Clamped to 0...100.
    public init(_ value: Int) { self.value = min(100, max(0, value)) }

    public static func < (a: SafetyScore, b: SafetyScore) -> Bool { a.value < b.value }

    /// The risk band this score implies (Art. 4.2).
    public var impliedRisk: RiskLevel {
        switch value {
        case 85...100: return .safe
        case 50..<85: return .medium
        default: return .dangerous
        }
    }

    public static let maxSafe = SafetyScore(100)
    public static let minDangerous = SafetyScore(0)
}
