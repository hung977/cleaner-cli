import Foundation
import CleanerCore
import Yams

/// User configuration loaded from `~/.cleaner/config.yml` (specs/24, v0.5 subset).
public struct CleanerConfiguration: Sendable, Codable, Equatable {
    public var version: Int
    /// Glob patterns; matching findings are dropped from results (never shown or acted on).
    public var ignore: [String]
    /// Glob patterns the tool must never touch (treated as protected).
    public var whitelist: [String]

    public init(version: Int = 1, ignore: [String] = [], whitelist: [String] = []) {
        self.version = version
        self.ignore = ignore
        self.whitelist = whitelist
    }

    public static let empty = CleanerConfiguration()

    /// True if `path` matches any ignore or whitelist glob (⇒ exclude from findings).
    public func excludes(_ path: String) -> Bool {
        (ignore + whitelist).contains { Glob.matches(pattern: $0, path: path) }
    }
}

/// Configuration errors map to exit code 6 (Constitution Art. 7).
public enum ConfigError: Error, CustomStringConvertible {
    case invalidYAML(String)
    case unsupportedVersion(Int)
    public var description: String {
        switch self {
        case .invalidYAML(let m): return "invalid config.yml: \(m)"
        case .unsupportedVersion(let v): return "unsupported config version \(v) (expected 1)"
        }
    }
}

/// Loads and validates configuration. A missing file yields `.empty` (config is optional).
public struct ConfigLoader: Sendable {
    public init() {}

    public func load(path: String) throws -> CleanerConfiguration {
        guard FileManager.default.fileExists(atPath: path) else { return .empty }
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw ConfigError.invalidYAML(error.localizedDescription) }

        let config: CleanerConfiguration
        do { config = try YAMLDecoder().decode(CleanerConfiguration.self, from: text) }
        catch { throw ConfigError.invalidYAML("\(error)") }

        guard config.version == 1 else { throw ConfigError.unsupportedVersion(config.version) }
        return config
    }
}
