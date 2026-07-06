/// A confirmed set of actions the cleanup engine will execute (specs/20).
///
/// Built from a `ScanResult` after selection + confirmation. Each entry pairs a finding with
/// the disposition the user actually approved. A plan is what dry-run and real-run share.
public struct CleanPlan: Sendable, Codable {
    public struct Action: Sendable, Codable, Identifiable {
        public let finding: Finding
        public let disposition: Disposition
        public var id: ItemID { finding.id }
        public init(finding: Finding, disposition: Disposition) {
            self.finding = finding
            self.disposition = disposition
        }
    }

    public var actions: [Action]
    /// If true, compute everything but mutate nothing (identical numbers — DM-9).
    public var dryRun: Bool

    public init(actions: [Action] = [], dryRun: Bool = false) {
        self.actions = actions
        self.dryRun = dryRun
    }

    /// Estimated reclaim if every non-skip action succeeds.
    public var estimatedReclaim: ByteCount {
        actions
            .filter { $0.disposition != .skip }
            .map { $0.finding.reclaimableSize }
            .total()
    }

    public var isEmpty: Bool { actions.allSatisfy { $0.disposition == .skip } }
}
