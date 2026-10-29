import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - SelectionService

/// Captures the selected text of the frontmost app and replaces it on request.
///
/// Two paths, AX first:
/// 1. Accessibility: read the focused UI element's selected text directly.
///    No clipboard touched, works in most apps (TextEdit, Notes, Xcode,
///    Safari, Chrome after `AXEnhancedUserInterface` is set).
/// 2. Clipboard fallback: snapshot the pasteboard, simulate Cmd+C, poll for a
///    new write, restore the snapshot. Needed for terminals, Electron apps
///    and other apps without usable AX support.
///
/// Replacement prefers AX writes (set selected text, or set value plus
/// re-selecting the range). Apps that reject every AX write, like some
/// custom editors, get a paste instead: the clipboard is snapshotted, the
/// new text is posted with a synthetic Cmd+V, and the snapshot is restored,
/// the same transient pattern the capture path uses for Cmd+C.
public final class SelectionService: @unchecked Sendable {

    public enum CaptureError: Error, Equatable {
        /// AX returned a value but it was empty.
        case emptySelection
        /// Both paths failed.
        case captureFailed
        /// AX permission is not granted.
        case accessibilityNotTrusted
    }

    public struct CapturedSelection {
        public let text: String
        /// True when the text came from the AX path.
        public let viaAccessibility: Bool
        /// Process that owned the selection, so Replace can hand focus back
        /// when it came through a panel that became the key window.
        public let ownerProcessIdentifier: pid_t

        init(text: String, viaAccessibility: Bool, ownerProcessIdentifier: pid_t) {
            self.text = text
            self.viaAccessibility = viaAccessibility
            self.ownerProcessIdentifier = ownerProcessIdentifier
        }
    }

    private let pasteboard = NSPasteboard.general

    // MARK: - Capture

    /// Captures the selected text of the frontmost application.
    public func captureSelectedText() async -> Result<CapturedSelection, CaptureError> {
        guard AXIsProcessTrusted() else { return .failure(.accessibilityNotTrusted) }

        let owner = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }

        if let text = await captureViaAccessibility() {
            guard !text.isEmpty else { return .failure(.emptySelection) }
            return .success(CapturedSelection(text: text, viaAccessibility: true, ownerProcessIdentifier: owner))
        }

        if let text = await captureViaClipboard() {
            guard !text.isEmpty else { return .failure(.emptySelection) }
            return .success(CapturedSelection(text: text, viaAccessibility: false, ownerProcessIdentifier: owner))
        }

