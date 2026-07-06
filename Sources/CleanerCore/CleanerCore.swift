// CleanerCore — domain model (specs/14-domain-model.md).
// Pure value types, Sendable, no platform/IO dependencies. Everything here is
// deterministic and free of side effects so it can be exhaustively unit-tested.

/// Namespace + version marker.
public enum CleanerCore {
    /// Spec suite this module implements against.
    public static let specVersion = "0.1.0"
}
