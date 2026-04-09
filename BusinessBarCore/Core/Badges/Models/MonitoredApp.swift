import AppKit
import Foundation

public struct MonitoredApp: Identifiable, Hashable, Codable {
    public let id: String
    public let bundleIdentifier: String
    public let displayName: String
    public var badgeCount: Int
    public var iconPath: String?

    public init(bundleIdentifier: String, displayName: String, badgeCount: Int = 0, iconPath: String? = nil) {
        self.id = bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.badgeCount = badgeCount
        self.iconPath = iconPath
    }

    /// Resolves the app icon, handling both `.app` bundle directories and bare
    /// `.icns` file paths. Falls back to looking up by bundle identifier.
    public var icon: NSImage? {
        // If iconPath points to a .app bundle directory, use NSWorkspace which
        // handles asset-catalogue icons correctly. Fall back to direct file load
        // for bare .icns paths, then look up by bundle identifier.
        if let iconPath {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: iconPath, isDirectory: &isDir), isDir.boolValue {
                return NSWorkspace.shared.icon(forFile: iconPath)
            }
            if let image = NSImage(contentsOfFile: iconPath) {
                return image
            }
        }
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }
}
