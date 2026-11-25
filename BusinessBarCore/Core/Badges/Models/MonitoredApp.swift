import AppKit
import Foundation

public struct MonitoredApp: Identifiable, Hashable, Codable {
    public let id: String
    public let bundleIdentifier: String
    public let displayName: String
    /// Persisted badge storage: 0 = no badge, -1 = unknown count, n > 0 = n.
    /// Kept as a plain Int so the JSON format is unchanged from earlier
    /// releases; read through `badge` instead.
    public var badgeCount: Int
    public var iconPath: String?

    public init(bundleIdentifier: String, displayName: String, badgeCount: Int = 0, iconPath: String? = nil) {
        self.id = bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.badgeCount = badgeCount
        self.iconPath = iconPath
    }

    /// Badge state for rendering: nil = no badge, .unknown = dot,
    /// .known(n) = count bubble.
    public var badge: BadgeValue? {
        BadgeValue?.from(persistedCount: badgeCount)
    }

    /// Resolves the app icon, handling both `.app` bundle directories and bare
    /// `.icns` file paths. Falls back to looking up by bundle identifier.
    ///
    /// Resolution hits the disk (NSWorkspace / file reads), so results are
    /// cached per bundle identifier. Icons are app-static; a stale entry only
    /// survives until relaunch or an app update, which is acceptable here.
    public var icon: NSImage? {
        if let cached = Self.iconCache.object(forKey: bundleIdentifier as NSString) {
            return cached
        }

        let resolved = resolveIcon()
        if let resolved {
            Self.iconCache.setObject(resolved, forKey: bundleIdentifier as NSString)
        }
        return resolved
    }

    func resolveIcon(
        iconForFile: (String) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0) },
        applicationPath: (String) -> String? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path },
        loadImage: (String) -> NSImage? = { NSImage(contentsOfFile: $0) }
    ) -> NSImage? {
        if let iconPath {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: iconPath, isDirectory: &isDir), isDir.boolValue {
                return iconForFile(iconPath)
            }
            if let image = loadImage(iconPath) {
                return image
            }
        }
        if let path = applicationPath(bundleIdentifier) {
            return iconForFile(path)
        }
        return nil
    }

    /// NSCache so the system can evict under memory pressure instead of
    /// pinning every icon for the app's lifetime.
    private static let iconCache = NSCache<NSString, NSImage>()
}
