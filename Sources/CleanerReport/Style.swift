import Foundation

/// ANSI styling primitives for the CLI (specs/25). All are no-ops when `enabled == false`
/// (respects `--no-color` / `NO_COLOR` / non-TTY), so callers never branch on color themselves.
public struct Style: Sendable {
    public let enabled: Bool
    /// True when the terminal supports 24-bit colour (COLORTERM=truecolor/24bit, e.g. iTerm2,
    /// VS Code, Ghostty). Apple Terminal does NOT — it mis-parses `38;2;…` and eats characters,
    /// so we emit 256-colour there instead.
    public let truecolor: Bool

    public init(enabled: Bool, truecolor: Bool = Style.detectTruecolor()) {
        self.enabled = enabled
        self.truecolor = truecolor
    }

    public static func detectTruecolor() -> Bool {
        let ct = ProcessInfo.processInfo.environment["COLORTERM"]?.lowercased() ?? ""
        return ct == "truecolor" || ct == "24bit"
    }

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

    /// Foreground colour from a 0xRRGGBB hex, optionally bold. Emits 24-bit on capable terminals,
    /// else the nearest xterm-256 colour (safe on Apple Terminal).
    public func hex(_ rgb: UInt32, _ s: String, bold: Bool = false) -> String {
        guard enabled else { return s }
        let r = Int((rgb >> 16) & 0xFF), g = Int((rgb >> 8) & 0xFF), b = Int(rgb & 0xFF)
        let color = truecolor ? "38;2;\(r);\(g);\(b)" : "38;5;\(Self.xterm256(r, g, b))"
        let lead = bold ? "1;" : ""
        return "\u{001B}[\(lead)\(color)m\(s)\u{001B}[0m"
    }

    /// Nearest xterm-256 index for an RGB triple (6×6×6 cube + grayscale ramp).
    static func xterm256(_ r: Int, _ g: Int, _ b: Int) -> Int {
        if r == g, g == b {                                  // grayscale
            if r < 8 { return 16 }
            if r > 248 { return 231 }
            return 232 + Int((Double(r) - 8) / 247 * 24)
        }
        func c(_ v: Int) -> Int { Int((Double(v) / 255 * 5).rounded()) }
        return 16 + 36 * c(r) + 6 * c(g) + c(b)
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
