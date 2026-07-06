import Foundation
import CleanerCore

/// Colour tokens (slate theme, 0xRRGGBB) — kept subtle for a plain, normal-CLI look.
enum Palette {
    static let textStrong: UInt32 = 0xE9F0F6
    static let text2Strong: UInt32 = 0xDBE4EC
    static let text: UInt32 = 0xC6D2DC
    static let muted: UInt32 = 0x8B98A5
    static let dim: UInt32 = 0x5E7180
    static let faint: UInt32 = 0x4D5A66
    static let teal: UInt32 = 0x7ECEC0
    static let green: UInt32 = 0x8AC776
    static let amber: UInt32 = 0xD9A441
    static let red: UInt32 = 0xE5595C
    static let rule: UInt32 = 0x2A333D
}

/// Plain, aligned list output — name on the left, size right-aligned, grouped by category
/// (specs/26). No bars, no boxes: just a clean log like `du`/`brew`. Risk is conveyed by the
/// size colour (safe = neutral, medium = amber, danger = red) so safety stays visible without
/// clutter. Alignment is measured on raw strings; no-color degrades to plain text.
public struct SummaryRenderer: Sendable {
    let s: Style
    let width: Int

    public init(useColor: Bool, width: Int = SummaryRenderer.terminalWidth()) {
        self.s = Style(enabled: useColor)
        self.width = max(40, min(width, 100))
    }

