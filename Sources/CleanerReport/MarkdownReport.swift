import Foundation
import CleanerCore

/// Renders a scan result as a Markdown storage report (specs/08 `report --md`). Deterministic
/// so it can be snapshot-tested.
public enum MarkdownReport {
    public static func render(_ result: ScanResult, generatedAt: String) -> String {
        var out: [String] = []
        out.append("# cleaner — Storage Report")
        out.append("")
        out.append("_Generated: \(generatedAt)_")
        out.append("")
        out.append("**Total reclaimable: \(result.totalReclaimable.formatted)**")
        out.append("")

        let groups = result.byCategory()
        if groups.isEmpty {
            out.append("_Nothing reclaimable found._")
            return out.joined(separator: "\n") + "\n"
        }

        // Summary table.
        out.append("| Category | Reclaimable | Items |")
        out.append("|---|---:|---:|")
        for g in groups {
            out.append("| \(g.category.displayName) | \(g.total.formatted) | \(g.findings.count) |")
        }
        out.append("")

        // Per-category detail.
        for g in groups {
            out.append("## \(g.category.icon) \(g.category.displayName) (\(g.total.formatted))")
            out.append("")
            for f in g.findings.prefix(50) {
                out.append("- \(f.risk.icon) **\(f.reclaimableSize.formatted)** — `\(f.item.title)`  \(f.rationale)")
            }
            if g.findings.count > 50 {
                out.append("- … and \(g.findings.count - 50) more")
            }
            out.append("")
        }
        if !result.skipped.isEmpty {
            out.append("## Skipped")
            for s in result.skipped { out.append("- `\(s.pluginID)`: \(s.reason)") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
