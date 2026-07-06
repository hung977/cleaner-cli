import ArgumentParser
import Foundation
import CleanerCore
import CleanerPlatform
import CleanerReport

/// `cleaner optimize` — a read-only, guided overview: how much you can safely reclaim, the biggest
/// wins, and the exact next commands to run. Never cleans anything itself (specs/08).
struct Optimize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Guided overview: how much you can reclaim and what to run next.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let rt = Runtime(useColor: options.useColor)
        if let e = rt.configError { printErr("\(e)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let plugins = selectPlugins(rt.registry, include: options.include, exclude: options.exclude)
        let (raw, elapsed) = await scanWithSpinner(rt, plugins: plugins, context: rt.context(),
                                                   live: liveEnabled(json: options.json), color: options.useColor)
        let result = rt.applyConfig(raw)

        let safe = result.findings.filter { $0.risk == .safe }.map(\.reclaimableSize).total()
        let medium = result.findings.filter { $0.risk == .medium }.map(\.reclaimableSize).total()

        // Biggest sources (grouped by plugin).
        let names = rt.pluginNames()
        let top = Dictionary(grouping: result.findings, by: { $0.pluginID })
            .map { (id, fs) in (name: names[id] ?? id.rawValue, total: fs.map(\.reclaimableSize).total()) }
            .sorted { $0.total.bytes > $1.total.bytes }
            .prefix(5)

        if options.json {
            struct O: Encodable { let schemaVersion = 1; let command = "optimize"
                let safeReclaimable: Int64; let reviewReclaimable: Int64 }
            printOut(try ReportJSONEncode(O(safeReclaimable: safe.bytes, reviewReclaimable: medium.bytes)))
            return
        }

        let s = Style(enabled: options.useColor)
        let shell = ShellAdapter()
        printOut("")
        printOut("  " + s.hexBold(0xE9F0F6, "OPTIMIZE") + s.hex(0x5E7180, "   \(result.findings.count) source items · \(elapsed)"))
        printOut("")
        printOut("  You can reclaim " + s.hexBold(0x8AC776, safe.formatted) + s.hex(0x8B98A5, " safely")
                 + (medium.bytes > 0 ? s.hex(0x8B98A5, "  ·  ") + s.hexBold(0xD9A441, medium.formatted) + s.hex(0x8B98A5, " more with review") : ""))
        if !top.isEmpty {
            printOut("")
            printOut("  " + s.hex(0x6E7D8A, "BIGGEST WINS"))
            let sizeW = top.map { $0.total.formatted.count }.max() ?? 8
            for t in top {
                let size = String(repeating: " ", count: max(0, sizeW - t.total.formatted.count)) + t.total.formatted
                printOut("    " + s.hexBold(0xE6EDF3, size) + "   " + s.hex(0xC6D2DC, t.name))
            }
        }
        printOut("")
        printOut("  " + s.hex(0x6E7D8A, "NEXT STEPS"))
        func step(_ cmd: String, _ desc: String) {
            printOut("    " + s.hexBold(0x8AC776, s.padRight(cmd, 26)) + s.hex(0x8B98A5, desc))
        }
        if safe.bytes > 0 { step("cleaner clean", "stage \(safe.formatted) — recoverable") }
        step("cleaner large-files", "find big personal files")
        step("cleaner duplicates", "find duplicate files")
        if shell.available("docker") { step("cleaner docker", "reclaim Docker space") }
        if shell.available("brew") { step("cleaner brew", "clean old Homebrew versions") }
        printOut("")
    }
}
