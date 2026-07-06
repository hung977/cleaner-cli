import ArgumentParser
import CleanerCore

// Root CLI command. Subcommand bodies are stubbed in this v0.1 scaffold (Task #1);
// `analyze`, `clean`, and `staging` are implemented in Tasks #11–13.
// Command surface & flags follow specs/08-command-reference.md.

@main
struct Cleaner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleaner",
        abstract: "A safe, native macOS disk cleaner for developers.",
        version: "0.1.0-dev",
        subcommands: [Analyze.self, Clean.self, Staging.self],
        defaultSubcommand: nil
    )
}

/// Flags shared by scanning/cleaning commands (subset for v0.1).
struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Increase output detail.")
    var verbose: Bool = false

    @Flag(help: "Emit machine-readable JSON to stdout.")
    var json: Bool = false

    @Flag(help: "Disable ANSI color.")
    var noColor: Bool = false

    @Option(help: "Only run these plugins (comma-separated ids).")
    var include: String?

    @Option(help: "Skip these plugins (comma-separated ids).")
    var exclude: String?
}

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read-only scan: report reclaimable space by category. Never deletes."
    )
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        // Implemented in Task #11.
        throw CleanerExit.notYetImplemented("analyze")
    }
}

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan, preview, confirm, then reclaim to staging (recoverable)."
    )
    @OptionGroup var options: GlobalOptions

    @Flag(help: "Compute everything but mutate nothing (identical numbers).")
    var dryRun: Bool = false

    @Flag(help: "Skip prompts: auto-clean Safe (🟢) items only, never Dangerous.")
    var yes: Bool = false

    func run() async throws {
        // Implemented in Task #12.
        throw CleanerExit.notYetImplemented("clean")
    }
}

struct Staging: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and restore items moved to staging (rollback).",
        subcommands: [StagingList.self, StagingRestore.self]
    )
}

struct StagingList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list",
        abstract: "List staged sessions and items available to restore.")
    func run() async throws { throw CleanerExit.notYetImplemented("staging list") }
}

struct StagingRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore",
        abstract: "Restore a staged session/item to its original location.")
    @Argument(help: "Session or item id to restore.") var id: String
    func run() async throws { throw CleanerExit.notYetImplemented("staging restore") }
}

/// Minimal typed exit until the real error taxonomy (spec 27) lands.
enum CleanerExit: Error, CustomStringConvertible {
    case notYetImplemented(String)
    var description: String {
        switch self {
        case .notYetImplemented(let what):
            return "`\(what)` is not implemented yet in this v0.1 scaffold."
        }
    }
}