    public func analyze(_ result: ScanResult, elapsed: String? = nil,
                        scanning: (done: Int, total: Int, frame: Int)? = nil,
                        names: [PluginID: String] = [:], verbose: Bool = false) -> String {
        var out: [String] = [""]
        let sizeW = max(8, (result.findings.map { $0.reclaimableSize.formatted.count }.max() ?? 8))

        // Findings collapse to one "source" per plugin (e.g. 18 DerivedData folders → one
        // "Xcode DerivedData (18)"); `-v` expands them. Count sources for the header.
        let sourceCount = Set(result.findings.map { $0.pluginID }).count

        // Header.
        let total = result.totalReclaimable.formatted
        out.append(justify(left: s.hexBold(Palette.textStrong, "DISK RECLAIMABLE"), leftRaw: 16,
                           right: s.hexBold(Palette.green, total), rightRaw: total.count))
        if let elapsed {
            out.append("  " + s.hex(Palette.dim, "\(sourceCount) source(s) · \(elapsed)"))
        }

        if result.findings.isEmpty {
            out.append("")
            out.append("  " + (scanning == nil
                ? s.hex(Palette.green, "Nothing reclaimable") + s.hex(Palette.dim, " — your disk is tidy.")
                : s.hex(Palette.dim, "scanning…")))
            out.append("")
            return out.joined(separator: "\n")
        }

        for g in result.byCategory() {
            out.append("")
            out.append(line(name: g.category.displayName, indent: 2,
                            nameColor: Palette.teal, bold: true,
                            size: g.total.formatted, sizeW: sizeW, sizeColor: Palette.green, sizeBold: true))

            // Group this category's findings by plugin, largest first.
            let sources = Dictionary(grouping: g.findings, by: { $0.pluginID })
                .map { (id, fs) -> (name: String, total: ByteCount, worst: RiskLevel, findings: [Finding]) in
                    (names[id] ?? id.rawValue, fs.map(\.reclaimableSize).total(),
                     fs.map(\.risk).max() ?? .safe, fs)
                }
                .sorted { $0.total.bytes > $1.total.bytes }

            for src in sources {
                if verbose || src.findings.count == 1 {
                    // Expanded: a header per multi-item source, then each item.
                    if src.findings.count > 1 {
                        out.append(line(name: src.name, indent: 4, nameColor: Palette.text2Strong, bold: false,
                                        size: src.total.formatted, sizeW: sizeW,
                                        sizeColor: riskColor(src.worst), sizeBold: false))
                    }
                    for f in src.findings.prefix(200) {
                        out.append(line(name: f.item.title, indent: src.findings.count > 1 ? 6 : 4,
                                        nameColor: Palette.text, bold: false,
                                        size: f.reclaimableSize.formatted, sizeW: sizeW,
                                        sizeColor: riskColor(f.risk), sizeBold: false))
                    }
                } else {
                    // Collapsed: one line for the whole source with an item count.
                    out.append(line(name: "\(src.name) (\(src.findings.count))", indent: 4,
                                    nameColor: Palette.text, bold: false,
                                    size: src.total.formatted, sizeW: sizeW,
                                    sizeColor: riskColor(src.worst), sizeBold: false))
                }
            }
        }
        for sk in result.skipped {
            out.append("  " + s.hex(Palette.amber, "skipped ") + s.hex(Palette.muted, "\(sk.pluginID)  \(sk.reason)"))
        }

        out.append("")
        if scanning == nil {
            out.append("  " + s.hex(Palette.muted, "Total  ") + s.hexBold(Palette.textStrong, total)
                       + s.hex(Palette.faint, "   ·   ") + s.hex(Palette.muted, "run ")
                       + s.hexBold(Palette.green, "cleaner clean") + s.hex(Palette.muted, " to reclaim"))
        } else {
            out.append("  " + s.hex(Palette.muted, "discovered so far  ") + s.hexBold(Palette.textStrong, total))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    public func clean(_ report: CleanReport) -> String {
        var out: [String] = [""]
        let verb = report.dryRun ? "Would reclaim" : "Reclaimed"
        let color = report.dryRun ? Palette.teal : Palette.green
        out.append("  " + s.hex(Palette.muted, verb + "  ") + s.hexBold(color, report.totalReclaimed.formatted)
                   + (report.dryRun ? s.hex(Palette.dim, "   dry-run — nothing changed") : ""))
        let ok = report.succeeded.count, failed = report.failed.count, blocked = report.blocked.count
        var l = "  " + s.hex(Palette.dim, "\(ok) item(s) " + (report.dryRun ? "would be processed" : "processed"))
        if failed > 0 { l += s.hex(Palette.red, "  ·  \(failed) failed") }
        if blocked > 0 { l += s.hex(Palette.red, "  ·  \(blocked) blocked by safety") }
        out.append(l)
        for o in (report.failed + report.blocked).prefix(10) {
            out.append("    " + s.hex(Palette.red, "×") + " " + s.truncate(o.path, width - 12)
                       + s.hex(Palette.dim, "  \(o.detail ?? o.status.rawValue)"))
        }
        if !report.dryRun && ok > 0 {
            out.append("")
            out.append("  " + s.hex(Palette.muted, "Undo with  ")
                       + s.hexBold(Palette.teal, "cleaner staging restore \(report.sessionID.rawValue)"))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: helpers

    /// `  name<spaces>SIZE` — name left, size right-aligned to the terminal edge.
    private func line(name: String, indent: Int, nameColor: UInt32, bold: Bool,
                      size: String, sizeW: Int, sizeColor: UInt32, sizeBold: Bool) -> String {
        let nameMax = max(6, width - indent - sizeW - 2)
        let nm = name.count > nameMax ? String(name.prefix(nameMax - 1)) + "…" : name
        let pad = max(2, width - indent - nm.count - sizeW)
        let sizeStr = String(repeating: " ", count: max(0, sizeW - size.count)) + size
        return String(repeating: " ", count: indent)
            + s.hex(nameColor, nm, bold: bold)
            + String(repeating: " ", count: pad)
            + s.hex(sizeColor, sizeStr, bold: sizeBold)
    }

    private func justify(left: String, leftRaw: Int, right: String, rightRaw: Int) -> String {
        let pad = max(1, width - 2 - leftRaw - rightRaw)
        return "  " + left + String(repeating: " ", count: pad) + right
    }

    private func riskColor(_ r: RiskLevel) -> UInt32 {
        switch r { case .safe: return Palette.text; case .medium: return Palette.amber; case .dangerous: return Palette.red }
    }

    public static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
        return 80
    }
}
