import AppKit
import ApplicationServices
import BusinessBarCore
import Foundation
@testable import BusinessBar

/// Drives SelectionService's real AX machinery against a fixture text view
/// hosted in this process. The systemwide focused-element lookup only
/// answers for the app holding keyboard focus, which the coverage harness
/// (a .prohibited background process) never has, so the scenario injects the
/// fixture element through the focused-element seam. Every read and write
/// below is a real Accessibility call against a real NSTextView; the AX
/// paths against Chromium-style editors (value-rewrite fallbacks and the
/// Chromium secure-role sentinel) cannot be driven honestly by AppKit
/// controls, which report success for writes they drop, and stay uncovered
/// by design; exercising them here would also require the clipboard
/// fallbacks that post real keystrokes outside the harness.
@MainActor
enum AppSelectionAXScenarios {
    static func run(_ context: CoverageContext) async throws {
        let service = SelectionService()

        let fixture = try AXTextFixture()
        defer { fixture.close() }
        service.focusedElementOverride = { fixture.element }

        // --- Capture: reads the fixture selection through kAXSelectedText.
        fixture.textView.string = "hello brave world"
        fixture.textView.setSelectedRange(NSRange(location: 6, length: 5))
        let captured = await service.captureSelectedText()
        guard case .success(let selection) = captured else {
            throw CoverageContext.Failure(description: "AX capture must succeed with an injected editable text view: \(captured)")
        }
        try context.equal(selection.text, "brave", "AX capture reads the selected range")
        try context.expect(selection.viaAccessibility, "Capture came through the AX path")

        // Empty selection: kAXSelectedText read returns the empty string,
        // which capture reports as the explicit emptySelection error.
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let emptyCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure(.emptySelection) = emptyCapture { return true }; return false }(),
            "Empty selection reports emptySelection"
        )

        // --- Replace: writes through kAXSelectedText, which rewrites the
        // selection in place on native editors.
        fixture.textView.string = "alpha beta gamma"
        fixture.textView.setSelectedRange(NSRange(location: 6, length: 4))
        let replaced = await service.replaceSelection(with: "delta")
        try context.expect(replaced, "AX replace succeeds on the fixture text view")
        try context.equal(fixture.textView.string, "alpha delta gamma", "Replace rewrites the selection in place")

        // --- Insert after selection: collapse the range to a caret at the
        // selection's end, then write through kAXSelectedText.
        fixture.textView.string = "one two three"
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 3))
        let inserted = await service.insertAfterSelection(" AND")
        try context.expect(inserted, "AX insert-after succeeds through the caret collapse")
        try context.equal(fixture.textView.string, "one AND two three", "Insert lands right after the selection")

        // --- Owner activation branch: a captured selection from this same
        // process makes the owner lookup find no foreign app, so the
        // activation is skipped and the write goes straight through AX.
        fixture.textView.string = "owner path"
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let ownerSelection = SelectionService.CapturedSelection(
            text: "owner", viaAccessibility: true, ownerProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        let ownerReplaced = await service.replaceSelectionInOwner(of: ownerSelection, with: "written")
        try context.expect(ownerReplaced, "Owner replace writes after the activation hop")
        try context.equal(fixture.textView.string, "written path", "Owner replace kept the tail of the document")

        fixture.textView.string = "insert owner"
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let ownerInserted = await service.insertAfterSelectionInOwner(of: ownerSelection, " here")
        try context.expect(ownerInserted, "Owner insert writes after the activation hop")
        try context.equal(fixture.textView.string, "insert here owner", "Owner insert landed right after the selection")

        // --- Owner 0 keeps the write working without any activation hop;
        // the pid guard skips activation entirely.
        fixture.textView.string = "zero pid path"
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 4))
        let zeroSelection = SelectionService.CapturedSelection(
            text: "zero", viaAccessibility: true, ownerProcessIdentifier: 0
        )
        let zeroReplaced = await service.replaceSelectionInOwner(of: zeroSelection, with: "null")
        try context.expect(zeroReplaced, "Zero-pid replace skips activation and writes")
        try context.equal(fixture.textView.string, "null pid path", "Zero-pid replace kept the tail")

        // --- Missing focused element: a seam override that finds nothing
        // makes the insert path report failure. Insert has no clipboard
        // fallback, so nothing is posted to the frontmost app; the replace
        // counterpart is deliberately not exercised here because its paste
        // fallback would post a real Cmd+V outside the harness.
        service.focusedElementOverride = { nil }
        let noElementInsert = await service.insertAfterSelection("dropped")
        try context.expect(!noElementInsert, "Insert reports failure when no element resolves")

        // --- Clipboard paths, driven through the frontmost/poster seams so
        // no real keystrokes leave the harness. Frontmost nil: capture's
        // clipboard fallback declines before any snapshot or copy post.
        service.frontmostApplicationOverride = { nil }
        let frontlessCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure(.captureFailed) = frontlessCapture { return true }; return false }(),
            "Nil frontmost app fails capture after the AX path finds nothing"
        )

        // --- Replace falls through to paste when the AX write is rejected
        // and the frontmost lookup finds no foreign app: paste declines and
        // the whole replace reports failure.
        let pastelessReplace = await service.replaceSelection(with: "never")
        try context.expect(!pastelessReplace, "Replace reports failure with no element and no frontmost app")

        // --- Copy declined by both the synthetic poster and the menu
        // fallback: captureViaClipboard returns before polling.
        service.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "coverage.front.app", processIdentifier: 1
            )
        }
        service.copyPosterOverride = { false }
        service.menuCopyTriggerOverride = { false }
        let copylessCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure(.captureFailed) = copylessCapture { return true }; return false }(),
            "Declined copy posts fail capture without touching the pasteboard"
        )

        // --- Successful clipboard capture: the poster seam acts as Cmd+C by
        // writing the fixture selection onto the pasteboard under test, and
        // the poll loop observes the changeCount move. The restore puts the
        // pre-existing contents back.
        // Fixture pasteboard: later blocks exercise the REAL poster bodies,
        // whose synthetic keystrokes reach the user's actual frontmost app;
        // polling the real general pasteboard there would make capture
        // succeed or fail on whatever the user had selected. The fixture
        // keeps the change-count poll deterministic and leaves the user's
        // clipboard untouched throughout.
        let pasteboard = NSPasteboard.withUniqueName()
        service.pasteboardOverride = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("before-capture", forType: .string)
        fixture.textView.string = "clipboard capture text"
        fixture.textView.setSelectedRange(NSRange(location: 10, length: 7))
        service.copyPosterOverride = {
            pasteboard.clearContents()
            pasteboard.setString("capture", forType: .string)
            return true
        }
        let clipboardCapture = await service.captureSelectedText()
        guard case .success(let clipboardSelection) = clipboardCapture else {
            throw CoverageContext.Failure(description: "Clipboard capture must succeed through the poster seam: \(clipboardCapture)")
        }
        try context.equal(clipboardSelection.text, "capture", "Clipboard capture reads the posted write")
        try context.expect(!clipboardSelection.viaAccessibility, "Clipboard capture is not flagged as AX")
        try context.equal(
            pasteboard.string(forType: .string), "before-capture",
            "Clipboard capture restores the snapshot"
        )

        // Empty clipboard write: capture reports the explicit emptySelection
        // instead of a generic failure.
        service.copyPosterOverride = {
            pasteboard.clearContents()
            pasteboard.setString("", forType: .string)
            return true
        }
        let emptyClipboardCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure(.emptySelection) = emptyClipboardCapture { return true }; return false }(),
            "Empty clipboard write reports emptySelection"
        )

        // --- Copy posts but nothing changes the pasteboard: the poll loop
        // runs to its deadline and the snapshot is restored anyway.
        pasteboard.clearContents()
        pasteboard.setString("still-here", forType: .string)
        service.copyPosterOverride = { true }
        let stalledCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure(.captureFailed) = stalledCapture { return true }; return false }(),
            "Stalled pasteboard change fails capture after the poll deadline"
        )
        try context.equal(
            pasteboard.string(forType: .string), "still-here",
            "Stalled capture restores the snapshot after the deadline"
        )

        // --- Menu-copy fallback: the synthetic poster declines, the menu
        // trigger writes the selection, capture succeeds through the poll.
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 9))
        service.copyPosterOverride = { false }
        service.menuCopyTriggerOverride = {
            pasteboard.clearContents()
            pasteboard.setString("clipboard", forType: .string)
            return true
        }
        let menuCapture = await service.captureSelectedText()
        try context.expect(
            { if case .success = menuCapture { return true }; return false }(),
            "Menu-copy fallback captures when the synthetic poster declines"
        )

        // --- Chromium wake-up branch: a Chrome-like bundle id reaches the
        // AXEnhancedUserInterface write; a neutral id returns early.
        service.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "com.google.Chrome", processIdentifier: 1
            )
        }
        service.copyPosterOverride = { true }
        let chromeCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = chromeCapture { return true }; return false }(),
            "Chrome wake-up path completes without crashing the AX write"
        )
        service.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "coverage.neutral.app", processIdentifier: 1
            )
        }
        let neutralCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = neutralCapture { return true }; return false }(),
            "Neutral bundle id skips the wake-up write"
        )

        // --- Replace paste fallback: AX write is available again but the
        // focused element is gone, so replace falls to paste. The paste
        // poster declines and the snapshot restore runs inline.
        pasteboard.clearContents()
        pasteboard.setString("paste-snapshot", forType: .string)
        service.focusedElementOverride = { nil }
        service.pastePosterOverride = { false }
        let declinedPaste = await service.replaceSelection(with: "replaced")
        try context.expect(!declinedPaste, "Replace fails when the paste poster declines")
        try context.equal(
            pasteboard.string(forType: .string), "paste-snapshot",
            "Declined paste restores the snapshot immediately"
        )

        // Accepted paste: replace succeeds, the new text lands on the
        // pasteboard, and the snapshot is restored after the async delay.
        service.pastePosterOverride = { true }
        let acceptedPaste = await service.replaceSelection(with: "pasted-text")
        try context.expect(acceptedPaste, "Replace succeeds through the paste fallback")
        try context.equal(
            pasteboard.string(forType: .string), "pasted-text",
            "Paste fallback leaves the replacement on the pasteboard before the delayed restore"
        )
        try await Task.sleep(for: .milliseconds(600))
        try context.equal(
            pasteboard.string(forType: .string), "paste-snapshot",
            "Delayed restore returns the snapshot after the paste window"
        )

        // --- Secure-field probes: the seam marks the fixture element
        // secure, so capture returns the empty sentinel (reported as
        // emptySelection) and both write paths decline before any AX write.
        service.focusedElementOverride = { fixture.element }
        service.frontmostApplicationOverride = { nil }
        service.secureElementOverride = { _ in true }
        let secureCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure(.emptySelection) = secureCapture { return true }; return false }(),
            "Secure element capture returns the empty sentinel"
        )
        let secureReplace = await service.replaceSelection(with: "secret")
        try context.expect(!secureReplace, "Secure element replace declines")
        let secureInsert = await service.insertAfterSelection("secret")
        try context.expect(!secureInsert, "Secure element insert declines")

        // --- Snapshot edge cases: the pasteboard with no items yields a nil
        // snapshot, and the restore clears and re-writes what was there.
        pasteboard.clearContents()
        service.copyPosterOverride = { true }
        service.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "coverage.front.app", processIdentifier: 1
            )
        }
        let bareCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = bareCapture { return true }; return false }(),
            "Nil snapshot still completes the capture round-trip"
        )
        try context.expect(pasteboard.pasteboardItems?.isEmpty != false, "Nil snapshot restore leaves the pasteboard clear")

        // --- Walk-up loops to the hop limit: the container element carries
        // no selected-text or value attributes, so every read fails and the
        // walk climbs parents until the limit. Capture then falls to the
        // clipboard path, which the poster seam feeds.
        service.secureElementOverride = nil
        service.focusedElementOverride = { fixture.containerElement }
        service.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "coverage.front.app", processIdentifier: 1
            )
        }
        pasteboard.clearContents()
        pasteboard.setString("hop-limit", forType: .string)
        service.copyPosterOverride = {
            pasteboard.clearContents()
            pasteboard.setString("walked", forType: .string)
            return true
        }
        let hopCapture = await service.captureSelectedText()
        guard case .success(let hopSelection) = hopCapture else {
            throw CoverageContext.Failure(description: "Hop-limit capture must fall through to the clipboard path: \(hopCapture)")
        }
        try context.equal(hopSelection.text, "walked", "Hop-limit capture succeeds through the clipboard fallback")

        // Insert on the same element: every selected-range read fails, the
        // walk hits the limit, and the value-rewrite fallback finds no value
        // either, so insert reports failure.
        let hopInsert = await service.insertAfterSelection("inserted")
        try context.expect(!hopInsert, "Hop-limit insert reports failure with no text-bearing ancestor")

        // Replace on the same element: the selected-text write is rejected
        // up the chain, the value rewrite finds no value, and the paste
        // fallback declines through a failed post, so replace fails.
        service.pastePosterOverride = { false }
        let hopReplace = await service.replaceSelection(with: "replaced")
        try context.expect(!hopReplace, "Hop-limit replace fails through every AX path and the declined paste")

        // --- Real poster bodies: with the seams cleared, simulateCopy and
        // triggerMenuCopyAction run for real. The harness is .prohibited and
        // has no Edit menu, so both return without posting anything the
        // user's session would see, and capture fails.
        service.copyPosterOverride = nil
        service.menuCopyTriggerOverride = nil
        let realPostCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = realPostCapture { return true }; return false }(),
            "Real poster path completes without a fixture app to copy from"
        )

        // The real simulatePaste body posts Cmd+V at the harness itself,
        // which has no key window to receive it.
        service.focusedElementOverride = { nil }
        service.pastePosterOverride = nil
        let realPasteReplace = await service.replaceSelection(with: "pasted")
        try context.expect(realPasteReplace, "Real paste poster reports success posting to a windowless harness")

        // --- Paste key-equivalent resolution: a main menu with a
        // command-V Paste item drives the real-equivalent branch; a custom
        // non-command shortcut and a missing menu both fall back to Cmd+V.
        // The AX element is gone and the frontmost seam is foreign, so the
        // replace falls through to the real paste poster, which resolves
        // the key equivalent from the fixture menu.
        service.focusedElementOverride = { nil }
        service.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "coverage.front.app", processIdentifier: 1
            )
        }
        let mainMenu = NSMenu()
        let editMenu = NSMenu(title: "Edit")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        editMenu.addItem(pasteItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = mainMenu
        defer { NSApp.mainMenu = previousMenu }

        service.focusedElementOverride = { nil }
        let menuPasteReplace = await service.replaceSelection(with: "written")
        try context.expect(menuPasteReplace, "Menu Cmd+V equivalent drives the paste fallback")
        try context.expect(
            pasteboard.string(forType: .string) == "written",
            "Menu-equivalent paste writes the replacement onto the pasteboard"
        )

        pasteItem.keyEquivalentModifierMask = [.option]
        pasteItem.keyEquivalent = "p"
        let customPasteReplace = await service.replaceSelection(with: "swapped")
        try context.expect(customPasteReplace, "Custom non-command shortcut falls back to the Cmd+V keycode")
        try context.expect(
            pasteboard.string(forType: .string) == "swapped",
            "Custom-shortcut paste writes the replacement onto the pasteboard"
        )

        NSApp.mainMenu = nil
        let barePasteReplace = await service.replaceSelection(with: "still")
        try context.expect(barePasteReplace, "Missing menu falls back to the Cmd+V keycode")
        try context.expect(
            pasteboard.string(forType: .string) == "still",
            "Missing-menu paste writes the replacement onto the pasteboard"
        )

        // With no focused-element seam, the real systemwide lookup runs and
        // finds nothing in the .prohibited harness.
        service.focusedElementOverride = nil
        let systemWideCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = systemWideCapture { return true }; return false }(),
            "Systemwide focused-element lookup finds nothing in the harness"
        )

        // --- Real menu-copy walk: the copy poster declines, the menu seam is
        // cleared, and the real AX menu walk of the frontmost lookup runs;
        // the harness has no Edit menu, so the walk returns false.
        service.frontmostApplicationOverride = { nil }
        service.copyPosterOverride = { false }
        service.menuCopyTriggerOverride = nil
        let menuWalkCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = menuWalkCapture { return true }; return false }(),
            "Real menu-copy walk returns without an Edit menu to press"
        )

        // --- Foreign owner activation: a pid with no running app makes the
        // activation guard return without touching any app.
        let foreignSelection = SelectionService.CapturedSelection(
            text: "gone", viaAccessibility: true, ownerProcessIdentifier: 999_999
        )
        service.focusedElementOverride = { fixture.element }
        fixture.textView.string = "owner missing"
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let missingOwnerReplaced = await service.replaceSelectionInOwner(of: foreignSelection, with: "written")
        try context.expect(missingOwnerReplaced, "Missing-owner replace still writes through AX")
        try context.equal(fixture.textView.string, "written missing", "Missing-owner replace kept the tail")

        // --- Chromium-style stubborn editor: selected-text writes are
        // rejected, so replace falls back to the value rewrite and insert
        // falls through the walk-up to the value splice. AppKit fixtures
        // report success for every write, so this scripts the rejection.
        AXScripter.install()
        defer { AXScripter.clear() }
        AXScripter.stubbornValue = "alpha beta gamma"
        AXScripter.selectedTextWriteFails = true
        service.focusedElementOverride = { AXScripter.stubborn }
        service.pastePosterOverride = { false }
        let stubbornReplace = await service.replaceSelection(with: "delta")
        try context.expect(stubbornReplace, "Value rewrite replaces through the full AXValue write")

        AXScripter.stubbornValue = "one two three"
        let stubbornInsert = await service.insertAfterSelection(" AND")
        try context.expect(stubbornInsert, "Value rewrite inserts after the selection when range writes fail")

        // A "successful" selected-text write that changes nothing never
        // reports a phantom success; the walk falls through to the value
        // rewrite, which is the honest rescue.
        AXScripter.selectedTextWriteFails = false
        let droppedInsert = await service.insertAfterSelection("drop")
        try context.expect(droppedInsert, "No-op writes fall through to the value rewrite instead of a phantom success")

        // --- Real menu-copy walk over a scripted foreign menu bar: the
        // poster declines, the menu seam is clear, and the walk presses
        // the enabled Copy item through the static frontmost lookup.
        service.focusedElementOverride = { nil }
        service.frontmostApplicationOverride = nil
        service.copyPosterOverride = { false }
        service.menuCopyTriggerOverride = nil
        SelectionService.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "coverage.menu.app", processIdentifier: 900_001
            )
        }
        AXScripter.stubbornValue = nil
        AXScripter.menuChildren = [AXScripter.copyItem]
        let pressedCapture = await service.captureSelectedText()
        try context.expect(AXScripter.copyPressed == 1, "Menu walk pressed the enabled Copy item")
        try context.expect(
            { if case .failure = pressedCapture { return true }; return false }(),
            "Menu-copy capture still fails with no live pasteboard write"
        )

        // A Chromium-flavored bundle id routes the walk through the wake.
        SelectionService.frontmostApplicationOverride = {
            SelectionService.FrontmostApplication(
                bundleIdentifier: "org.chromium.coverage", processIdentifier: 900_001
            )
        }
        let wakeCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = wakeCapture { return true }; return false }(),
            "Chromium wake path completes against the scripted menu"
        )

        // Non-Copy titles and a disabled Copy item leave the walk empty-handed.
        AXScripter.menuChildren = [AXScripter.cutItem, AXScripter.disabledItem]
        let before = AXScripter.copyPressed
        let disabledCapture = await service.captureSelectedText()
        try context.expect(AXScripter.copyPressed == before, "Disabled and foreign titles are never pressed")
        try context.expect(
            { if case .failure = disabledCapture { return true }; return false }(),
            "Disabled Copy item fails the menu walk"
        )

        // Real press tail: with only the action seam cleared, the walk still
        // resolves the scripted menu but performs AXPress through the raw
        // C call against the nonexistent-pid element, which fails harmlessly
        // and is ignored on the way to the walk's success return.
        AXScripter.menuChildren = [AXScripter.copyItem]
        SelectionService.axPerformAction = nil
        let realPressCapture = await service.captureSelectedText()
        try context.expect(AXScripter.copyPressed == before, "Real press tail never touches the scripted item")
        try context.expect(
            { if case .failure = realPressCapture { return true }; return false }(),
            "Real-press walk completes without a live pasteboard write"
        )

        // A menu bar whose Edit menu holds only a Cut item: the title guard
        // continues past it, the items loop exhausts, and the walk ends with
        // no Copy to press — the loop-exit path, not an early return.
        SelectionService.axPerformAction = nil
        AXScripter.menuChildren = [AXScripter.cutItem]
        AXScripter.menuBarChildren = []
        let fileOnlyCapture = await service.captureSelectedText()
        try context.expect(AXScripter.copyPressed == before, "Cut-only Edit menu never presses anything")
        try context.expect(
            { if case .failure = fileOnlyCapture { return true }; return false }(),
            "Cut-only Edit menu ends the walk with no Copy to press"
        )

        // Frontmost fallthrough: no seams installed, the real workspace
        // lookup runs and answers the harness itself, which the clipboard
        // guard rejects as the app's own bundle.
        AXScripter.clear()
        SelectionService.frontmostApplicationOverride = nil
        let selfFrontCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = selfFrontCapture { return true }; return false }(),
            "Own-app frontmost falls out of the clipboard path"
        )

        // Systemwide lookup that succeeds with no focused element: the
        // nil guard runs its full condition and focusedElement returns nil.
        SelectionService.axCopyAttribute = { _, attr, _ in
            attr == "AXFocusedUIElement" ? .success : .attributeUnsupported
        }
        service.frontmostApplicationOverride = nil
        let nilFocusCapture = await service.captureSelectedText()
        try context.expect(
            { if case .failure = nilFocusCapture { return true }; return false }(),
            "Successful systemwide lookup with no focused element finds nothing"
        )
        SelectionService.axCopyAttribute = nil
    }
}

