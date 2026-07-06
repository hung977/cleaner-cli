import ArgumentParser
import Foundation
import CleanerCore
import CleanerPlugins
import CleanerPluginAPI
import CleanerReport

// MARK: - shared helpers

/// Parse a human size like "100MB", "2GB", "500kb", or a plain byte count.
func parseSize(_ str: String) -> Int64? {
    let t = str.trimmingCharacters(in: .whitespaces).uppercased()
    let units: [(String, Int64)] = [("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10), ("B", 1)]
    for (suffix, mult) in units where t.hasSuffix(suffix) {
        let num = t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
        if let v = Double(num) { return Int64(v * Double(mult)) }
    }
    return Int64(t)
}

/// Resolve user-supplied paths (or defaults) to absolute directories that exist.
func resolveRoots(_ paths: [String], defaults: [String], home: String) -> [String] {
    let raw = paths.isEmpty ? defaults : paths
    return raw.map { p -> String in
        if p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        if p.hasPrefix("/") { return p }
        return FileManager.default.currentDirectoryPath + "/" + p
    }
}

/// Abbreviate an absolute path by replacing the home prefix with `~` (handles the
/// `/private` symlink so `/private/var/…` paths collapse too).
func abbreviate(_ path: String, home: String) -> String {
    let candidates = [home, (home as NSString).resolvingSymlinksInPath, "/private" + home]
    for h in candidates where !h.isEmpty && (path == h || path.hasPrefix(h + "/")) {
        return "~" + path.dropFirst(h.count)
    }
    return path
}

// MARK: - find (parent for detectors)

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "find",
        abstract: "Find large files or duplicates (read-only; nothing is deleted).",
        subcommands: [LargeFiles.self, Duplicates.self])
}

// MARK: - find large

struct LargeFiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "large",
        abstract: "Find the largest files under given folders (read-only; nothing is deleted).")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Minimum size, e.g. 100MB, 2GB.") var min: String = "100MB"
    @Option(help: "How many to show.") var top: Int = 20
    @Argument(help: "Folders to scan (default: Downloads, Desktop, Documents, Movies).")
    var paths: [String] = []

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        let minBytes = parseSize(min) ?? (100 << 20)
        let roots = resolveRoots(paths, defaults: ["Downloads", "Desktop", "Documents", "Movies"]
                                    .map { rt.home + "/" + $0 }, home: rt.home)
        let plugin = LargeFileFinder(roots: roots, minBytes: minBytes, top: top)
        let ctx = rt.context()
        let (findings, elapsed) = await withSpinner("scanning for large files",
            live: liveEnabled(json: options.json), color: options.useColor) {
            (try? await plugin.scan(ctx)) ?? []
        }

        if options.json {
            printOut(try ReportJSON.encode(ReportJSON.analyze(ScanResult(findings: findings))))
            return
        }
        let s = Style(enabled: options.useColor)
        let width = SummaryRenderer.terminalWidth()
        printOut("")
        printOut("  " + s.hexBold(0xE9F0F6, "LARGE FILES") + s.hex(0x5E7180, "  ≥ \(ByteCount(minBytes).formatted)"))
        printOut("  " + s.hex(0x5E7180, "\(findings.count) file(s) · \(elapsed)"))
        printOut("")
        if findings.isEmpty {
            printOut("  " + s.hex(0x8AC776, "No files that large.") + "\n"); return
        }
        let sizeW = findings.map { $0.reclaimableSize.formatted.count }.max() ?? 8
        for f in findings {
            let p = abbreviate(f.item.path, home: rt.home)
            let nameMax = max(10, width - 4 - sizeW - 2)
            let name = p.count > nameMax ? "…" + String(p.suffix(nameMax - 1)) : p
            let pad = max(2, width - 4 - name.count - sizeW)
            let size = String(repeating: " ", count: max(0, sizeW - f.reclaimableSize.formatted.count)) + f.reclaimableSize.formatted
            printOut("    " + s.hex(0xC6D2DC, name) + String(repeating: " ", count: pad) + s.hex(0xE6EDF3, size))
        }
        printOut("")
        printOut("  " + s.hex(0x8B98A5, "These are your files — remove manually if you don't need them.") + "\n")
    }
}

// MARK: - duplicates

struct Duplicates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dupes",
        abstract: "Find byte-identical duplicate files (read-only; nothing is deleted).")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Ignore files smaller than this, e.g. 1MB.") var min: String = "1MB"
    @Argument(help: "Folders to scan (default: Downloads, Desktop, Documents).")
    var paths: [String] = []

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        let minBytes = parseSize(min) ?? (1 << 20)
        let roots = resolveRoots(paths, defaults: ["Downloads", "Desktop", "Documents"]
                                    .map { rt.home + "/" + $0 }, home: rt.home)
        let plugin = DuplicateFinder(roots: roots, minBytes: minBytes)
        let ctx = rt.context()
        let (findings, elapsed) = await withSpinner("hashing duplicate candidates",
            live: liveEnabled(json: options.json), color: options.useColor) {
            (try? await plugin.scan(ctx)) ?? []
        }

        if options.json {
            printOut(try ReportJSON.encode(ReportJSON.analyze(ScanResult(findings: findings))))
            return
        }
        let s = Style(enabled: options.useColor)
        let width = SummaryRenderer.terminalWidth()
        let reclaimable = findings.map(\.reclaimableSize).total()
        printOut("")
        printOut("  " + s.hexBold(0xE9F0F6, "DUPLICATE FILES") + "   "
                 + s.hexBold(0x8AC776, reclaimable.formatted) + s.hex(0x5E7180, " reclaimable"))
        printOut("  " + s.hex(0x5E7180, "\(findings.count) group(s) · \(elapsed)"))
        printOut("")
        if findings.isEmpty {
            printOut("  " + s.hex(0x8AC776, "No duplicates found.") + "\n"); return
        }
        let sizeW = findings.map { $0.reclaimableSize.formatted.count }.max() ?? 8
        for f in findings.prefix(50) {
            let nameMax = max(10, width - 4 - sizeW - 2)
            let name = f.item.title.count > nameMax ? String(f.item.title.prefix(nameMax - 1)) + "…" : f.item.title
            let pad = max(2, width - 4 - name.count - sizeW)
            let size = String(repeating: " ", count: max(0, sizeW - f.reclaimableSize.formatted.count)) + f.reclaimableSize.formatted
            printOut("    " + s.hex(0xC6D2DC, name) + String(repeating: " ", count: pad) + s.hex(0xE6EDF3, size))
            for copy in f.item.allPaths.prefix(6) {
                printOut("        " + s.hex(0x5E7180, abbreviate(copy, home: rt.home)))
            }
        }
        printOut("")
        printOut("  " + s.hex(0x8B98A5, "Keep one of each — remove the extra copies manually.") + "\n")
    }
}
