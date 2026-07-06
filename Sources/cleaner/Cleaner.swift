import ArgumentParser
import Foundation
import Darwin
import CleanerCore
import CleanerEngine
import CleanerReport
import CleanerConfig
import CleanerPlatform

@main
struct Cleaner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleaner",
        abstract: "Reclaim disk space safely — scan, pick what to clean, done (recoverable).",
        discussion: """
        Run `cleaner` to scan and interactively clean. Nothing is deleted without your \
        confirmation, and everything is recoverable with `cleaner undo`.
        """,
        version: "0.5.0",
        subcommands: [Undo.self, Find.self, Docker.self, Brew.self, Doctor.self, ProfileCmd.self])

    @OptionGroup var options: GlobalOptions
    @Flag(name: .long, help: "Preview only — scan and show, clean nothing.") var dryRun = false
    @Flag(name: .long, help: "Clean Safe items without prompting (automation).") var yes = false
    @Flag(name: .long, help: "Emit a Markdown report (implies preview).") var md = false

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        if let e = rt.configError { printErr("\(e)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let selc: (include: String?, exclude: String?)
        do { selc = try resolveSelection(config: rt.config, profileName: options.profile,
                                         include: options.include, exclude: options.exclude) }
        catch { printErr("\(error)"); throw ExitCode(CleanerExitCode.config.rawValue) }

        let plugins = selectPlugins(rt.registry, include: selc.include, exclude: selc.exclude)
        let ctx = rt.context()
        let (raw, elapsed) = await scanWithSpinner(rt, plugins: plugins, context: ctx,
                                                   live: liveEnabled(json: options.json), color: options.useColor)
        let result = rt.applyConfig(raw)
        let s = Style(enabled: options.useColor)

        // ── Machine output ──────────────────────────────────────────────
        if options.json {
            printOut(try ReportJSON.encode(ReportJSON.analyze(result))); return
        }
        if md {
            printOut(MarkdownReport.render(result, generatedAt: rt.clock.timestamp(),
                                           names: rt.pluginNames())); return
        }

        // ── Preview (--dry-run): show + suggest next steps, act on nothing ─
        if dryRun {
            printOut(rt.renderer.analyze(result, elapsed: elapsed, names: rt.pluginNames(), verbose: options.verbose))
            printNextSteps(s, result: result)
            if !result.skipped.isEmpty { throw ExitCode(CleanerExitCode.partial.rawValue) }
            return
        }

        // Show the summary, then let the user clean everything or pick each source.
        let names = rt.pluginNames()
        printOut(rt.renderer.analyze(result, elapsed: elapsed, names: names, verbose: options.verbose))

        // Group findings into sources (one per plugin) for per-source selection.
        let sources = Dictionary(grouping: result.findings, by: { $0.pluginID })
            .map { (id, fs) -> (name: String, total: ByteCount, findings: [Finding]) in
                (names[id] ?? id.rawValue, fs.map(\.reclaimableSize).total(), fs)
            }
            .sorted { $0.total.bytes > $1.total.bytes }

        var selected: [Finding]
        if yes {
            selected = result.findings                      // automation: clean everything found
        } else if isatty(fileno(stdin)) == 1 {
            switch prompt3("\n  Clean all " + s.hexBold(0x8AC776, result.totalReclaimable.formatted) + "?") {
            case .all:
                selected = result.findings
            case .cancel:
                printErr("  Cancelled — nothing was changed.")
                throw ExitCode(CleanerExitCode.cancelled.rawValue)
            case .select:
                printOut("")
                selected = []
                for src in sources {
                    let label = src.findings.count > 1 ? "\(src.name) (\(src.findings.count))" : src.name
                    let row = "    " + s.hex(0xC6D2DC, s.padRight(s.truncate(label, 32), 34))
                        + s.hex(0xE6EDF3, s.padLeft(src.total.formatted, 9))
                    if promptYesNo(row + "  clean?", defaultYes: false) { selected += src.findings }
                }
                if selected.isEmpty { printOut("\n  " + s.hex(0x8B98A5, "Nothing selected.") + "\n"); return }
            }
        } else {
            printErr("  Not a terminal — run with " + s.hexBold(0x8AC776, "--yes") + " to clean all.")
            throw ExitCode(CleanerExitCode.cancelled.rawValue)
        }

        let plan = CleanPlan(actions: selected.map { .init(finding: $0, disposition: $0.proposedDisposition) })
        let report = rt.cleanupEngine.execute(plan, session: rt.session,
                                              allowedRoots: rt.allowedRoots(plugins, ctx))
        printOut(rt.renderer.clean(report))
        let code = report.resolvedExitCode
        if code != .ok { throw ExitCode(code.rawValue) }
    }
}

// MARK: - shared options & helpers

struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "More detail (expand grouped sources).")
    var verbose: Bool = false
    @Flag(help: "Emit machine-readable JSON to stdout.")
    var json: Bool = false
    @Flag(name: .customLong("no-color"), help: "Disable ANSI color.")
    var noColor: Bool = false
    @Option(help: "Only these plugins (comma-separated ids).")
    var include: String?
    @Option(help: "Skip these plugins (comma-separated ids).")
    var exclude: String?
    @Option(help: "Use a saved profile from config.yml.")
    var profile: String?

    var useColor: Bool {
        if noColor { return false }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(fileno(stdout)) == 1
    }
}

