import Foundation
import Darwin
import CleanerCore
import CleanerReport

/// One selectable row in the picker.
struct PickItem {
    let label: String
    let size: ByteCount
    let risk: RiskLevel
    var selected: Bool
}

/// A raw-mode checkbox multi-select (specs/25). ↑↓/jk move · space toggle · a all · enter confirm ·
/// q/esc cancel. Draws to stderr and erases itself on exit; the terminal is always restored.
/// Returns the chosen indices, or nil if the user cancelled. Requires a TTY.
enum MultiSelect {
    static func run(title: String, items: [PickItem], style s: Style) -> [Int]? {
        guard isatty(fileno(stdin)) == 1, isatty(fileno(stderr)) == 1 else { return nil }

        // Enter raw mode; guarantee restore.
        var orig = termios()
        tcgetattr(fileno(stdin), &orig)
        var raw = orig
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        tcsetattr(fileno(stdin), TCSANOW, &raw)
        write(2, "\u{1B}[?25l", 6)   // hide cursor
        defer {
            tcsetattr(fileno(stdin), TCSANOW, &orig)
            write(2, "\u{1B}[?25h", 6)   // show cursor
        }

        var sel = items.map(\.selected)
        var cursor = 0
        var lastLines = 0

        func draw() {
            var lines: [String] = []
            lines.append("  " + s.hex(0xC6D2DC, title))
            lines.append("")
            let sizeW = items.map { $0.size.formatted.count }.max() ?? 8
            let width = SummaryRenderer.terminalWidth()
            for (i, it) in items.enumerated() {
                let pointer = i == cursor ? s.hex(0x7ECEC0, "❯") : " "
                let box = sel[i] ? s.hex(0x8AC776, "[x]") : s.hex(0x5E7180, "[ ]")
                let tag: String = {
                    switch it.risk {
                    case .safe: return ""
                    case .medium: return s.hex(0xD9A441, "  medium")
                    case .dangerous: return s.hex(0xE5595C, "  danger")
                    }
                }()
                let nameMax = max(10, width - 8 - sizeW - 10)
                let name = it.label.count > nameMax ? String(it.label.prefix(nameMax - 1)) + "…" : it.label
                let pad = max(2, width - 8 - name.count - sizeW - (tag.isEmpty ? 0 : 8))
                let size = String(repeating: " ", count: max(0, sizeW - it.size.formatted.count)) + it.size.formatted
                let nameCol = i == cursor ? s.hex(0xE9F0F6, name) : s.hex(0xC6D2DC, name)
                lines.append("  \(pointer) \(box)  " + nameCol + tag + String(repeating: " ", count: pad) + s.hex(0xE6EDF3, size))
            }
            lines.append("")
            let chosen = sel.filter { $0 }.count
            let total = zip(items, sel).filter { $0.1 }.map { $0.0.size }.total()
            lines.append("  " + s.hex(0x5E7180, "space toggle · a all · enter clean · q cancel")
                         + s.hex(0x5E7180, "   —   \(chosen) selected · \(total.formatted)"))

            var frame = ""
            if lastLines > 0 { frame += "\u{1B}[\(lastLines)A\u{1B}[0J" }
            frame += lines.joined(separator: "\n")
            write(2, frame, strlen(frame))
            lastLines = lines.count - 1
        }

        func erase() {
            if lastLines > 0 { let e = "\u{1B}[\(lastLines)A\u{1B}[0J"; write(2, e, strlen(e)) }
        }

        draw()
        var byte: UInt8 = 0
        while read(fileno(stdin), &byte, 1) == 1 {
            switch byte {
            case 0x1B:   // ESC — could be an arrow sequence
                var seq: [UInt8] = [0, 0]
                if read(fileno(stdin), &seq[0], 1) == 1, seq[0] == UInt8(ascii: "["),
                   read(fileno(stdin), &seq[1], 1) == 1 {
                    if seq[1] == UInt8(ascii: "A") { cursor = (cursor - 1 + items.count) % items.count }
                    else if seq[1] == UInt8(ascii: "B") { cursor = (cursor + 1) % items.count }
                } else { erase(); return nil }   // bare ESC = cancel
            case UInt8(ascii: "k"): cursor = (cursor - 1 + items.count) % items.count
            case UInt8(ascii: "j"): cursor = (cursor + 1) % items.count
            case UInt8(ascii: " "): sel[cursor].toggle()
            case UInt8(ascii: "a"), UInt8(ascii: "A"):
                let allOn = sel.allSatisfy { $0 }; for i in sel.indices { sel[i] = !allOn }
            case 0x0A, 0x0D:   // enter
                erase(); return sel.indices.filter { sel[$0] }
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03:   // q / Ctrl-C
                erase(); return nil
            default: break
            }
            draw()
        }
        erase()
        return nil
    }
}
