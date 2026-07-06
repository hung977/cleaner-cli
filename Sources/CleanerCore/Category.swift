/// A user-facing grouping of findings (specs/09 information architecture).
public struct Category: Sendable, Hashable, Codable, Identifiable {
    public let id: String            // stable slug, e.g. "developer-cache"
    public let displayName: String
    public let icon: String          // Unicode glyph for the TUI

    public init(id: String, displayName: String, icon: String) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
    }

    // Well-known categories used by the v0.1 plugins.
    public static let trash = Category(id: "trash", displayName: "Trash", icon: "🗑")
    public static let developerCache =
        Category(id: "developer-cache", displayName: "Developer Cache", icon: "🛠")
    public static let buildArtifacts =
        Category(id: "build-artifacts", displayName: "Build Artifacts", icon: "📦")
}