/// A real NSTextView in an offscreen panel whose AX element is discovered
/// through this process's own accessibility tree.
/// Follows the ChatHosted fixture rules: nonactivating panel, no ordering
/// animations, invisible, never dealloc'd while the process lives.
@MainActor
final class AXTextFixture {
    let textView: NSTextView
    let element: AXUIElement
    private let window: NSPanel

    init() throws {
        OwnedAccessibility.materialize()
        let panel = NSPanel(
            contentRect: NSRect(x: -100_000, y: -100_000, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.isEditable = true
        textView.isSelectable = true
        textView.setAccessibilityIdentifier("ax-fixture-text")
        textView.string = "fixture"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        container.addSubview(textView)
        container.setAccessibilityIdentifier("ax-fixture-container")
        container.setAccessibilityElement(true)
        panel.contentView = container
        window = panel
        self.textView = textView
        panel.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard let discovered = Self.findElement(identifier: "ax-fixture-text") else {
            throw CoverageContext.Failure(description: "Fixture text view did not appear in the process AX tree")
        }
        element = discovered
        guard let containerElement = Self.findElement(identifier: "ax-fixture-container") else {
            throw CoverageContext.Failure(description: "Fixture container did not appear in the process AX tree")
        }
        self.containerElement = containerElement
    }

    /// Element of the plain container view: carries no selected-text or
    /// value attributes, so the walk-up loops hop through it to the limit.
    let containerElement: AXUIElement

    /// Walks this process's AX tree for the element carrying the fixture
    /// identifier. Same discovery route OwnedAccessibility exercises.
    private static func findElement(identifier: String) -> AXUIElement? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success, let windows = windowsRef as? [AXUIElement] else { return nil }
        var queue = windows
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            var idRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate, kAXIdentifierAttribute as CFString, &idRef
            ) == .success, (idRef as? String) == identifier {
                return candidate
            }
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate, kAXChildrenAttribute as CFString, &subRef
            ) == .success, let sub = subRef as? [AXUIElement] {
                queue.append(contentsOf: sub)
            }
        }
        return nil
    }

    func close() {
        window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

/// Scripts Chromium-style AX behavior the fixture's AppKit text view cannot
/// produce: selected-text writes that fail, no-op "successful" writes, and
/// the menu-bar walk of a foreign app. Keys fake roles by pid; AX app refs
/// for distinct pids are distinct CF values, so the walk can address each
/// fake element without colliding with real ones.
@MainActor
enum AXScripter {
    static let menuApp = AXUIElementCreateApplication(900_001)
    static let editMenu = AXUIElementCreateApplication(900_002)
    static let copyItem = AXUIElementCreateApplication(900_003)
    static let disabledItem = AXUIElementCreateApplication(900_004)
    static let cutItem = AXUIElementCreateApplication(900_006)
    static let fileMenu = AXUIElementCreateApplication(900_007)
    static let stubborn = AXUIElementCreateApplication(900_005)

    /// Copy presses the fake menu item recorded.
    static var copyPressed = 0
    /// Items the scripted Edit menu exposes.
    static var menuChildren: [AXUIElement] = []
    /// Menus the scripted menu bar exposes; empty = Edit only.
    static var menuBarChildren: [AXUIElement] = []
    /// When true, AXSelectedText writes fail and AXValue writes succeed,
    /// the Chromium-style rejection the value-rewrite fallbacks handle.
    static var selectedTextWriteFails = false
    /// When true, "successful" writes are dropped: the value never changes,
    /// which keeps the walk-up going instead of reporting a phantom success.
    static var dropWrites = false
    /// Simulated AXValue the stubborn element exposes.
    static var stubbornValue: String?

    static func install() {
        SelectionService.axCopyAttribute = { element, attr, out in
            switch (element, attr) {
            case (menuApp, "AXMenuBar"):
                if !menuBarChildren.isEmpty {
                    out?.initialize(to: menuBarChildren as CFArray)
                    return .success
                }
                out?.initialize(to: [editMenu] as CFArray)
                return .success
            case (editMenu, "AXTitle"):
                out?.initialize(to: "Edit" as CFString)
                return .success
            case (fileMenu, "AXTitle"):
                out?.initialize(to: "File" as CFString)
                return .success
            case (editMenu, "AXChildren"):
                if !menuChildren.isEmpty {
                    out?.initialize(to: menuChildren as CFArray)
                    return .success
                }
                out?.initialize(to: [copyItem, disabledItem] as CFArray)
                return .success
            case (copyItem, "AXTitle"), (disabledItem, "AXTitle"):
                out?.initialize(to: "Copy" as CFString)
                return .success
            case (cutItem, "AXTitle"):
                out?.initialize(to: "Cut" as CFString)
                return .success
            case (copyItem, "AXEnabled"):
                out?.initialize(to: true as CFBoolean)
                return .success
            case (disabledItem, "AXEnabled"):
                out?.initialize(to: false as CFBoolean)
                return .success
            case (stubborn, "AXValue"), (stubborn, "AXSelectedText"):
                if let stubbornValue { out?.initialize(to: stubbornValue as CFString) }
                return .success
            case (stubborn, "AXSelectedTextRange"):
                var cfRange = CFRange(location: 0, length: stubbornValue?.utf16.count ?? 0)
                if let axValue = AXValueCreate(.cfRange, &cfRange) {
                    out?.initialize(to: axValue)
                }
                return .success
            default:
                return .attributeUnsupported
            }
        }
        SelectionService.axSetAttribute = { element, attr, _ in
            switch (element, attr) {
            case (stubborn, "AXSelectedText"):
                return selectedTextWriteFails ? .attributeUnsupported : .success
            case (stubborn, "AXValue"), (stubborn, "AXSelectedTextRange"):
                return .success
            case (stubborn, "AXSelectedTextRange"):
                return .success
            default:
                return .attributeUnsupported
            }
        }
        SelectionService.axPerformAction = { element, action in
            if CFEqual(element, copyItem) && action == "AXPress" {
                copyPressed += 1
                return .success
            }
            return .failure
        }
    }

    static func clear() {
        SelectionService.axCopyAttribute = nil
        SelectionService.axSetAttribute = nil
        SelectionService.axPerformAction = nil
    }
}
