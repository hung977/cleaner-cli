import Foundation
import CleanerCore
import Yams

/// A saved, named selection of plugins + options (specs/24 profiles).
public struct Profile: Sendable, Codable, Equatable {
    public var include: [String]
    public var exclude: [String]

    public init(include: [String] = [], exclude: [String] = []) {
        self.include = include
        self.exclude = exclude
    }

    enum CodingKeys: String, CodingKey { case include, exclude }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.include = try c.decodeIfPresent([String].self, forKey: .include) ?? []
        self.exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }
}

/// User configuration loaded from `~/.cleaner/config.yml` (specs/24, v0.5 subset).
public struct CleanerConfiguration: Sendable, Codable, Equatable {
    public var version: Int
    /// Glob patterns; matching findings are dropped from results (never shown or acted on).
    public var ignore: [String]
    /// Glob patterns the tool must never touch (treated as protected).
    public var whitelist: [String]
    /// Named profiles (selection presets).
    public var profiles: [String: Profile]

    public init(version: Int = 1, ignore: [String] = [], whitelist: [String] = [],
                profiles: [String: Profile] = [:]) {
        self.version = version
        self.ignore = ignore
        self.whitelist = whitelist
        self.profiles = profiles
    }

    // All keys optional in YAML (a minimal config need only set what it overrides).
    enum CodingKeys: String, CodingKey { case version, ignore, whitelist, profiles }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.ignore = try c.decodeIfPresent([String].self, forKey: .ignore) ?? []
        self.whitelist = try c.decodeIfPresent([String].self, forKey: .whitelist) ?? []
        self.profiles = try c.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
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
