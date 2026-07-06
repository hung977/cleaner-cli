import Foundation

/// One invocation of the tool from process start to exit (Constitution glossary).
/// The UUID and clock are injected so CleanerCore stays deterministic.
public struct Session: Sendable, Codable, Identifiable {
    public let id: SessionID
    public let startedAt: Date

    public init(id: SessionID, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}
