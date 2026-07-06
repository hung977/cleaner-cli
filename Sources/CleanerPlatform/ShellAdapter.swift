import Foundation

/// Result of running an external tool.
public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public var ok: Bool { exitCode == 0 && !timedOut }

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs external tools (docker, brew, xcrun…) that have no stable native API. Injected so
/// plugins/commands never spawn processes directly (testability + a single audited chokepoint).
public protocol ShellRunning: Sendable {
    /// Is `tool` available on this machine?
    func available(_ tool: String) -> Bool
    /// Run `tool args…`. `args` is passed as an argv array — NEVER interpolated into a shell —
    /// so there is no command-injection surface (spec 36 §shell). Bounded by `timeout` seconds.
    func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> ShellResult
}

/// Concrete adapter built on Foundation `Process`. No shell is ever invoked: we resolve the
/// tool to an absolute path and exec it with an argument vector. Output is captured; a watchdog
/// terminates the process if it exceeds the timeout.
public struct ShellAdapter: ShellRunning {
    public init() {}

    // Common locations searched in addition to $PATH (Docker/Homebrew/Xcode tools live here).
    private static let extraDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Resolve a bare tool name to an absolute executable path (or nil).
    public func resolve(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs + Self.extraDirs {
            let candidate = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func available(_ tool: String) -> Bool { resolve(tool) != nil }

    public func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) -> ShellResult {
        guard let exe = resolve(tool) else {
            return ShellResult(exitCode: 127, stdout: "", stderr: "\(tool): not found", timedOut: false)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)   // exact executable, no shell
        proc.arguments = args                             // argv — not a parsed string
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Minimal, predictable environment; keep PATH/HOME so tools locate their config.
        var env = ProcessInfo.processInfo.environment
        env["CLICOLOR"] = "0"
        proc.environment = env

        do { try proc.run() } catch {
            return ShellResult(exitCode: 126, stdout: "", stderr: "cannot launch \(tool): \(error)", timedOut: false)
        }

        // Watchdog: terminate if it runs past the timeout.
        let timedOut = LockedBool()
        let watchdog = DispatchWorkItem {
            if proc.isRunning { timedOut.set(true); proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // readDataToEndOfFile unblocks when the child closes the pipe (i.e. exits).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        return ShellResult(
            exitCode: proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut.get())
    }
}

/// Tiny thread-safe bool for the watchdog.
private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
