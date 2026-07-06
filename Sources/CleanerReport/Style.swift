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
    public func green(_ s: String) -> String { wrap("32", s) }
    public func yellow(_ s: String) -> String { wrap("33", s) }
    public func red(_ s: String) -> String { wrap("31", s) }
    public func cyan(_ s: String) -> String { wrap("36", s) }
    public func gray(_ s: String) -> String { wrap("90", s) }

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
