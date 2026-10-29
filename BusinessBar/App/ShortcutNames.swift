import Foundation
import KeyboardShortcuts

// MARK: - Global keyboard shortcut names
// Registered with the KeyboardShortcuts library (sindresorhus).
// Users can customise them in the General and Companion preferences tabs.

extension KeyboardShortcuts.Name {
    /// Opens the main BusinessBar dropdown menu.
    static let openMenu = Self("openMenu", default: .init(.b, modifiers: [.command, .shift]))

    /// Joins the next scheduled meeting (opens its meeting link).
    static let joinNextMeeting = Self("joinNextMeeting", default: .init(.j, modifiers: [.command, .shift]))

    /// Toggles the companion chat panel.
    static let toggleCompanionChat = Self("toggleCompanionChat", default: .init(.b, modifiers: [.command]))
}

// MARK: - Per-template shortcut names

extension KeyboardShortcuts.Name {
    /// Shortcut name for a rewrite template. Each template can own its own
    /// global shortcut; `templateShortcutPrefix + template.id` is the stable
    /// key, so renaming a template keeps its shortcut.
    static func rewriteTemplate(_ id: UUID) -> Self {
        Self(templateShortcutPrefix + id.uuidString)
    }

    static let templateShortcutPrefix = "rewriteTemplate:"
}