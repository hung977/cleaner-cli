import Foundation

/// Minimal shell-glob matching backed by POSIX `fnmatch` (specs/24 §rules). Supports `*`, `?`,
/// `[...]`. `*` crosses `/` (no FNM_PATHNAME) so patterns like `*Keep*` match anywhere in a path.
public enum Glob {
    public static func matches(pattern: String, path: String) -> Bool {
        pattern.withCString { pat in
            path.withCString { str in
                fnmatch(pat, str, 0) == 0
            }
        }
    }
}
