import Foundation
import Darwin
import CleanerCore
import CleanerEngine
import CleanerPluginAPI
import CleanerReport

/// Thread-safe progress snapshot shared between the scan callback and the animator task.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0, total = 0
    private var bytes = ByteCount.zero
    func setTotal(_ t: Int) { lock.lock(); total = t; lock.unlock() }
    func set(_ d: Int, _ t: Int, _ b: ByteCount) { lock.lock(); done = d; total = t; bytes = b; lock.unlock() }
    var snapshot: (Int, Int, ByteCount) { lock.lock(); defer { lock.unlock() }; return (done, total, bytes) }
}

/// Runs a scan while showing a single-line spinner on stderr (plain, normal-CLI style), so the
/// tool never sits silent. The line clears when done; the caller prints the final result to
/// stdout. `live == false` for pipes/CI/--json.
func scanWithSpinner(_ rt: Runtime, plugins: [any CleanerPlugin], context: PluginContext,
                     live: Bool, color: Bool) async -> (ScanResult, String) {
    let box = ProgressBox()
    box.setTotal(plugins.count)
    let start = Date()
    let s = Style(enabled: color)
    let liveLine = LiveLine(enabled: live)

    let animator: Task<Void, Never>? = live ? Task {
        var i = 0
        while !Task.isCancelled {
            let (d, t, b) = box.snapshot
            let el = String(format: "%.1fs", Date().timeIntervalSince(start))
            liveLine.draw("  " + s.hex(0x7ECEC0, Spinner.frame(i)) + "  "
                          + s.hex(0x8B98A5, "scanning \(d)/\(max(t, 1)) · \(b.formatted) · \(el)"))
            i += 1
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        liveLine.clear()
    } : nil

    let result = await rt.scanEngine.scan(plugins: plugins, context: context,
                                          progress: { d, t, b in box.set(d, t, b) })
    animator?.cancel()
    await animator?.value
    return (result, String(format: "%.1fs", Date().timeIntervalSince(start)))
}

/// Whether to animate: stderr is a TTY and we're not emitting machine output.
func liveEnabled(json: Bool) -> Bool { isatty(fileno(stderr)) == 1 && !json }
