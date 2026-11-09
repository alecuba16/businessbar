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
        // counterpart is deliberately not exercised because its paste
        // fallback would post a real Cmd+V outside the harness.
        service.focusedElementOverride = { nil }
        let noElementInsert = await service.insertAfterSelection("dropped")
        try context.expect(!noElementInsert, "Insert reports failure when no element resolves")
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
        panel.contentView = container
        window = panel
        self.textView = textView
        panel.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard let discovered = Self.findElement(identifier: "ax-fixture-text") else {
            throw CoverageContext.Failure(description: "Fixture text view did not appear in the process AX tree")
        }
        element = discovered
    }

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