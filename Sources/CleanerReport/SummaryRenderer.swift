import Foundation
import CleanerCore

/// Colour tokens from the Claude Design "Cleaner Console" slate theme (0xRRGGBB).
enum Palette {
    static let textStrong: UInt32 = 0xE9F0F6
    static let text: UInt32 = 0xE6EDF3
    static let text2: UInt32 = 0xC6D2DC
    static let muted: UInt32 = 0x8B98A5
    static let muted2: UInt32 = 0x7D8B98
    static let dim: UInt32 = 0x5E7180
    static let faint: UInt32 = 0x4D5A66
    static let teal: UInt32 = 0x7ECEC0
    static let tealDeep: UInt32 = 0x5CBEAE
    static let green: UInt32 = 0x8AC776
    static let greenMid: UInt32 = 0x6BA25A
    static let greenDark: UInt32 = 0x5C7F4D
    static let greenDarker: UInt32 = 0x4D6A41
    static let amber: UInt32 = 0xD9A441
    static let red: UInt32 = 0xE5595C
    static let rule: UInt32 = 0x232C35
}

/// Renders the analyze view in the spirit of the Claude Design mock (specs/25/26): a slate,
/// icon-free bar chart. Category bars scale to the largest category (comparable across
/// categories); item bars scale within their own category. Risk is kept — bars are green for
/// safe, amber for medium, red for dangerous (the design flattened risk; we don't, it's core
/// safety). Alignment is computed on raw widths; no-color degrades to a clean monochrome chart.
public struct SummaryRenderer: Sendable {
    let s: Style
    let width: Int

    public init(useColor: Bool, width: Int = SummaryRenderer.terminalWidth()) {
        self.s = Style(enabled: useColor)
        self.width = max(58, min(width, 108))
    }

