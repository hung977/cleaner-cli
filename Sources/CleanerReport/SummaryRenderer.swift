import Foundation
import CleanerCore

/// Renders polished, dark-terminal-friendly summaries (specs/25/26). Alignment is done on the
/// ASCII size column and box interiors (never across emoji) so it stays crisp regardless of
/// terminal emoji width. No-color mode degrades to clean plain text.
public struct SummaryRenderer: Sendable {
    let style: Style
    let width: Int

    public init(useColor: Bool, width: Int = SummaryRenderer.terminalWidth()) {
        self.style = Style(enabled: useColor)
        self.width = max(48, min(width, 100))
    }

    // MARK: analyze / preview

    public func analyze(_ result: ScanResult, elapsed: String? = nil) -> String {
        var out: [String] = [""]
        if let elapsed {
            out.append("  " + style.gray("Scanned \(result.findings.count) item(s) in \(elapsed)"))
        }
        if result.findings.isEmpty {
            out.append("")
            out.append("  " + style.green("✓") + " Nothing reclaimable — your disk is tidy.")
            return out.joined(separator: "\n")
        }

        let sizeW = max(8, result.findings.map { $0.reclaimableSize.formatted.count }.max() ?? 8)
        let titleW = max(14, min(30, width - sizeW - 22))
        let ruleW = min(width - 2, 62)

        for group in result.byCategory() {
            out.append("")
            out.append("  \(group.category.icon)  " + style.bold(group.category.displayName)
                       + "  " + style.gray("·") + "  " + style.bold(group.total.formatted))
            out.append("  " + style.gray(String(repeating: "─", count: ruleW)))
            for f in group.findings.prefix(60) {
                let size = style.padLeft(f.reclaimableSize.formatted, sizeW)
                let title = style.padRight(style.truncate(f.item.title, titleW), titleW)
                out.append("    \(riskGlyph(f.risk))  \(style.bold(size))  \(title)  "
                           + style.gray(f.rationale))
            }
            if group.findings.count > 60 {
                out.append("    " + style.gray("… and \(group.findings.count - 60) more"))
            }
        }
        for s in result.skipped {
            out.append("  " + style.yellow("⚠") + " skipped \(s.pluginID): " + style.gray(s.reason))
        }
        out.append("")
        out.append(contentsOf: totalBox("Total reclaimable", result.totalReclaimable.formatted))
        return out.joined(separator: "\n")
    }

    // MARK: clean result

    public func clean(_ report: CleanReport) -> String {
        var out: [String] = [""]
        let verb = report.dryRun ? "Would reclaim" : "Reclaimed"
        out.append(contentsOf: totalBox(verb, report.totalReclaimed.formatted,
                                        accent: report.dryRun ? .cyan : .green))
        let ok = report.succeeded.count, failed = report.failed.count, blocked = report.blocked.count
        var line = "  " + style.gray("\(ok) item(s) " + (report.dryRun ? "would be processed" : "processed"))
        if failed > 0 { line += style.red("  · \(failed) failed") }
        if blocked > 0 { line += style.red("  · \(blocked) blocked by safety") }
        out.append(line)
        for o in (report.failed + report.blocked).prefix(10) {
            out.append("    " + style.red("•") + " " + style.truncate(o.path, width - 8)
                       + style.gray("  \(o.detail ?? o.status.rawValue)"))
        }
        if !report.dryRun && ok > 0 {
            out.append("")
            out.append("  " + style.gray("Undo:  ") + "cleaner staging restore \(report.sessionID.rawValue)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: helpers

    private enum Accent { case green, cyan, none }

    private func riskGlyph(_ r: RiskLevel) -> String {
        switch r {
        case .safe: return style.green(r.icon)
        case .medium: return style.yellow(r.icon)
        case .dangerous: return style.red(r.icon)
        }
    }

    /// A rounded box: `╭───╮ / │ label      value │ / ╰───╯`. Interior is ASCII so it aligns.
    private func totalBox(_ label: String, _ value: String, accent: Accent = .green) -> [String] {
        let inner = min(width - 4, 52)
        let gap = max(1, inner - label.count - value.count - 2)
        let mid = "  " + label + String(repeating: " ", count: gap) + value + "  "
        let coloredValue: String = {
            switch accent {
            case .green: return style.green(style.bold(value))
            case .cyan: return style.cyan(style.bold(value))
            case .none: return style.bold(value)
            }
        }()
        let midColored = "  " + style.bold(label) + String(repeating: " ", count: gap)
            + coloredValue + "  "
        let top = "  " + style.gray("╭" + String(repeating: "─", count: mid.count) + "╮")
        let body = "  " + style.gray("│") + midColored + style.gray("│")
        let bot = "  " + style.gray("╰" + String(repeating: "─", count: mid.count) + "╯")
        return [top, body, bot]
    }

    /// Best-effort terminal width via ioctl, falling back to $COLUMNS then 80.
    public static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
        return 80
    }
}
