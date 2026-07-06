/// How recoverable an item is after removal (Constitution Art. 4.3).
public enum Recoverability: String, Sendable, Hashable, Codable, CaseIterable {
    /// Staged; one-command rollback.
    case instant
    /// Re-downloadable / re-buildable by the user.
    case manual
    /// External source needed (e.g. re-clone).
    case hard
    /// Irreversible — forces a `dangerous` risk classification.
    case none

    public var label: String {
        switch self {
        case .instant: return "instant (staged)"
        case .manual: return "manual (re-obtainable)"
        case .hard: return "hard (external source)"
        case .none: return "none (irreversible)"
        }
    }

    /// `none` recoverability caps the item at `dangerous` regardless of score (Art. 4.3).
    public var forcesDangerous: Bool { self == .none }
}
