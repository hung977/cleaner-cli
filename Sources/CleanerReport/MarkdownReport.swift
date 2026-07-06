import Foundation
import CleanerCore

/// Renders a scan result as a Markdown storage report (`cleaner --md`). Grouped by source like the
/// console (one row per plugin, e.g. "Xcode DerivedData (12)"), icon-free, with a risk column —
/// consistent with the interactive output. Deterministic so it can be snapshot-tested.
public enum MarkdownReport {
    public static func render(_ result: ScanResult, generatedAt: String,
                              names: [PluginID: String] = [:]) -> String {
        var out: [String] = [
            "# cleaner — Storage Report", "",
            "_Generated: \(generatedAt)_", "",
            "**Total reclaimable: \(result.totalReclaimable.formatted)**", "",
        ]

        let groups = result.byCategory()
        if groups.isEmpty {
            out.append("_Nothing reclaimable found._")
            return out.joined(separator: "\n") + "\n"
        }

        for g in groups {
            out.append("## \(g.category.displayName) — \(g.total.formatted)")
            out.append("")
            out.append("| Source | Reclaimable | Risk |")
            out.append("|---|---:|:--|")
            let sources = Dictionary(grouping: g.findings, by: { $0.pluginID })
                .map { (id, fs) -> (name: String, total: ByteCount, worst: RiskLevel, n: Int) in
                    (names[id] ?? id.rawValue, fs.map(\.reclaimableSize).total(),
                     fs.map(\.risk).max() ?? .safe, fs.count)
                }
                .sorted { $0.total.bytes > $1.total.bytes }
            for src in sources {
                let label = src.n > 1 ? "\(src.name) (\(src.n))" : src.name
                out.append("| \(label) | \(src.total.formatted) | \(riskWord(src.worst)) |")
            }
            out.append("")
        }

        if !result.skipped.isEmpty {
            out.append("## Skipped")
            out.append("")
            for s in result.skipped { out.append("- `\(s.pluginID)` — \(s.reason)") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func riskWord(_ r: RiskLevel) -> String {
        switch r { case .safe: return "safe"; case .medium: return "medium"; case .dangerous: return "danger" }
    }
}
