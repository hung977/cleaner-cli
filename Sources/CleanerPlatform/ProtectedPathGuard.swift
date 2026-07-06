import Foundation
import CleanerCore

/// The engine-enforced deletion gate (Constitution Art. 4.4 & Art. 5, specs/22).
///
/// This is *defense in depth*: it runs independently of any plugin. A plugin can only *propose*
/// paths; nothing is disposed unless this guard approves it. The rule is:
///
///   allowed(path)  ⇔  path ⊆ (⋃ allowedRoots)  ∧  path ⊄ denyList  ∧  path is not a root/volume
///
/// Matching is on path *components* (so `/Users/me/DerivedDataEvil` is NOT inside
/// `/Users/me/DerivedData`).
public struct ProtectedPathGuard: Sendable {
    public enum Decision: Sendable, Equatable {
        case allowed
        case blocked(reason: String)
        public var isAllowed: Bool { self == .allowed }
    }

    private let home: String
    private let denyPrefixes: [String]
    private let toolHome: String

    /// - Parameters:
    ///   - home: the user's home directory (injected for testability).
    ///   - toolHome: the tool's own `~/.cleaner` directory (never deletable by plugins).
    public init(home: String = NSHomeDirectory(), toolHome: String? = nil) {
        let h = Self.normalize(home)
        self.home = h
        self.toolHome = Self.normalize(toolHome ?? (h + "/.cleaner"))
        self.denyPrefixes = Self.buildDenyList(home: h, toolHome: self.toolHome)
    }

    // MARK: - Public API

    /// Is this path itself protected (independent of allowed roots)?
    public func isProtected(_ path: String) -> Bool {
        let p = Self.normalize(path)
        if Self.isRootOrVolume(p) { return true }
        if denyPrefixes.contains(where: { Self.isWithin(p, prefix: $0) }) { return true }
        if Self.hasSensitiveSuffix(p) { return true }
        return false
    }

    /// Validate a path for deletion given the plugin-declared allowed roots. This is the call the
    /// cleanup engine MUST make before disposing of anything.
    public func validateForDeletion(_ path: String, allowedRoots: [String]) -> Decision {
        let p = Self.normalize(path)

        if Self.isRootOrVolume(p) {
            return .blocked(reason: "refuses to act on a volume root or `/`")
        }
        if let hit = denyPrefixes.first(where: { Self.isWithin(p, prefix: $0) }) {
            return .blocked(reason: "path is under a protected location (\(hit))")
        }
        if Self.hasSensitiveSuffix(p) {
            return .blocked(reason: "path looks like credential/key material")
        }
        let roots = allowedRoots.map(Self.normalize)
        guard roots.contains(where: { Self.isWithin(p, prefix: $0) }) else {
            return .blocked(reason: "path is outside every allowed plugin root")
        }
        return .allowed
    }

    // MARK: - Deny list (Constitution Art. 5)

    private static func buildDenyList(home: String, toolHome: String) -> [String] {
        var deny = [
            "/System", "/bin", "/sbin", "/private/var/db",
            "/usr",                       // /usr/local is re-allowed below via allowedRoots, not here
            "/Library",                   // system Library
            "/Applications",              // the .app bundles themselves
            "/.vol", "/cores",
        ]
        // User content roots — never touched.
        for sub in ["Documents", "Desktop", "Pictures", "Movies", "Music",
                    ".ssh", ".gnupg", ".aws", ".config/gcloud",
                    "Library/Keychains"] {
            deny.append(home + "/" + sub)
        }
        // The tool's own home (staging/config/logs/audit) is off-limits to plugins.
        deny.append(toolHome)
        return deny.map(normalize)
    }

    // MARK: - Path helpers

    /// Absolute, tilde-expanded, `..`-resolved, trailing-slash-stripped.
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// True if `path` is `prefix` or lives beneath it, matching on component boundaries.
    static func isWithin(_ path: String, prefix: String) -> Bool {
        if path == prefix { return true }
        return path.hasPrefix(prefix + "/")
    }

    static func isRootOrVolume(_ path: String) -> Bool {
        if path == "/" || path.isEmpty { return true }
        // `/Volumes/X` mount roots (but allow paths *inside* an external volume).
        if path.hasPrefix("/Volumes/") {
            let rest = path.dropFirst("/Volumes/".count)
            return !rest.contains("/")   // exactly `/Volumes/Name` = a mount root
        }
        return false
    }

    static func hasSensitiveSuffix(_ path: String) -> Bool {
        let lower = path.lowercased()
        let last = (lower as NSString).lastPathComponent
        if ["id_rsa", "id_ed25519", "id_dsa"].contains(last) { return true }
        for ext in [".key", ".pem", ".p12", ".keychain", ".keychain-db"] {
            if lower.hasSuffix(ext) { return true }
        }
        return false
    }
}
