import Testing
import Foundation
@testable import CleanerPlatform

@Suite("Platform: ShellAdapter (safe argv runner)")
struct ShellAdapterTests {
    let sh = ShellAdapter()

    @Test("runs a tool and captures stdout + exit code")
    func echo() {
        let r = sh.run("echo", ["hello", "world"], timeout: 5)
        #expect(r.ok)
        #expect(r.exitCode == 0)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test("a missing tool returns 127, not a crash")
    func missing() {
        let r = sh.run("definitely-not-a-real-tool-\(UUID().uuidString)", [], timeout: 5)
        #expect(!r.ok)
        #expect(r.exitCode == 127)
    }

    @Test("available() resolves real vs fake tools")
    func available() {
        #expect(sh.available("echo"))
        #expect(!sh.available("nope-\(UUID().uuidString)"))
    }

    @Test("arguments are argv, not shell — no injection")
    func noShellInjection() {
        // If this went through a shell, `; echo pwned` would run. With argv it's a literal arg.
        let r = sh.run("echo", ["safe ; echo pwned"], timeout: 5)
        #expect(r.stdout.contains("safe ; echo pwned"))
        #expect(!r.stdout.contains("pwned\n") || r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "safe ; echo pwned")
    }

    @Test("times out a long-running tool")
    func timeout() {
        let r = sh.run("sleep", ["5"], timeout: 0.3)
        #expect(r.timedOut)
        #expect(!r.ok)
    }
}
