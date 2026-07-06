/// What the engine should do with a confirmed item (Constitution glossary, specs/20).
public enum Disposition: String, Sendable, Hashable, Codable, CaseIterable {
    /// Move to the tool-managed quarantine (recoverable). The default.
    case stage
    /// Move to the macOS Trash (recoverable until the user empties it).
    case trash
    /// Permanently delete (the only irreversible operation).
    case purge
    /// Do nothing.
    case skip

    public static let `default` = Disposition.stage

    /// Does this disposition destroy data irreversibly? Only `purge`.
    public var isDestructive: Bool { self == .purge }

    /// Can the action be undone by the tool afterwards?
    public var isRecoverable: Bool { self == .stage || self == .trash }
}
