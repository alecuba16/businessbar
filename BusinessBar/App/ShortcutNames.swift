import KeyboardShortcuts

// MARK: - Global keyboard shortcut names
// Registered with the KeyboardShortcuts library (sindresorhus).
// Users can customise them in the General preferences tab.

extension KeyboardShortcuts.Name {
    /// Opens the main BusinessBar dropdown menu.
    static let openMenu = Self("openMenu", default: .init(.b, modifiers: [.command, .shift]))

    /// Joins the next scheduled meeting (opens its meeting link).
    static let joinNextMeeting = Self("joinNextMeeting", default: .init(.j, modifiers: [.command, .shift]))
}
