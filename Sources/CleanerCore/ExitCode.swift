/// The shared process exit codes (Constitution Art. 7). Never invent new ones ad hoc.
public enum CleanerExitCode: Int32, Sendable, CaseIterable {
    case ok = 0
    case general = 1
    case usage = 2
    case partial = 3          // completed with some items skipped/failed
    case permission = 4       // needed access (Full Disk Access / admin) not granted
    case cancelled = 5        // user cancelled or timeout
    case config = 6           // invalid configuration
    case plugin = 7           // a plugin failed to load or violated the contract
    case safety = 8           // aborted by a safety invariant
    case precondition = 10    // environment unmet (unsupported OS, no TTY where required)
    case entitlement = 11     // Pro-only feature invoked without a valid license
}
