import Foundation
import CleanerCore

/// Bar-chart summary: every source gets a proportional bar so the biggest space hogs are obvious
/// at a glance (specs/26). Icon-free; risk is conveyed by bar colour + a word on non-safe rows.
/// Alignment is computed on raw strings; no-color mode degrades to a clean monochrome chart.
public struct SummaryRenderer: Sendable {
    let style: Style
    let width: Int

    public init(useColor: Bool, width: Int = SummaryRenderer.terminalWidth()) {
        self.style = Style(enabled: useColor)
        self.width = max(56, min(width, 110))
    }

    private static let eighths = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    public func analyze(_ result: ScanResult, elapsed: String? = nil) -> String {
        var out: [String] = [""]
        // Header row.
        out.append(header("DISK RECLAIMABLE", result.totalReclaimable.formatted))
        if let elapsed {
            out.append("  " + style.gray("\(result.findings.count) source(s) · \(elapsed)"))
        }
        if result.findings.isEmpty {
            out.append("")
            out.append("  " + style.green("Nothing reclaimable") + style.gray(" — your disk is tidy."))
            return out.joined(separator: "\n") + "\n"
        }

        let groups = result.byCategory()
        // Global scale = the largest category total, so bars are comparable everywhere.
        let scale = max(1, groups.map { $0.total.bytes }.max() ?? 1)

        // Column geometry.
        let sizeW = max(8, result.findings.map { $0.reclaimableSize.formatted.count }.max() ?? 8)
        let labelW = max(12, min(20, (width - 2 - sizeW - 6) / 2))
        let barW = max(10, min(28, width - 2 - labelW - 1 - 2 - sizeW))

        for group in groups {
            out.append("")
            out.append(row(label: group.category.displayName, indent: 2, labelW: labelW,
                           value: group.total.bytes, scale: scale, barW: barW,
                           sizeText: group.total.formatted, sizeW: sizeW,
                           barColor: .accent, bold: true, tag: nil))
            for f in group.findings.prefix(40) {
                out.append(row(label: f.item.title, indent: 4, labelW: labelW,
                               value: f.reclaimableSize.bytes, scale: scale, barW: barW,
                               sizeText: f.reclaimableSize.formatted, sizeW: sizeW,
                               barColor: .risk(f.risk), bold: false,
                               tag: f.risk == .safe ? nil : riskWord(f.risk)))
            }
            if group.findings.count > 40 {
                out.append("      " + style.gray("… and \(group.findings.count - 40) more"))
            }
        }
        for s in result.skipped {
            out.append("  " + style.yellow("skipped ") + "\(s.pluginID)" + style.gray("  \(s.reason)"))
        }
        out.append("")
        out.append("  " + style.bold("Total  " + result.totalReclaimable.formatted)
                   + style.gray("  ·  run ") + style.bold("cleaner clean") + style.gray(" to reclaim"))
        out.append("")
        return out.joined(separator: "\n")
    }

    public func clean(_ report: CleanReport) -> String {
        var out: [String] = [""]
        let verb = report.dryRun ? "Would reclaim" : "Reclaimed"
        let val = report.dryRun ? style.cyan(style.bold(report.totalReclaimed.formatted))
                                : style.green(style.bold(report.totalReclaimed.formatted))
        out.append("  " + style.bold(verb) + "  " + val
                   + (report.dryRun ? style.gray("  (dry-run — nothing changed)") : ""))
        let ok = report.succeeded.count, failed = report.failed.count, blocked = report.blocked.count
        var line = "  " + style.gray("\(ok) item(s) " + (report.dryRun ? "would be processed" : "processed"))
        if failed > 0 { line += style.red("  ·  \(failed) failed") }
        if blocked > 0 { line += style.red("  ·  \(blocked) blocked by safety") }
        out.append(line)
        for o in (report.failed + report.blocked).prefix(10) {
            out.append("    " + style.red("×") + " " + style.truncate(o.path, width - 12)
                       + style.gray("  \(o.detail ?? o.status.rawValue)"))
        }
        if !report.dryRun && ok > 0 {
            out.append("")
            out.append("  " + style.gray("Undo with  ")
                       + style.bold("cleaner staging restore \(report.sessionID.rawValue)"))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: pieces

    private enum BarColor { case accent; case risk(RiskLevel) }

    private func header(_ title: String, _ total: String) -> String {
        let content = width - 2
        let pad = max(1, content - title.count - total.count)
        return "  " + style.bold(title) + String(repeating: " ", count: pad) + style.bold(total)
    }

    private func row(label: String, indent: Int, labelW: Int, value: Int64, scale: Int64,
                     barW: Int, sizeText: String, sizeW: Int, barColor: BarColor,
                     bold: Bool, tag: String?) -> String {
        let effLabelW = labelW - (indent - 2)
        let name = style.padRight(style.truncate(label, effLabelW), effLabelW)
        let labelStr = bold ? style.bold(name) : name
        let rawBar = bar(value: value, scale: scale, width: barW)
        let coloredBar: String = {
            switch barColor {
            case .accent: return style.cyan(rawBar)
            case .risk(let r): return riskColor(r, rawBar)
            }
        }()
        let size = style.padLeft(sizeText, sizeW)
        let tagStr = tag.map { "  " + riskWord2Color($0) } ?? ""
        return String(repeating: " ", count: indent) + labelStr + " " + coloredBar
            + "  " + style.bold(size) + tagStr
    }

    /// A proportional bar of `width` cells using 1/8-block resolution; ≥▏ for any non-zero value.
    private func bar(value: Int64, scale: Int64, width: Int) -> String {
        guard scale > 0, value > 0 else { return String(repeating: " ", count: width) }
        let frac = min(Double(value) / Double(scale), 1.0) * Double(width)
        let full = Int(frac)
        var s = String(repeating: "█", count: min(full, width))
        var used = min(full, width)
        if used < width {
            let rem = Int(((frac - Double(full)) * 8).rounded())
            if rem > 0 { s += Self.eighths[min(rem, 7)]; used += 1 }
            else if used == 0 { s += "▏"; used += 1 }   // minimum visible sliver
        }
        if used < width { s += String(repeating: " ", count: width - used) }
        return s
    }

    private func riskWord(_ r: RiskLevel) -> String {
        switch r { case .safe: return "safe"; case .medium: return "medium"; case .dangerous: return "danger" }
    }
    private func riskColor(_ r: RiskLevel, _ s: String) -> String {
        switch r { case .safe: return style.green(s); case .medium: return style.yellow(s); case .dangerous: return style.red(s) }
    }
    private func riskWord2Color(_ word: String) -> String {
        switch word { case "medium": return style.yellow(word); case "danger": return style.red(word); default: return style.gray(word) }
    }

    public static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
        return 80
    }
}
