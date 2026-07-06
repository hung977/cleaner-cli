import Foundation

/// The result of executing a `CleanPlan` — the truthful record of what happened (specs/20).
public struct CleanReport: Sendable, Codable {
    public struct Outcome: Sendable, Codable, Identifiable {
        public enum Status: String, Sendable, Codable {
            case staged, trashed, purged, skipped, failed, blockedBySafety
        }
        public let itemID: ItemID
        public let path: String
        public let status: Status
        public let reclaimed: ByteCount    // actual, measured post-action
        public let detail: String?         // failure/skip reason if any
        public var id: ItemID { itemID }

        public init(itemID: ItemID, path: String, status: Status,
                    reclaimed: ByteCount = .zero, detail: String? = nil) {
            self.itemID = itemID
            self.path = path
            self.status = status
            self.reclaimed = reclaimed
            self.detail = detail
        }
    }

    public let sessionID: SessionID
    public var outcomes: [Outcome]
    public var dryRun: Bool

    public init(sessionID: SessionID, outcomes: [Outcome] = [], dryRun: Bool = false) {
        self.sessionID = sessionID
        self.outcomes = outcomes
        self.dryRun = dryRun
    }

    /// Actual reclaimed total (sum of successful outcomes).
    public var totalReclaimed: ByteCount { outcomes.map(\.reclaimed).total() }

    public var failed: [Outcome] { outcomes.filter { $0.status == .failed } }
    public var blocked: [Outcome] { outcomes.filter { $0.status == .blockedBySafety } }
    public var succeeded: [Outcome] {
        outcomes.filter { [.staged, .trashed, .purged].contains($0.status) }
    }

    /// True if some items failed/were blocked but others succeeded (→ exit code 3).
    public var isPartial: Bool { !failed.isEmpty || !blocked.isEmpty }
}
