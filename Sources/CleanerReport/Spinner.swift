import Foundation

/// Braille spinner frames + a helper to draw/clear a single live status line on stderr (specs/25).
/// Used to show progress *while* work happens, so the tool never sits silent.
public enum Spinner {
    public static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    public static func frame(_ i: Int) -> String { frames[(i % frames.count + frames.count) % frames.count] }
}

/// Writes an in-place status line to stderr (carriage-return + clear-line), and can erase it.
/// A no-op when not attached to a TTY (so pipes/CI stay clean).
public struct LiveLine: Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }

    public func draw(_ text: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("\r\u{001B}[2K" + text).utf8))
    }
    public func clear() {
        guard enabled else { return }
        FileHandle.standardError.write(Data("\r\u{001B}[2K".utf8))
    }
}
