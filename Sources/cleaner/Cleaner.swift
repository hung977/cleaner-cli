import ArgumentParser
import Foundation
import Darwin
import CleanerCore
import CleanerEngine
import CleanerReport
import CleanerConfig

@main
struct Cleaner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleaner",
        abstract: "A safe, native macOS disk cleaner for developers.",
        version: "0.1.0-dev",
        subcommands: [Analyze.self, Clean.self, Staging.self, Doctor.self, Report.self,
                      LargeFiles.self, Duplicates.self, Docker.self, Brew.self,
                      Optimize.self, ProfileCmd.self]
    )
}

// MARK: - profile

struct ProfileCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile",
        abstract: "List saved profiles from config.yml.", subcommands: [ProfileList.self],
        defaultSubcommand: ProfileList.self)
}

struct ProfileList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list",
        abstract: "List saved profiles.")
    @OptionGroup var options: GlobalOptions
    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        if let e = rt.configError { printErr("\(e)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let s = Style(enabled: options.useColor)
        let profs = rt.config.profiles
        printOut("")
        if profs.isEmpty {
            printOut("  " + s.hex(0x8B98A5, "No profiles defined. Add a `profiles:` section to ~/.cleaner/config.yml.") + "\n")
            return
        }
        for name in profs.keys.sorted() {
            let p = profs[name]!
            var bits: [String] = []
            if !p.include.isEmpty { bits.append("include \(p.include.count)") }
            if !p.exclude.isEmpty { bits.append("exclude \(p.exclude.count)") }
            if p.risky { bits.append("risky") }
            printOut("  " + s.hexBold(0x7ECEC0, name) + s.hex(0x5E7180, "  " + (bits.isEmpty ? "all safe sources" : bits.joined(separator: " · "))))
        }
        printOut("\n  " + s.hex(0x8B98A5, "use with  ") + s.hexBold(0x8AC776, "cleaner clean --profile <name>") + "\n")
    }
}

// MARK: - Shared options & helpers

struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Increase output detail.")
    var verbose: Bool = false

    @Flag(help: "Emit machine-readable JSON to stdout.")
    var json: Bool = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color.")
    var noColor: Bool = false

    @Option(help: "Only run these plugins (comma-separated ids).")
    var include: String?

    @Option(help: "Skip these plugins (comma-separated ids).")
    var exclude: String?

    @Option(help: "Use a saved profile from config.yml.")
    var profile: String?

    /// Color only when a TTY, not disabled, and NO_COLOR unset.
    var useColor: Bool {
        if noColor { return false }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(fileno(stdout)) == 1
    }
}

func printOut(_ s: String) { print(s) }
func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Prompt for a yes/no on the TTY. Returns false if not interactive (safety-first).
func promptYesNo(_ question: String) -> Bool {
    guard isatty(fileno(stdin)) == 1 else { return false }
    FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
    guard let line = readLine(strippingNewline: true)?.lowercased() else { return false }
    return line == "y" || line == "yes"
}

