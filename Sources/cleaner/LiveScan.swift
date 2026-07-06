import Foundation
import Darwin
import CleanerCore
import CleanerEngine
import CleanerPluginAPI
import CleanerReport

/// Thread-safe holder for the latest partial scan result, shared between the scan callback and
/// the animator task.
private final class ScanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = ScanResult()
    private var done = 0
    private var total = 0
    func setTotal(_ t: Int) { lock.lock(); total = t; lock.unlock() }
    func update(_ r: ScanResult, _ d: Int, _ t: Int) {
        lock.lock(); result = r; done = d; total = t; lock.unlock()
    }
    var snapshot: (ScanResult, Int, Int) {
        lock.lock(); defer { lock.unlock() }; return (result, done, total)
    }
}

private func elapsedString(since start: Date) -> String {
    String(format: "%.1fs", Date().timeIntervalSince(start))
}

/// Runs a scan while **live-rendering a growing bar chart** on stderr: the chart appears
/// immediately and fills in (bars grow, proportions rescale) as each source completes. The final
/// result is returned for the caller to print to stdout. `live == false` for pipes/CI/--json.
func scanWithSpinner(_ rt: Runtime, plugins: [any CleanerPlugin], context: PluginContext,
                     live: Bool, color: Bool) async -> (ScanResult, String) {
    let box = ScanBox()
    box.setTotal(plugins.count)
    let start = Date()
    let renderer = SummaryRenderer(useColor: color)

    let animator: Task<Void, Never>? = live ? Task {
        var lastLines = 0
        var tick = 0
        func redraw(clear: Bool) {
            var frame = ""
            if lastLines > 0 { frame += "\u{001B}[\(lastLines)A\u{001B}[0J" }  // up + clear-to-end
            if clear {
                FileHandle.standardError.write(Data(frame.utf8))
                lastLines = 0
                return
            }
            let (res, done, total) = box.snapshot
            var text = renderer.analyze(res, elapsed: elapsedString(since: start),
                                        scanning: (done, total, tick))
            while text.hasSuffix("\n") { text.removeLast() }
            frame += text
            FileHandle.standardError.write(Data(frame.utf8))
            lastLines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }
        while !Task.isCancelled {
            redraw(clear: false)
            tick += 1
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        redraw(clear: true)   // erase the live frame so the caller can print the final result
    } : nil

    let result = await rt.scanEngine.scan(plugins: plugins, context: context,
                                          onUpdate: { r, d, t in box.update(r, d, t) })
    animator?.cancel()
    await animator?.value
    return (result, elapsedString(since: start))
}

/// Whether to animate: stderr is a TTY and we're not emitting machine output.
func liveEnabled(json: Bool) -> Bool { isatty(fileno(stderr)) == 1 && !json }
