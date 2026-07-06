import ArgumentParser
import Foundation
import CleanerCore
import CleanerPlatform
import CleanerReport

// MARK: - docker

/// `cleaner docker` — report Docker's reclaimable space and, on request, run ONLY safe prunes.
/// Docker manages its own storage (often inside a VM), so this can't use staging; it's a separate
/// command with its own confirmation. It NEVER prunes named/anonymous volumes or runs
/// `system prune` (data-loss risk, specs/plugins/plugin-docker.md).
struct Docker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show Docker reclaimable space; --prune runs safe prunes (never volumes).")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Prune dangling images, build cache and stopped containers (never volumes).")
    var prune: Bool = false
    @Flag(help: "Skip the confirmation prompt.") var yes: Bool = false

    func run() async throws {
        let s = Style(enabled: options.useColor)
        let shell = ShellAdapter()
        guard shell.available("docker") else {
            printOut("\n  " + s.hex(0x8B98A5, "Docker not found — nothing to do.") + "\n"); return
        }
        let df = shell.run("docker", ["system", "df", "--format", "{{json .}}"], timeout: 20)
        guard df.ok else {
            let hint = df.stderr.contains("Cannot connect") ? "Docker isn't running." : df.stderr
            printErr("  " + s.hex(0xD9A441, "Could not query Docker: ") + hint)
            throw ExitCode(CleanerExitCode.precondition.rawValue)
        }

        // Parse one JSON object per line: {Type, Size, Reclaimable}.
        struct Row: Decodable {
            let type: String, reclaimable: String
            enum CodingKeys: String, CodingKey { case type = "Type", reclaimable = "Reclaimable" }
        }
        let rows = df.stdout.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(Row.self, from: Data($0.utf8))
        }
        printOut("")
        printOut("  " + s.hexBold(0xE9F0F6, "DOCKER"))
        for r in rows {
            printOut("    " + s.hex(0xC6D2DC, s.padRight(r.type, 16)) + s.hex(0x5E7180, "reclaimable ")
                     + s.hex(0xE6EDF3, r.reclaimable))
        }
        printOut("  " + s.hex(0x5E7180, "named/anonymous volumes are never pruned (they hold data)"))

        guard prune else {
            printOut("  " + s.hex(0x8B98A5, "run ") + s.hexBold(0x8AC776, "cleaner docker --prune")
                     + s.hex(0x8B98A5, " to reclaim safely") + "\n")
            return
        }
        if !yes && !promptYesNo("\n  Prune dangling images, build cache and stopped containers?") {
            printErr("  aborted."); throw ExitCode(CleanerExitCode.cancelled.rawValue)
        }
        // Allow-list ONLY — no volume/system prune.
        let prunes: [([String], String)] = [
            (["image", "prune", "-f"], "dangling images"),
            (["builder", "prune", "-f"], "build cache"),
            (["container", "prune", "-f"], "stopped containers"),
        ]
        printOut("")
        for (args, label) in prunes {
            let r = shell.run("docker", args, timeout: 120)
            let freed = r.stdout.split(separator: "\n").first(where: { $0.contains("reclaimed") }) ?? ""
            printOut("    " + (r.ok ? s.green("✓") : s.red("×")) + " " + s.hex(0xC6D2DC, label)
                     + s.hex(0x5E7180, "  " + freed.trimmingCharacters(in: .whitespaces)))
        }
        printOut("")
    }
}

// MARK: - brew

/// `cleaner brew` — report what `brew cleanup` would remove (old versions + cache) and, on
/// request, run it. Homebrew manages the Cellar/cache itself, so this delegates to `brew cleanup`
/// rather than deleting files (specs/plugins/plugin-homebrew.md).
struct Brew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what `brew cleanup` would remove; --run performs it.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Actually run `brew cleanup`.") var run: Bool = false
    @Flag(help: "Skip the confirmation prompt.") var yes: Bool = false

    func run() async throws {
        let s = Style(enabled: options.useColor)
        let shell = ShellAdapter()
        guard shell.available("brew") else {
            printOut("\n  " + s.hex(0x8B98A5, "Homebrew not found — nothing to do.") + "\n"); return
        }
        printOut("")
        printOut("  " + s.hexBold(0xE9F0F6, "HOMEBREW"))
        if run {
            if !yes && !promptYesNo("  Run `brew cleanup -s` (removes old versions + cache)?") {
                printErr("  aborted."); throw ExitCode(CleanerExitCode.cancelled.rawValue)
            }
            let r = shell.run("brew", ["cleanup", "-s"], timeout: 180)
            printOut(indentLines(r.stdout.isEmpty ? "done." : r.stdout, s: s))
            if !r.ok { printErr(r.stderr); throw ExitCode(CleanerExitCode.partial.rawValue) }
        } else {
            let r = shell.run("brew", ["cleanup", "-ns"], timeout: 120)   // -n dry-run, -s scrub
            let body = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            printOut(body.isEmpty ? "    " + s.hex(0x8AC776, "Already clean.")
                                  : indentLines(body, s: s))
            printOut("  " + s.hex(0x8B98A5, "run ") + s.hexBold(0x8AC776, "cleaner brew --run")
                     + s.hex(0x8B98A5, " to perform cleanup"))
        }
        printOut("")
    }

    private func indentLines(_ text: String, s: Style) -> String {
        text.split(separator: "\n").map { "    " + s.hex(0x8B98A5, String($0)) }.joined(separator: "\n")
    }
}
