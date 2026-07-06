import ArgumentParser
import Foundation
import CleanerCore
import CleanerReport

/// `cleaner report` — export a storage report to stdout or a file (specs/08). Read-only.
struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a storage report (--json or --md), to stdout or a file.")
    @OptionGroup var options: GlobalOptions

    enum Format: String, ExpressibleByArgument { case json, md }
    @Option(help: "Output format: json or md.") var format: Format = .md
    @Option(name: [.short, .long], help: "Write to this file instead of stdout.") var output: String?

    func run() async throws {
        let rt = Runtime(useColor: false)
        if let e = rt.configError { printErr("\(e)"); throw ExitCode(CleanerExitCode.config.rawValue) }
        let plugins = selectPlugins(rt.registry, include: options.include, exclude: options.exclude)
        let (raw, _) = await scanWithSpinner(rt, plugins: plugins, context: rt.context(),
                                             live: liveEnabled(json: options.json), color: false)
        let result = rt.applyConfig(raw)

        let text: String
        switch (options.json ? .json : format) {
        case .json: text = try ReportJSON.encode(ReportJSON.analyze(result))
        case .md:   text = MarkdownReport.render(result, generatedAt: rt.clock.timestamp())
        }

        if let output {
            try text.write(toFile: output, atomically: true, encoding: .utf8)
            printErr("Report written to \(output)")
        } else {
            printOut(text)
        }
        if !result.skipped.isEmpty { throw ExitCode(CleanerExitCode.partial.rawValue) }
    }
}
