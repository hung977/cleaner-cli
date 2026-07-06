import Foundation
import CleanerCore

/// Renders human-readable, dark-terminal-friendly summaries for the linear v0.1 TUI (specs/25,26).
/// Full-screen interactive TUI is deferred to v0.5; this is honest, quiet, scriptable output.
public struct SummaryRenderer: Sendable {
    public let useColor: Bool
    public init(useColor: Bool) { self.useColor = useColor }

    // Minimal ANSI palette (respects --no-color / NO_COLOR by disabling).
    private func c(_ code: String, _ s: String) -> String {
        useColor ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
    }
    private func dim(_ s: String) -> String { c("2", s) }
    private func bold(_ s: String) -> String { c("1", s) }

    private func riskTag(_ r: RiskLevel) -> String {
        switch r {
        case .safe: return c("32", r.icon)       // green
        case .medium: return c("33", r.icon)     // yellow
        case .dangerous: return c("31", r.icon)  // red
        }
    }

    /// The analyze / preview view: categories with per-item lines and a grand total.
    public func analyze(_ result: ScanResult) -> String {
        var out: [String] = []
        if result.findings.isEmpty {
            out.append(dim("Nothing reclaimable found. Your disk is already tidy. 🎉"))
        }
        for group in result.byCategory() {
            out.append("")
            out.append("\(group.category.icon)  \(bold(group.category.displayName))   "
                       + bold(group.total.formatted))
            for f in group.findings.prefix(50) {
                let size = f.reclaimableSize.formatted.leftPadded(to: 9)
                out.append("   \(riskTag(f.risk)) \(size)  \(f.item.title)  \(dim(f.rationale))")
            }
            if group.findings.count > 50 {
                out.append(dim("   … and \(group.findings.count - 50) more"))
            }
        }
        for s in result.skipped {
            out.append(dim("⚠  skipped \(s.pluginID): \(s.reason)"))
        }
        out.append("")
        out.append(bold("Total reclaimable: \(result.totalReclaimable.formatted)"))
        return out.joined(separator: "\n")
    }

    /// The post-clean summary.
    public func clean(_ report: CleanReport) -> String {
        var out: [String] = []
        let verb = report.dryRun ? "Would reclaim" : "Reclaimed"
        out.append(bold("\(verb) \(report.totalReclaimed.formatted)")
                   + (report.dryRun ? dim("  (dry-run — nothing was changed)")
                                    : dim("  (staged, recoverable)")))
        let ok = report.succeeded.count, failed = report.failed.count, blocked = report.blocked.count
        out.append("\(ok) item(s) processed"
                   + (failed > 0 ? c("31", ", \(failed) failed") : "")
                   + (blocked > 0 ? c("31", ", \(blocked) blocked by safety") : ""))
        for o in report.failed + report.blocked {
            out.append(dim("   • \(o.path): \(o.detail ?? o.status.rawValue)"))
        }
        if !report.dryRun && ok > 0 {
            out.append(dim("Undo:  cleaner staging restore \(report.sessionID.rawValue)"))
        }
        return out.joined(separator: "\n")
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
