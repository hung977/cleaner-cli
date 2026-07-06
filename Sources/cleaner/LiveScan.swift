import Foundation
import Darwin
import CleanerCore
import CleanerEngine
import CleanerPluginAPI
import CleanerReport

/// Thread-safe progress snapshot shared between the scan callback and the animator task.
private final class ScanProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0, total = 0
    private var bytes = ByteCount.zero
    func set(_ d: Int, _ t: Int, _ b: ByteCount) {
        lock.lock(); done = d; total = t; bytes = b; lock.unlock()
    }
    var snapshot: (Int, Int, ByteCount) {
        lock.lock(); defer { lock.unlock() }; return (done, total, bytes)
    }
}

/// Runs a scan while animating a live spinner on stderr, so the tool never sits silent.
/// Returns the result plus a human elapsed string. `live` should be false for pipes/CI/--json.
func scanWithSpinner(_ rt: Runtime, plugins: [any CleanerPlugin], context: PluginContext,
                     live: Bool, color: Bool) async -> (ScanResult, String) {
    let box = ScanProgressBox()
    let liveLine = LiveLine(enabled: live)
    let style = Style(enabled: color)
    let start = Date()

    let animator: Task<Void, Never>? = live ? Task {
        var i = 0
        while !Task.isCancelled {
            let (d, t, b) = box.snapshot
            let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))
            let msg = "  " + style.cyan(Spinner.frame(i)) + "  Scanning \(d)/\(max(t, 1)) sources"
                + style.gray("  ·  \(b.formatted) found  ·  \(elapsed)")
            liveLine.draw(msg)
            i += 1
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
    } : nil

    let result = await rt.scanEngine.scan(plugins: plugins, context: context) { d, t, b in
        box.set(d, t, b)
    }
    animator?.cancel()
    liveLine.clear()
    return (result, String(format: "%.1fs", Date().timeIntervalSince(start)))
}

/// Whether to animate: stderr is a TTY and we're not emitting machine output.
func liveEnabled(json: Bool) -> Bool { isatty(fileno(stderr)) == 1 && !json }
