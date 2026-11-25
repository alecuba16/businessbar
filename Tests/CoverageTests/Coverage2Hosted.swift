import AppKit
import BusinessBarCore
import Foundation
import SwiftUI
@testable import BusinessBar

/// Hosted fixture for the coverage wave-2 scenarios. Same panel recipe as
/// ChatHosted: offscreen borderless panel, invisible, AX-driven.
@MainActor
final class Coverage2Hosted<Content: View> {
    let host: NSHostingView<Content>
    let window: NSPanel

    init(_ content: Content, size: NSSize) {
        OwnedAccessibility.materialize()
        host = NSHostingView(rootView: content)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        window = panel
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        host.displayIfNeeded()
    }

    var text: String {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return OwnedAccessibility.elements(in: host).flatMap { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }

    func elements() -> [OwnedAccessibility.Element] {
        OwnedAccessibility.materialize()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return OwnedAccessibility.elements(in: host)
    }

    func control(_ name: String) -> OwnedAccessibility.Element? {
        elements().first { element in
            element.accessibilityLabel() == name || element.accessibilityTitle() == name || (element.accessibilityValue() as? String) == name
        }
    }

    func press(_ name: String, _ context: CoverageContext) throws {
        guard let element = control(name), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Control not found or disabled: \(name)")
        }
        try context.expect(element.accessibilityPerformPress(), "Control press succeeds: \(name)")
    }

    func pressByHelp(_ help: String, _ context: CoverageContext) throws {
        guard let element = elements().first(where: { $0.helpText() == help }), element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Control with help not found or disabled: \(help)")
        }
        try context.expect(element.accessibilityPerformPress(), "Press by help succeeds: \(help)")
    }

    /// Alert and sheet windows spawned by the hosted view: same walk as the
    /// main fixture panel.
    func auxiliaryWindows() -> [OwnedAccessibility.Element] {
        OwnedAccessibility.materialize()
        var found: [OwnedAccessibility.Element] = []
        for window in NSApp.windows {
            guard window.isVisible, window !== self.window, let content = window.contentView else { continue }
            found.append(contentsOf: OwnedAccessibility.elements(in: content))
        }
        return found
    }

    func auxiliaryText() -> String {
        auxiliaryWindows().flatMap { element in
            [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }

    /// Press inside an alert or sheet window. Measured on this host: alert
    /// buttons report performPress false while the action still runs, so
    /// like alertPress the return value is not asserted.
    func auxiliaryPress(_ label: String, _ context: CoverageContext) throws {
        guard let element = auxiliaryWindows().first(where: { $0.accessibilityLabel() == label || $0.accessibilityTitle() == label }),
              element.isAccessibilityEnabled() else {
            throw CoverageContext.Failure(description: "Auxiliary control not found or disabled: \(label)")
        }
        _ = element.accessibilityPerformPress()
    }

    /// Checkbox with a label: the AXCheckBox node whose parent row carries
    /// the label. Matches the UI2Hosted pressCheckbox(index:) shape.
    func checkboxControls() -> [OwnedAccessibility.Element] {
        elements().filter { String(describing: $0.accessibilityRole() ?? "").contains("CheckBox") }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
func coverage2Settle() async {
    for _ in 0..<4 {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }
}