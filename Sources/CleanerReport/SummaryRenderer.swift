import Foundation
import CleanerCore

/// Renders clean, icon-free, columnar summaries in the spirit of `gh`/`docker`/`brew` (specs/26).
/// Risk is shown as a coloured word, not an emoji. Alignment is computed on raw (un-coloured)
/// strings so columns stay crisp; no-color mode degrades to plain aligned text.
public struct SummaryRenderer: Sendable {
    let style: Style
    let width: Int

    public init(useColor: Bool, width: Int = SummaryRenderer.terminalWidth()) {
        self.style = Style(enabled: useColor)
        self.width = max(56, min(width, 110))
    }

    // Column geometry (all ASCII, so alignment is exact).
    private var indent: String { "  " }
    private var riskW: Int { 6 }        // "safe" / "medium" / "danger"

    public func analyze(_ result: ScanResult, elapsed: String? = nil) -> String {
        var out: [String] = [""]
        if let elapsed {
            out.append(indent + style.gray("Scanned \(result.findings.count) source(s) in \(elapsed)"))
        }
        if result.findings.isEmpty {
            out.append("")
            out.append(indent + style.green("Nothing reclaimable") + style.gray(" — your disk is tidy."))
            return out.joined(separator: "\n") + "\n"
        }

        let sizeW = max(8, result.findings.map { $0.reclaimableSize.formatted.count }.max() ?? 8)
        let fixed = indent.count + 2 + riskW + 2 + sizeW + 2   // leading + gap + risk + gap + size + gap
        let titleW = max(14, min(34, (width - fixed) / 2))
        let rationaleW = max(10, width - fixed - titleW - 2)

        for group in result.byCategory() {
            out.append("")
            out.append(headerLine(group.category.displayName.uppercased(), group.total.formatted))
            out.append(indent + style.gray(String(repeating: "─", count: width - indent.count)))
            for f in group.findings.prefix(60) {
                let risk = style.padRight(riskWord(f.risk), riskW)
                let size = style.padLeft(f.reclaimableSize.formatted, sizeW)
                let title = style.padRight(style.truncate(f.item.title, titleW), titleW)
                let why = style.truncate(f.rationale, rationaleW)
                out.append(indent + "  " + riskColor(f.risk, risk) + "  " + style.bold(size)
                           + "  " + title + "  " + style.gray(why))
            }
            if group.findings.count > 60 {
                out.append(indent + "  " + style.gray("… and \(group.findings.count - 60) more"))
            }
        }
        for s in result.skipped {
            out.append(indent + style.yellow("skipped ") + "\(s.pluginID)" + style.gray("  \(s.reason)"))
        }
        out.append("")
        out.append(totalLine("Total reclaimable", result.totalReclaimable.formatted, .green))
        out.append("")
        return out.joined(separator: "\n")
    }

    public func clean(_ report: CleanReport) -> String {
        var out: [String] = [""]
        let verb = report.dryRun ? "Would reclaim" : "Reclaimed"
        out.append(totalLine(verb, report.totalReclaimed.formatted, report.dryRun ? .cyan : .green))
        let ok = report.succeeded.count, failed = report.failed.count, blocked = report.blocked.count
        var line = indent + style.gray("\(ok) item(s) " + (report.dryRun ? "would be processed" : "processed"))
        if failed > 0 { line += style.red("  ·  \(failed) failed") }
        if blocked > 0 { line += style.red("  ·  \(blocked) blocked by safety") }
        out.append(line)
        for o in (report.failed + report.blocked).prefix(10) {
            out.append(indent + "  " + style.red("×") + " "
                       + style.truncate(o.path, width - 10) + style.gray("  \(o.detail ?? o.status.rawValue)"))
        }
        if !report.dryRun && ok > 0 {
            out.append("")
            out.append(indent + style.gray("Undo with  ") + style.bold("cleaner staging restore \(report.sessionID.rawValue)"))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: pieces

    private enum Accent { case green, cyan }

    /// `  NAME .................................. SIZE` with a dim dotted leader.
    private func headerLine(_ name: String, _ size: String) -> String {
        let content = width - indent.count
        let leader = max(1, content - name.count - size.count - 2)
        return indent + style.bold(name) + " " + style.gray(String(repeating: "·", count: leader))
            + " " + style.bold(size)
    }

    /// `  Total reclaimable ......................... 10.8 GB`
    private func totalLine(_ label: String, _ value: String, _ accent: Accent) -> String {
        let content = width - indent.count
        let leader = max(1, content - label.count - value.count - 2)
        let coloured = accent == .green ? style.green(style.bold(value)) : style.cyan(style.bold(value))
        return indent + style.bold(label) + " " + style.gray(String(repeating: "·", count: leader))
            + " " + coloured
    }

    private func riskWord(_ r: RiskLevel) -> String {
        switch r {
        case .safe: return "safe"
        case .medium: return "medium"
        case .dangerous: return "danger"
        }
    }
    private func riskColor(_ r: RiskLevel, _ s: String) -> String {
        switch r {
        case .safe: return style.green(s)
        case .medium: return style.yellow(s)
        case .dangerous: return style.red(s)
        }
    }

    public static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
        return 80
    }
}