// MARK: - analyze (US1)

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read-only scan: report reclaimable space by category. Never deletes.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        if let e = rt.configError { printErr("\(e)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let sel: (include: String?, exclude: String?, risky: Bool)
        do { sel = try resolveSelection(config: rt.config, profileName: options.profile,
                                        include: options.include, exclude: options.exclude) }
        catch { printErr("\(error)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let plugins = selectPlugins(rt.registry, include: sel.include, exclude: sel.exclude)
        let (raw, elapsed) = await scanWithSpinner(rt, plugins: plugins, context: rt.context(),
                                                   live: liveEnabled(json: options.json), color: options.useColor)
        let result = rt.applyConfig(raw)

        if options.json {
            printOut(try ReportJSON.encode(ReportJSON.analyze(result)))
        } else {
            printOut(rt.renderer.analyze(result, elapsed: elapsed,
                                         names: rt.pluginNames(), verbose: options.verbose))
        }
        let code = result.resolvedExitCode
        if code != .ok { throw ExitCode(code.rawValue) }
    }
}

// MARK: - clean (US2)

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan, preview, confirm, then reclaim to staging (recoverable).")
    @OptionGroup var options: GlobalOptions

    @Flag(help: "Compute everything but mutate nothing (identical numbers).")
    var dryRun: Bool = false

    @Flag(help: "Skip prompts: auto-clean Safe (🟢) items only, never Dangerous.")
    var yes: Bool = false

    @Flag(help: "Also include Medium (🟡) items (still requires confirmation).")
    var risky: Bool = false

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        if let e = rt.configError { printErr("\(e)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let sel: (include: String?, exclude: String?, risky: Bool)
        do { sel = try resolveSelection(config: rt.config, profileName: options.profile,
                                        include: options.include, exclude: options.exclude) }
        catch { printErr("\(error)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let plugins = selectPlugins(rt.registry, include: sel.include, exclude: sel.exclude)
        let ctx = rt.context()
        let (raw, elapsed) = await scanWithSpinner(rt, plugins: plugins, context: ctx,
                                                   live: liveEnabled(json: options.json), color: options.useColor)
        let result = rt.applyConfig(raw)

        // Selection: Safe by default; +Medium with --risky or a risky profile; never Dangerous.
        let includeMedium = risky || sel.risky
        var selected = result.findings.filter { $0.risk == .safe }
        if includeMedium { selected += result.findings.filter { $0.risk == .medium } }
        if yes { selected = selected.filter { $0.risk.isAutoCleanable } }

        if !options.json { printOut(rt.renderer.analyze(result, elapsed: elapsed,
                                                        names: rt.pluginNames(), verbose: options.verbose)) }

        if selected.isEmpty {
            if !options.json { printOut("\nNothing selected to clean.") }
            else { printOut(try ReportJSON.encode(ReportJSON.clean(
                CleanReport(sessionID: rt.session, dryRun: dryRun)))) }
            return
        }

        let total = selected.map(\.reclaimableSize).total()
        // Confirmation gate (skipped for --yes and --dry-run).
        if !yes && !dryRun {
            let q = "\nStage \(selected.count) item(s) to reclaim \(total.formatted)?"
            guard promptYesNo(q) else {
                printErr("Aborted — nothing was changed. (use --yes for non-interactive)")
                throw ExitCode(CleanerExitCode.cancelled.rawValue)
            }
        }

        let plan = CleanPlan(actions: selected.map { .init(finding: $0, disposition: $0.proposedDisposition) },
                             dryRun: dryRun)
        let report = rt.cleanupEngine.execute(plan, session: rt.session,
                                              allowedRoots: rt.allowedRoots(plugins, ctx))

        if options.json { printOut(try ReportJSON.encode(ReportJSON.clean(report))) }
        else { printOut("\n" + rt.renderer.clean(report)) }

        let code = report.resolvedExitCode
        if code != .ok { throw ExitCode(code.rawValue) }
    }
}

// MARK: - staging (US3 rollback)

struct Staging: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and restore items moved to staging (rollback).",
        subcommands: [StagingList.self, StagingRestore.self])
}

struct StagingList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list",
        abstract: "List staged sessions and items available to restore.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        let entries = try rt.staging.allEntries()
        if options.json {
            struct E: Encodable { let session, item, path: String; let bytes: Int64; let at: String }
            printOut(try ReportJSON.encode(entries.map {
                E(session: $0.sessionID.rawValue, item: $0.itemID.rawValue,
                  path: $0.originalPath, bytes: $0.allocatedSize.bytes, at: $0.stagedAt) }))
            return
        }
        if entries.isEmpty { printOut("Staging is empty — nothing to restore."); return }
        var lastSession = ""
        for e in entries {
            if e.sessionID.rawValue != lastSession {
                printOut("\n\(e.sessionID.rawValue)")
                lastSession = e.sessionID.rawValue
            }
            printOut("   \(e.allocatedSize.formatted)  \(e.originalPath)")
        }
        printOut("\nRestore a session with:  cleaner staging restore <session>")
    }
}

struct StagingRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore",
        abstract: "Restore a staged session (or item) to its original location.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Session id (or item id) to restore.") var id: String

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        let sessions = try rt.staging.listSessions()

        var results: [(String, Error?)] = []
        if sessions.contains(where: { $0.rawValue == id }) {
            results = try rt.staging.restoreSession(SessionID(id)).map { ($0.0.originalPath, $0.1) }
        } else if let entry = try rt.staging.allEntries().first(where: { $0.itemID.rawValue == id }) {
            do { try rt.staging.restore(entry); results = [(entry.originalPath, nil)] }
            catch { results = [(entry.originalPath, error)] }
        } else {
            printErr("No staged session or item with id '\(id)'.")
            throw ExitCode(CleanerExitCode.usage.rawValue)
        }

        let ok = results.filter { $0.1 == nil }.count
        for (path, err) in results {
            if let err { printOut("   ✗ \(path): \(err)") }
            else { printOut("   ✓ restored \(path)") }
        }
        printOut("\nRestored \(ok)/\(results.count) item(s).")
        if ok < results.count { throw ExitCode(CleanerExitCode.partial.rawValue) }
    }
}