    private static let eighths = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    public func analyze(_ result: ScanResult, elapsed: String? = nil,
                        scanning: (done: Int, total: Int, frame: Int)? = nil) -> String {
        var out: [String] = [""]

        // Geometry.
        let sizeW = max(8, result.findings.map { $0.reclaimableSize.formatted.count }.max() ?? 8)
        let labelW = max(14, min(22, width / 3))
        let barW = max(10, min(28, width - 2 - labelW - 1 - 2 - sizeW))
        let gap = max(2, width - 2 - labelW - 1 - barW - sizeW)

        // Header.
        let total = result.totalReclaimable.formatted
        if let sc = scanning {
            let head = s.cyan(Spinner.frame(sc.frame)) + "  " + s.hexBold(Palette.textStrong, "SCANNING")
                + "  " + s.hex(Palette.dim, "\(sc.done)/\(sc.total)")
            out.append(justify("  " + head, rawLen: 2 + 1 + 2 + 8 + 2 + "\(sc.done)/\(sc.total)".count,
                               right: s.hexBold(Palette.green, total), rightRaw: total.count))
        } else {
            out.append(justify("  " + s.hexBold(Palette.textStrong, "DISK RECLAIMABLE"),
                               rawLen: 2 + 16, right: s.hexBold(Palette.green, total), rightRaw: total.count))
        }
        if let elapsed {
            out.append("  " + s.hex(Palette.dim, "\(result.findings.count) source(s) · \(elapsed)"))
        }

        if result.findings.isEmpty {
            out.append("")
            out.append("  " + (scanning == nil
                               ? s.hex(Palette.green, "Nothing reclaimable") + s.hex(Palette.dim, " — your disk is tidy.")
                               : s.hex(Palette.dim, "scanning…")))
            out.append("")
            return out.joined(separator: "\n")
        }

        let groups = result.byCategory()
        let globalMax = max(1, groups.map { $0.total.bytes }.max() ?? 1)

        for g in groups {
            out.append("")
            // Category row: name (teal, bold), category bar (teal→green gradient scaled to global max), total (green).
            out.append(row(nameRaw: pad(g.category.displayName, labelW), indent: 0,
                           nameColored: s.hexBold(Palette.teal, pad(g.category.displayName, labelW)),
                           bar: gradientBar(value: g.total.bytes, scale: globalMax, width: barW,
                                            from: Palette.tealDeep, to: Palette.green),
                           barW: barW, gap: gap,
                           sizeRaw: rpad(g.total.formatted, sizeW),
                           sizeColored: s.hexBold(Palette.green, rpad(g.total.formatted, sizeW))))
            for f in g.findings.prefix(40) {
                let name = pad(f.item.title, labelW - 2)
                out.append(row(nameRaw: "  " + name, indent: 0,
                               nameColored: "  " + s.hex(Palette.text2, name),
                               bar: solidBar(value: f.reclaimableSize.bytes, scale: g.total.bytes,
                                             width: barW, color: barColor(f)),
                               barW: barW, gap: gap,
                               sizeRaw: rpad(f.reclaimableSize.formatted, sizeW),
                               sizeColored: s.hex(Palette.text, rpad(f.reclaimableSize.formatted, sizeW))))
            }
            if g.findings.count > 40 {
                out.append("  " + s.hex(Palette.dim, "  … and \(g.findings.count - 40) more"))
            }
        }
        for sk in result.skipped {
            out.append("  " + s.hex(Palette.amber, "skipped ") + s.hex(Palette.muted2, "\(sk.pluginID)  \(sk.reason)"))
        }

        // Footer.
        out.append("")
        out.append("  " + s.hex(Palette.rule, String(repeating: "─", count: width - 2)))
        if scanning == nil {
            out.append("  " + s.hex(Palette.muted, "Total  ") + s.hexBold(Palette.textStrong, total)
                       + s.hex(Palette.faint, "  ·  ") + s.hex(Palette.muted2, "run ")
                       + s.hexBold(Palette.green, "cleaner clean") + s.hex(Palette.muted2, " to reclaim"))
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
        var line = "  " + s.hex(Palette.dim, "\(ok) item(s) " + (report.dryRun ? "would be processed" : "processed"))
        if failed > 0 { line += s.hex(Palette.red, "  ·  \(failed) failed") }
        if blocked > 0 { line += s.hex(Palette.red, "  ·  \(blocked) blocked by safety") }
        out.append(line)
        for o in (report.failed + report.blocked).prefix(10) {
            out.append("    " + s.hex(Palette.red, "×") + " " + s.truncate(o.path, width - 12)
                       + s.hex(Palette.dim, "  \(o.detail ?? o.status.rawValue)"))
        }
        if !report.dryRun && ok > 0 {
            out.append("")
            out.append("  " + s.hex(Palette.muted2, "Undo with  ")
                       + s.hexBold(Palette.teal, "cleaner staging restore \(report.sessionID.rawValue)"))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: row assembly

    private func row(nameRaw: String, indent: Int, nameColored: String, bar: String,
                     barW: Int, gap: Int, sizeRaw: String, sizeColored: String) -> String {
        // name(labelW) + space + bar(barW) + gap spaces + size(right)
        return "  " + nameColored + " " + bar + String(repeating: " ", count: gap) + sizeColored
    }

    /// Left title + right value on one full-width line (justify-between).
    private func justify(_ left: String, rawLen: Int, right: String, rightRaw: Int) -> String {
        let pad = max(1, width - rawLen - rightRaw)
        return left + String(repeating: " ", count: pad) + right
    }

    // MARK: bars (exactly `width` display cells, colour-coded)

    private func solidBar(value: Int64, scale: Int64, width: Int, color: UInt32) -> String {
        let (blocks, filled) = blocksString(value: value, scale: scale, width: width)
        return s.hex(color, blocks) + String(repeating: " ", count: width - filled)
    }

    private func gradientBar(value: Int64, scale: Int64, width: Int, from: UInt32, to: UInt32) -> String {
        let (_, filled) = blocksString(value: value, scale: scale, width: width)
        guard filled > 0 else { return String(repeating: " ", count: width) }
        var cells = ""
        for i in 0..<filled {
            let t = filled == 1 ? 1.0 : Double(i) / Double(filled - 1)
            cells += s.hex(lerp(from, to, t), "█")
        }
        return cells + String(repeating: " ", count: width - filled)
    }

    /// Returns (uncolored block string, number of cells filled 1..width).
    private func blocksString(value: Int64, scale: Int64, width: Int) -> (String, Int) {
        guard scale > 0, value > 0 else { return ("", 0) }
        let frac = min(Double(value) / Double(scale), 1.0) * Double(width)
        var full = Int(frac)
        var str = String(repeating: "█", count: min(full, width))
        if full < width {
            let rem = Int(((frac - Double(full)) * 8).rounded())
            if rem > 0 { str += Self.eighths[min(rem, 7)]; full += 1 }
            else if full == 0 { str += "▏"; full += 1 }   // minimum sliver for any non-zero
        }
        return (str, min(full, width))
    }

    /// Item bar colour: risk first (safe green / medium amber / danger red); within safe,
    /// darker green for smaller fractions (magnitude cue, matching the design).
    private func barColor(_ f: Finding) -> UInt32 {
        switch f.risk {
        case .medium: return Palette.amber
        case .dangerous: return Palette.red
        case .safe: return Palette.green
        }
    }

    private func lerp(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ x: UInt32, _ sh: UInt32) -> Double { Double((x >> sh) & 0xFF) }
        let r = ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t
        let g = ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t
        let bl = ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t
        return (UInt32(r.rounded()) << 16) | (UInt32(g.rounded()) << 8) | UInt32(bl.rounded())
    }

    // MARK: text helpers (raw, for alignment)

    private func pad(_ str: String, _ w: Int) -> String {
        let t = str.count > w ? String(str.prefix(w - 1)) + "…" : str
        return t + String(repeating: " ", count: max(0, w - t.count))
    }
    private func rpad(_ str: String, _ w: Int) -> String {
        str.count >= w ? str : String(repeating: " ", count: w - str.count) + str
    }

    public static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
        return 80
    }
}
