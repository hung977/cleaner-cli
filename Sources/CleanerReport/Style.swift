import Foundation

/// ANSI styling primitives for the CLI (specs/25). All are no-ops when `enabled == false`
/// (respects `--no-color` / `NO_COLOR` / non-TTY), so callers never branch on color themselves.
public struct Style: Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }

    private func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
    }
    public func bold(_ s: String) -> String { wrap("1", s) }
    public func dim(_ s: String) -> String { wrap("2", s) }
    public func green(_ s: String) -> String { hex(0x8AC776, s) }
    public func yellow(_ s: String) -> String { hex(0xD9A441, s) }
    public func red(_ s: String) -> String { hex(0xE5595C, s) }
    public func cyan(_ s: String) -> String { hex(0x7ECEC0, s) }
    public func gray(_ s: String) -> String { hex(0x7D8B98, s) }

    // MARK: 24-bit truecolor (to match the Claude Design slate/teal/green palette exactly)

    /// Foreground colour from a 0xRRGGBB hex, optionally bold.
    public func hex(_ rgb: UInt32, _ s: String, bold: Bool = false) -> String {
        guard enabled else { return s }
        let r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF
        let lead = bold ? "1;" : ""
        return "\u{001B}[\(lead)38;2;\(r);\(g);\(b)m\(s)\u{001B}[0m"
    }
    public func hexBold(_ rgb: UInt32, _ s: String) -> String { hex(rgb, s, bold: true) }

    /// Fixed-width, correctly padded regardless of ANSI (padding measured on the raw string).
    public func padLeft(_ s: String, _ width: Int) -> String {
        let n = s.count
        return n >= width ? s : String(repeating: " ", count: width - n) + s
    }
    public func padRight(_ s: String, _ width: Int) -> String {
        let n = s.count
        return n >= width ? s : s + String(repeating: " ", count: width - n)
    }
    /// Truncate with an ellipsis to at most `width` display columns.
    public func truncate(_ s: String, _ width: Int) -> String {
        guard s.count > width, width > 1 else { return s }
        return String(s.prefix(width - 1)) + "…"
    }
}
