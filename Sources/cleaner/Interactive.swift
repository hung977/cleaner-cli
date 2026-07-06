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
/// q/esc cancel. Renders on the **alternate screen buffer** and repaints from the top each frame
/// (no cursor-arithmetic → never stacks/garbles, even on scroll or wrap). The terminal is always
/// restored on exit. Returns the chosen indices, or nil if cancelled. Requires a TTY.
enum MultiSelect {
    private static func emit(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

    static func run(title: String, items: [PickItem], style s: Style) -> [Int]? {
        guard isatty(fileno(stdin)) == 1, isatty(fileno(stderr)) == 1 else { return nil }

        // Raw mode: no echo, no line-buffering, no signal chars (so Ctrl-C is handled by us and
        // never leaves the terminal stuck). Restored unconditionally via defer.
        var orig = termios()
        tcgetattr(fileno(stdin), &orig)
        var raw = orig
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON) | UInt(ISIG) | UInt(IEXTEN))
        tcsetattr(fileno(stdin), TCSANOW, &raw)
        emit("\u{1B}[?1049h\u{1B}[?25l")   // enter alt screen + hide cursor
        defer {
            emit("\u{1B}[?25h\u{1B}[?1049l")   // show cursor + leave alt screen (restores scrollback)
            tcsetattr(fileno(stdin), TCSANOW, &orig)
        }

        var sel = items.map(\.selected)
        var cursor = 0
        let sizeW = items.map { $0.size.formatted.count }.max() ?? 8

        func draw() {
            let width = SummaryRenderer.terminalWidth()
            var lines: [String] = ["", "  " + s.hex(0xC6D2DC, title), ""]
            for (i, it) in items.enumerated() {
                let pointer = i == cursor ? s.hex(0x7ECEC0, "❯") : " "
                let box = sel[i] ? s.hex(0x8AC776, "[x]") : s.hex(0x5E7180, "[ ]")
                let tag: String
                switch it.risk {
                case .safe: tag = ""
                case .medium: tag = s.hex(0xD9A441, "  medium")
                case .dangerous: tag = s.hex(0xE5595C, "  danger")
                }
                let tagW = tag.isEmpty ? 0 : 8
                let nameMax = max(8, width - 8 - sizeW - tagW - 3)
                let name = it.label.count > nameMax ? String(it.label.prefix(nameMax - 1)) + "…" : it.label
                let pad = max(2, width - 8 - name.count - tagW - sizeW)
                let sizeStr = String(repeating: " ", count: max(0, sizeW - it.size.formatted.count)) + it.size.formatted
                let nameCol = i == cursor ? s.hex(0xE9F0F6, name) : s.hex(0xC6D2DC, name)
                lines.append("  \(pointer) \(box)  " + nameCol + tag
                             + String(repeating: " ", count: pad) + s.hex(0xE6EDF3, sizeStr))
            }
            let chosen = sel.filter { $0 }.count
            let total = zip(items, sel).filter { $0.1 }.map { $0.0.size }.total()
            lines.append("")
            lines.append("  " + s.hex(0x5E7180, "↑↓ move · space toggle · a all · enter clean · q cancel"))
            lines.append("  " + s.hex(0x8B98A5, "\(chosen) selected · \(total.formatted)"))
            // Home + clear-to-end, then paint from the top. No relative cursor math.
            emit("\u{1B}[H\u{1B}[0J" + lines.joined(separator: "\r\n"))
        }

        draw()
        var byte: UInt8 = 0
        while read(fileno(stdin), &byte, 1) == 1 {
            switch byte {
            case 0x1B:
                var b1: UInt8 = 0, b2: UInt8 = 0
                if read(fileno(stdin), &b1, 1) == 1, b1 == UInt8(ascii: "["),
                   read(fileno(stdin), &b2, 1) == 1 {
                    if b2 == UInt8(ascii: "A") { cursor = (cursor - 1 + items.count) % items.count }
                    else if b2 == UInt8(ascii: "B") { cursor = (cursor + 1) % items.count }
                } else { return nil }   // bare ESC = cancel
            case UInt8(ascii: "k"): cursor = (cursor - 1 + items.count) % items.count
            case UInt8(ascii: "j"): cursor = (cursor + 1) % items.count
            case UInt8(ascii: " "): sel[cursor].toggle()
            case UInt8(ascii: "a"), UInt8(ascii: "A"):
                let allOn = sel.allSatisfy { $0 }; for i in sel.indices { sel[i] = !allOn }
            case 0x0A, 0x0D: return sel.indices.filter { sel[$0] }
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03: return nil
            default: break
            }
            draw()
        }
        return nil
    }
}
