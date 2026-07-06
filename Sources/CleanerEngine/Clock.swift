import Foundation

/// Injected clock so the engine (and its audit/staging timestamps) stay testable.
public struct EngineClock: Sendable {
    private let _now: @Sendable () -> Date
    public init(_ now: @escaping @Sendable () -> Date = { Date() }) { self._now = now }
    public var now: Date { _now() }

    /// ISO-8601 timestamp of the current instant (Sendable-safe; no shared formatter).
    public func timestamp() -> String { now.ISO8601Format() }

    /// A fixed clock for tests.
    public static func fixed(_ date: Date) -> EngineClock { EngineClock { date } }
}
