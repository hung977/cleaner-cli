import ArgumentParser
import Foundation
import CleanerCore

/// A single health check outcome.
struct HealthCheck: Encodable {
    enum Status: String, Encodable { case ok, warn, critical }
    let name: String
    let status: Status
    let detail: String
}

/// `cleaner doctor` — environment & health check (specs/08). `--ci` maps the worst status to the
/// CI exit contract: 0 healthy / 3 warnings / 1 critical (Constitution Art. 7).
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the environment and the tool's health.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "CI mode: exit 0 healthy / 3 warnings / 1 critical; no color.")
    var ci: Bool = false

    func run() async throws {
        let rt = Runtime(useColor: options.useColor && !ci)
        var checks: [HealthCheck] = []

        // 1. OS version (macOS 13+ baseline).
        let os = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(.init(name: "macOS version",
            status: os.majorVersion >= 13 ? .ok : .critical,
            detail: "\(os.majorVersion).\(os.minorVersion) (need ≥ 13)"))

        // 2. Tool home writable.
        let probe = rt.toolHome + "/.doctor-probe"
        let writable = (try? "ok".write(toFile: probe, atomically: true, encoding: .utf8)) != nil
        try? FileManager.default.removeItem(atPath: probe)
        checks.append(.init(name: "tool home writable",
            status: writable ? .ok : .critical, detail: rt.toolHome))

        // 3. Plugins registered.
        let n = rt.registry.plugins.count
        checks.append(.init(name: "plugins registered",
            status: n > 0 ? .ok : .critical, detail: "\(n) plugin(s)"))

        // 4. Configuration valid.
        checks.append(.init(name: "configuration",
            status: rt.configError == nil ? .ok : .warn,
            detail: rt.configError.map { "\($0)" } ?? "valid (or absent)"))

        // 5. Staging accessible.
        let staged = (try? rt.staging.listSessions().count) ?? 0
        checks.append(.init(name: "staging accessible",
            status: .ok, detail: "\(staged) staged session(s)"))

        // Worst status → summary + exit code.
        let worst: HealthCheck.Status =
            checks.contains { $0.status == .critical } ? .critical
            : checks.contains { $0.status == .warn } ? .warn : .ok

        if options.json || ci {
            struct Report: Encodable { let schemaVersion = 1; let command = "doctor"
                let health: String; let checks: [HealthCheck] }
            printOut(try ReportJSONEncode(Report(health: worst.rawValue, checks: checks)))
        } else {
            for c in checks {
                let icon = c.status == .ok ? "✓" : (c.status == .warn ? "!" : "✗")
                printOut("  \(icon) \(c.name): \(c.detail)")
            }
            printOut("\nHealth: \(worst.rawValue)")
        }

        switch worst {
        case .ok: return
        case .warn: throw ExitCode(CleanerExitCode.partial.rawValue)   // 3
        case .critical: throw ExitCode(CleanerExitCode.general.rawValue) // 1
        }
    }
}

/// Local pretty-JSON encoder (keeps Doctor independent of ReportJSON's DTOs).
func ReportJSONEncode<T: Encodable>(_ v: T) throws -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try e.encode(v), as: UTF8.self)
}