        return .failure(.captureFailed)
    }

    // MARK: - AX capture

    private func captureViaAccessibility() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [self] in
                continuation.resume(returning: captureSelectedTextViaAX())
            }
        }
    }

    /// Reads the focused element's selected text, walking up to its AX
    /// ancestors because some apps expose the selection on a parent (web areas).
    private func captureSelectedTextViaAX() -> String? {
        guard let element = Self.focusedElement() else { return nil }

        // Secure fields never expose content. Return "" (not nil) so the
        // clipboard fallback does not fire Cmd+C behind a password box.
        if Self.elementIsSecure(element) { return "" }

        var walkUp: CFTypeRef? = element
        var hops = 0
        while let current = walkUp, hops < 5 {
            var candidate: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                current as! AXUIElement, kAXSelectedTextAttribute as CFString, &candidate
            ) == .success, let text = candidate as? String {
                return text
            }
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                current as! AXUIElement, kAXParentAttribute as CFString, &parent
            ) == .success {
                walkUp = parent
            } else {
                walkUp = nil
            }
            hops += 1
        }
        return nil
    }

    private static func focusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemElement, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, focused != nil else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    private static func elementIsSecure(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &role
        ) == .success, let roleString = role as? String else { return false }
        return roleString == "AXSecureTextField"
    }

    // MARK: - Clipboard fallback

    /// Snapshot pasteboard, simulate Cmd+C, poll for the new write, restore.
    /// The snapshot/restore keeps the user's clipboard intact, and the
    /// transient marker tells clipboard managers to ignore the copy.
    private func captureViaClipboard() async -> String? {
        await MainActor.run { [self] in
            guard let frontApp = NSWorkspace.shared.frontmostApplication,
                  frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

            Self.wakeChromiumIfNeeded(bundleIdentifier: frontApp.bundleIdentifier)

            let snapshot = snapshotPasteboard()
            let before = pasteboard.changeCount
            // Synthetic Cmd+C first; apps that swallow synthetic key events
            // (Terminal, some editors) get the menu-action Copy as fallback.
            let posted = Self.simulateCopy() || Self.triggerMenuCopyAction()
            guard posted else { return nil }

            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline {
                if pasteboard.changeCount != before {
                    let captured = readPasteboardString()
                    restore(from: snapshot)
                    return captured
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            restore(from: snapshot)
            return nil
        }
    }

    private func readPasteboardString() -> String? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        return items.first?.string(forType: .string)
    }

    // MARK: - Snapshot/restore

    private struct PasteboardSnapshot {
        let items: [(types: [NSPasteboard.PasteboardType], data: [Data])]
    }

    private func snapshotPasteboard() -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        let captured = items.map { item in
            (types: item.types, data: item.types.compactMap { item.data(forType: $0) })
        }
        return PasteboardSnapshot(items: captured)
    }

    private func restore(from snapshot: PasteboardSnapshot?) {
        pasteboard.clearContents()
        guard let snapshot else { return }
        for item in snapshot.items {
            let newItem = NSPasteboardItem()
            for (type, data) in zip(item.types, item.data) {
                newItem.setData(data, forType: type)
            }
            pasteboard.writeObjects([newItem])
        }
        // Signal clipboard managers that the previous transient copy is gone.
        declareTransientPasteboard()
    }

    private func declareTransientPasteboard() {
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    // MARK: - Replace

    /// Replaces the selected text in the focused element with `newText`.
    /// AX writes first; apps that reject them get a clipboard paste as the
    /// last resort.
    public func replaceSelection(with newText: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [self] in
                var succeeded = replaceSelectionViaAX(newText)
                if !succeeded {
                    succeeded = replaceViaPaste(newText)
                }
                if !succeeded {
                    AppLogger.error("replaceSelection: AX write and paste both failed", category: "Companion")
                }
                continuation.resume(returning: succeeded)
            }
        }
    }

    /// Same as ``replaceSelection(with:)`` after the caller has returned key
    /// focus to the app that owns the selection. A panel that became the key
    /// window (the rewrite overlay) must be dismissed first: the AX focused
    /// element and synthetic keystrokes both follow the key window, not the
    /// frontmost application.
    public func replaceSelectionInOwner(
        of selection: CapturedSelection, with newText: String
    ) async -> Bool {
        if selection.ownerProcessIdentifier != 0 {
            await Self.activateApplication(pid: selection.ownerProcessIdentifier)
        }
        return await replaceSelection(with: newText)
    }

    /// Inserts `newText` immediately after the selection's end. The
    /// selected text stays in the document but the range collapses to a
    /// caret at the insertion point. AX only: the range dance has no safe
    /// clipboard equivalent, and a paste would overwrite the selection.
    /// Callers fall back to the overlay when this returns false so the
    /// reply is never lost.
    public func insertAfterSelection(_ newText: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [self] in
                let succeeded = insertAfterSelectionViaAX(newText)
                if succeeded {
                    AppLogger.info("insertAfterSelection: inserted after selection", category: "Companion")
                } else {
                    AppLogger.error("insertAfterSelection: AX insert failed", category: "Companion")
                }
                continuation.resume(returning: succeeded)
            }
        }
    }

    /// Same as ``insertAfterSelection(_:)`` after the caller has returned key
    /// focus to the app that owns the selection.
    public func insertAfterSelectionInOwner(
        of selection: CapturedSelection, _ newText: String
    ) async -> Bool {
        if selection.ownerProcessIdentifier != 0 {
            await Self.activateApplication(pid: selection.ownerProcessIdentifier)
        }
        return await insertAfterSelection(newText)
    }

    /// Re-activates the app that owned the selection without raising all its
    /// windows, then gives the run loop one turn so focus settles before
    /// keystrokes are posted (Maccy, Clipy and espanso all paste after the
    /// panel is gone, never while their own panel is key). MainActor because
    /// nonisolated async callers run on the global executor and both
    /// NSRunningApplication.activate and the main run loop are main-thread
    /// policy: off-main calls fail to activate or run loop sources on the
    /// wrong thread.
    @MainActor
    private static func activateApplication(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        app.activate(options: [])
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    private func replaceSelectionViaAX(_ newText: String) -> Bool {
        guard let element = Self.focusedElement() else { return false }
        if Self.elementIsSecure(element) { return false }

        if let role = Self.role(of: element) {
            AppLogger.info("replaceSelection: focused element role=\(role)", category: "Companion")
        }

        // Preferred: setting kAXSelectedText replaces the selection in
        // place. Some apps host the selection on a parent of the focused
        // element, so the write walks ancestors exactly like the capture.
        var walkUp: CFTypeRef? = element
        var hops = 0
        while let current = walkUp, hops < 5 {
            let candidate = unsafeBitCast(current, to: AXUIElement.self)
            if AXUIElementSetAttributeValue(
                candidate, kAXSelectedTextAttribute as CFString, newText as CFTypeRef
            ) == .success {
                return true
            }
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate, kAXParentAttribute as CFString, &parent
            ) == .success {
                walkUp = parent
            } else {
                walkUp = nil
            }
            hops += 1
        }
        AppLogger.warning(
            "replaceSelection: kAXSelectedText rejected on element and ancestors, trying value rewrite",
            category: "Companion"
        )

        // Fallback for elements that only support setting the full value:
        // replace the selected range inside the value, then re-select it.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let oldValue = valueRef as? String,
            let range = Self.selectedTextRange(of: element)
        else {
            AppLogger.warning("replaceSelection: element exposes no value or selected range", category: "Companion")
            return false
        }

        // AX ranges count UTF-16 units; NSString keeps those semantics.
        let nsOld = oldValue as NSString
        guard range.location + range.length <= nsOld.length else { return false }
        let newValue = nsOld.replacingCharacters(in: range, with: newText)

        guard AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, newValue as CFTypeRef
        ) == .success else { return false }

        Self.selectRange(range, in: element)
        return true
    }

    private static func role(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef
        ) == .success else { return nil }
        return roleRef as? String
    }

    /// Last resort for editors that reject every AX write: snapshot the
    /// clipboard, write the new text, post Cmd+V, then restore. The restore
    /// waits past one runloop tick so the target app has read the pasteboard.
    private func replaceViaPaste(_ newText: String) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }

        let snapshot = snapshotPasteboard()
        pasteboard.clearContents()
        pasteboard.setString(newText, forType: .string)
        guard Self.simulatePaste() else {
            restore(from: snapshot)
            return false
        }
        AppLogger.info(
            "replaceSelection: pasting into \(frontApp.bundleIdentifier ?? "app")",
            category: "Companion"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            restore(from: snapshot)
        }
        return true
    }

    /// Posts a synthetic Cmd+V the way proven clipboard managers do (Maccy,
    /// Clipy): a combined-session source with local key events filtered out
    /// during the suppression interval, posted at the annotated session tap.
    /// Raw HID tap delivery is what some editors choke on.
    private static func simulatePaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        // The Paste key equivalent comes from our own Edit menu so it follows
        // the user's keyboard layout instead of assuming ANSI V (Clipy).
        let (keyCode, modifiers) = Self.pasteKeyEquivalent()

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        keyDown.flags = modifiers
        keyUp.flags = modifiers
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Finds the Paste item in our own main menu; falls back to Cmd+V when
    /// the menu is missing or customized away.
    private static func pasteKeyEquivalent() -> (keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let pasteItem = NSApp.mainMenu?.items
            .flatMap { $0.submenu?.items ?? [] }
            .first { $0.action == #selector(NSText.paste(_:)) }

        guard let item = pasteItem, !item.keyEquivalent.isEmpty else {
            return (0x09, .maskCommand)
        }
        let modifiers = item.keyEquivalentModifierMask
        let flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        let keyCode = modifiers.contains(.command) ? CGKeyCode(kVK_ANSI_V) : 0x09
        // A non-command Paste shortcut cannot be turned into a keycode here;
        // Cmd+V is the universal fallback.
        guard modifiers.contains(.command), item.keyEquivalent.lowercased() == "v" else {
            return (0x09, .maskCommand)
        }
        return (keyCode, flags)
    }

    /// AX-only insert: collapse the selection to a caret at its end, then
    /// write the text through kAXSelectedText, which inserts at the caret.
    /// Walks ancestors like the capture/replace paths because some apps
    /// host the selection on a parent element.
    private func insertAfterSelectionViaAX(_ newText: String) -> Bool {
        guard let element = Self.focusedElement() else { return false }
        if Self.elementIsSecure(element) { return false }

        var walkUp: CFTypeRef? = element
        var hops = 0
        while let current = walkUp, hops < 5 {
            let candidate = unsafeBitCast(current, to: AXUIElement.self)
            if let range = Self.selectedTextRange(of: candidate) {
                // Collapse to the end of the selection, then insert there.
                var caret = CFRange(location: range.location + range.length, length: 0)
                if let axValue = AXValueCreate(.cfRange, &caret),
                    AXUIElementSetAttributeValue(
                        candidate, kAXSelectedTextRangeAttribute as CFString, axValue
                    ) == .success,
                    AXUIElementSetAttributeValue(
                        candidate, kAXSelectedTextAttribute as CFString, newText as CFTypeRef
                    ) == .success {
                    return true
                }
            }
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate, kAXParentAttribute as CFString, &parent
            ) == .success {
                walkUp = parent
            } else {
                walkUp = nil
            }
            hops += 1
        }
        return false
    }

    private static func selectedTextRange(of element: AXUIElement) -> NSRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef else { return nil }
        let axValue = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func selectRange(_ range: NSRange, in element: AXUIElement) {
        var cfRange = CFRange(location: range.location, length: range.length)
        if let axValue = AXValueCreate(.cfRange, &cfRange) {
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, axValue
            )
        }
    }

    // MARK: - Helpers

    private static func simulateCopy() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Triggers the frontmost app's enabled Edit > Copy menu action directly.
    /// Some apps reject synthetic key events but expose selection copy through
    /// their menu, so this walks the AX menu bar and presses Copy in place of
    /// a synthetic Cmd+C.
    private static func triggerMenuCopyAction() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var menus: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXMenuBarAttribute as CFString, &menus
        ) == .success, let menuBar = menus else { return false }
        guard let menuBarElement = menuBar as? [AXUIElement] else { return false }

        for menu in menuBarElement {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                menu, kAXTitleAttribute as CFString, &title
            ) == .success, (title as? String)?.lowercased() == "edit" else { continue }

            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                menu, kAXChildrenAttribute as CFString, &children
            ) == .success, let items = children as? [AXUIElement] else { continue }

            for item in items {
                var itemTitle: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    item, kAXTitleAttribute as CFString, &itemTitle
                ) == .success,
                      let name = itemTitle as? String,
                      name.lowercased() == "copy"
                else { continue }
                var enabled: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    item, kAXEnabledAttribute as CFString, &enabled
                ) == .success, (enabled as? Bool) == true else { return false }
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                return true
            }
        }
        return false
    }

    /// Electron apps ignore AX text queries until this attribute is set
    /// once; Chromium-based browsers and Slack both need the nudge.
    private static func wakeChromiumIfNeeded(bundleIdentifier: String?) {
        guard let id = bundleIdentifier,
              id.contains("chromium") || id == "com.google.Chrome" || id.contains("slack"),
              let app = NSWorkspace.shared.frontmostApplication
        else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef
        )
    }
}
