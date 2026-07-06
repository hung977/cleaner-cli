import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Executes a confirmed `CleanPlan` safely (specs/20). Plugins proposed; this disposes.
///
/// Per item: re-validate at execute time (TOCTOU) → re-check the ProtectedPathGuard →
/// measure actual on-disk size → dispose (stage/purge) → audit. Dry-run computes the identical
/// numbers with zero mutation (DM-9). Partial failure yields a report flagged `isPartial`
/// (→ exit 3); a safety block yields `blockedBySafety` (→ exit 8).
public struct CleanupEngine: Sendable {
    private let fs: FilesystemProviding
    private let guard_: ProtectedPathGuard
    private let staging: StagingManager
    private let audit: AuditLog
    private let clock: EngineClock

    public init(fs: FilesystemProviding, guard_: ProtectedPathGuard,
                staging: StagingManager, audit: AuditLog, clock: EngineClock) {
        self.fs = fs
        self.guard_ = guard_
        self.staging = staging
        self.audit = audit
        self.clock = clock
    }

    public func execute(_ plan: CleanPlan, session: SessionID,
                        allowedRoots: [String]) -> CleanReport {
        var report = CleanReport(sessionID: session, dryRun: plan.dryRun)

        // Delete deeper paths first so a parent never orphans a still-staged child.
        let ordered = plan.actions
            .filter { $0.disposition != .skip }
            .sorted { $0.finding.item.path.count > $1.finding.item.path.count }

        for action in ordered {
            report.outcomes.append(dispose(action, session: session, allowedRoots: allowedRoots,
                                            dryRun: plan.dryRun))
        }
        for action in plan.actions where action.disposition == .skip {
            report.outcomes.append(.init(itemID: action.id, path: action.finding.item.path,
                                         status: .skipped))
        }
        return report
    }

    private func dispose(_ action: CleanPlan.Action, session: SessionID,
                         allowedRoots: [String], dryRun: Bool) -> CleanReport.Outcome {
        let path = action.finding.item.path
        let itemID = action.id

        // 1. TOCTOU: the path may have vanished or changed since the scan.
        guard fs.exists(path) else {
            return .init(itemID: itemID, path: path, status: .failed,
                         detail: "path vanished before cleanup")
        }
        // 2. Safety re-validation — independent of the plugin (defense in depth).
        let decision = guard_.validateForDeletion(path, allowedRoots: allowedRoots)
        if case .blocked(let reason) = decision {
            try? audit.record(.init(ts: clock.timestamp(), session: session,
                                    action: "block", path: path, detail: reason))
            return .init(itemID: itemID, path: path, status: .blockedBySafety, detail: reason)
        }
        // 3. Measure actual on-disk size now (truthful reclaim).
        let actual = (try? fs.measure(path).allocatedSize) ?? action.finding.reclaimableSize

        // 4. Dry-run: report what *would* happen; mutate nothing (identical numbers).
        if dryRun {
            let wouldBe: CleanReport.Outcome.Status =
                action.disposition == .purge ? .purged : .staged
            return .init(itemID: itemID, path: path, status: wouldBe, reclaimed: actual)
        }

        // 5. Execute the disposition.
        do {
            switch action.disposition {
            case .stage, .trash:
                _ = try staging.stage(itemID: itemID, originalPath: path, size: actual,
                                      session: session, timestamp: clock.timestamp())
                try audit.record(.init(ts: clock.timestamp(), session: session,
                                       action: "stage", path: path))
                return .init(itemID: itemID, path: path, status: .staged, reclaimed: actual)
            case .purge:
                try fs.removeItem(path)
                try audit.record(.init(ts: clock.timestamp(), session: session,
                                       action: "purge", path: path))
                return .init(itemID: itemID, path: path, status: .purged, reclaimed: actual)
            case .skip:
                return .init(itemID: itemID, path: path, status: .skipped)
            }
        } catch {
            return .init(itemID: itemID, path: path, status: .failed, detail: "\(error)")
        }
    }
}
