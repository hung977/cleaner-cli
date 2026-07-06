/// How dangerous it is to remove an item (Constitution Art. 4.1, specs/22).
public enum RiskLevel: String, Sendable, Hashable, Codable, Comparable, CaseIterable {
    /// 🟢 Regenerated automatically; no user data; loss is invisible.
    case safe
    /// 🟡 Regenerated but costs time (re-download, re-index, re-build).
    case medium
    /// 🔴 Could contain irreplaceable data or break tools if wrong.
    case dangerous

    public var icon: String {
        switch self {
        case .safe: return "🟢"
        case .medium: return "🟡"
        case .dangerous: return "🔴"
        }
    }

    public var label: String {
        switch self {
        case .safe: return "Safe"
        case .medium: return "Medium"
        case .dangerous: return "Dangerous"
        }
    }

    private var order: Int {
        switch self {
        case .safe: return 0
        case .medium: return 1
        case .dangerous: return 2
        }
    }

    /// Ordered least → most dangerous, so `max()` finds the riskiest item in a group.
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.order < b.order }

    /// Is this item pre-selected by default in `clean`? Only Safe items are (Art. 4.1).
    public var isPreselected: Bool { self == .safe }

    /// May this item ever be auto-cleaned under `--yes`? Never for Dangerous (SR: Art. 4.1).
    public var isAutoCleanable: Bool { self == .safe }
}