func printOut(_ s: String) { print(s) }
func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Three-way choice for the clean prompt.
enum CleanChoice { case all, select, cancel }
func prompt3(_ question: String) -> CleanChoice {
    guard isatty(fileno(stdin)) == 1 else { return .cancel }
    FileHandle.standardError.write(Data("\(question) [Y = all · s = select each · n = cancel] ".utf8))
    let line = (readLine(strippingNewline: true) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    switch line {
    case "", "y", "yes", "a", "all": return .all
    case "s", "select", "p", "pick": return .select
    default: return .cancel
    }
}

func promptYesNo(_ question: String, defaultYes: Bool = false) -> Bool {
    guard isatty(fileno(stdin)) == 1 else { return defaultYes }
    FileHandle.standardError.write(Data("\(question) \(defaultYes ? "[Y/n]" : "[y/N]") ".utf8))
    guard let line = readLine(strippingNewline: true)?.lowercased() else { return defaultYes }
    if line.isEmpty { return defaultYes }
    return line == "y" || line == "yes"
}

/// The `optimize`-style suggestions, shown under a preview.
func printNextSteps(_ s: Style, result: ScanResult) {
    let shell = ShellAdapter()
    printOut("")
    printOut("  " + s.hex(0x6E7D8A, "NEXT STEPS"))
    func step(_ cmd: String, _ desc: String) {
        printOut("    " + s.hexBold(0x8AC776, s.padRight(cmd, 22)) + s.hex(0x8B98A5, desc))
    }
    if result.totalReclaimable.bytes > 0 { step("cleaner", "pick & reclaim \(result.totalReclaimable.formatted)") }
    step("cleaner find large", "biggest personal files")
    step("cleaner find dupes", "duplicate files")
    if shell.available("docker") { step("cleaner docker", "reclaim Docker space") }
    if shell.available("brew") { step("cleaner brew", "clean old Homebrew versions") }
    printOut("")
}

// MARK: - undo (rollback; replaces `staging`)

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore the last clean — or a specific session — from staging.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "List what can be restored instead of restoring.") var list: Bool = false
    @Argument(help: "Session id to restore (default: the most recent).") var id: String?

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        let s = Style(enabled: options.useColor)
        let sessions = try rt.staging.listSessions()

        if list {
            let entries = try rt.staging.allEntries()
            if options.json {
                struct E: Encodable { let session, item, path: String; let bytes: Int64; let at: String }
                printOut(try ReportJSON.encode(entries.map {
                    E(session: $0.sessionID.rawValue, item: $0.itemID.rawValue,
                      path: $0.originalPath, bytes: $0.allocatedSize.bytes, at: $0.stagedAt) }))
                return
            }
            printOut("")
            if entries.isEmpty { printOut("  " + s.hex(0x8B98A5, "Nothing to undo.") + "\n"); return }
            var last = ""
            for e in entries {
                if e.sessionID.rawValue != last { printOut("  " + s.hexBold(0x7ECEC0, e.sessionID.rawValue)); last = e.sessionID.rawValue }
                printOut("    " + s.hex(0xE6EDF3, e.allocatedSize.formatted) + "  "
                         + s.hex(0xC6D2DC, abbreviate(e.originalPath, home: rt.home)))
            }
            printOut("")
            return
        }

        guard let target = id ?? sessions.last?.rawValue else {
            printOut("\n  " + s.hex(0x8B98A5, "Nothing to undo.") + "\n"); return
        }
        guard sessions.contains(where: { $0.rawValue == target }) else {
            printErr("No staged session '\(target)'. Try: cleaner undo --list")
            throw ExitCode(CleanerExitCode.usage.rawValue)
        }
        let results = try rt.staging.restoreSession(SessionID(target))
        let ok = results.filter { $0.1 == nil }.count
        printOut("")
        for (entry, err) in results {
            let path = abbreviate(entry.originalPath, home: rt.home)
            if let err { printOut("    " + s.hex(0xE5595C, "×") + " \(path): \(err)") }
            else { printOut("    " + s.hex(0x8AC776, "✓") + " " + s.hex(0xC6D2DC, "restored \(path)")) }
        }
        printOut("\n  " + s.hexBold(0xE9F0F6, "Restored \(ok)/\(results.count) item(s).") + "\n")
        if ok < results.count { throw ExitCode(CleanerExitCode.partial.rawValue) }
    }
}

// MARK: - profile (advanced, hidden from main help)

struct ProfileCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile",
        abstract: "List saved profiles from config.yml.", shouldDisplay: false,
        subcommands: [ProfileList.self], defaultSubcommand: ProfileList.self)
}

struct ProfileList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved profiles.")
    @OptionGroup var options: GlobalOptions
    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        if let e = rt.configError { printErr("\(e)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let s = Style(enabled: options.useColor)
        let profs = rt.config.profiles
        printOut("")
        if profs.isEmpty {
            printOut("  " + s.hex(0x8B98A5, "No profiles. Add a `profiles:` section to ~/.cleaner/config.yml.") + "\n"); return
        }
        for name in profs.keys.sorted() {
            let p = profs[name]!
            var bits: [String] = []
            if !p.include.isEmpty { bits.append("include \(p.include.count)") }
            if !p.exclude.isEmpty { bits.append("exclude \(p.exclude.count)") }
            printOut("  " + s.hexBold(0x7ECEC0, name) + s.hex(0x5E7180, "  " + (bits.isEmpty ? "all safe" : bits.joined(separator: " · "))))
        }
        printOut("\n  " + s.hex(0x8B98A5, "use with  ") + s.hexBold(0x8AC776, "cleaner --profile <name>") + "\n")
    }
}
