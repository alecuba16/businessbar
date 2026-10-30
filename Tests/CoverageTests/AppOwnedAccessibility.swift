import AppKit
import ApplicationServices
import Foundation

@MainActor
enum OwnedAccessibility {
    private static var preparedApplication = false
    @MainActor struct Element {
        fileprivate let object: NSObject

        func accessibilityLabel() -> String? { value("accessibilityLabel") as? String }
        func accessibilityTitle() -> String? { value("accessibilityTitle") as? String }
        func accessibilityValue() -> Any? { value("accessibilityValue") }
        func isAccessibilityEnabled() -> Bool { boolean("isAccessibilityEnabled") }
        func accessibilityPerformPress() -> Bool { boolean("accessibilityPerformPress") }
        func accessibilityRole() -> Any? { value("accessibilityRole") }

        fileprivate func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }

        private func boolean(_ name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Getter.self)(object, selector)
        }
    }

    static func materialize() {
        if !preparedApplication {
            let application = NSApplication.shared
            let environment = ProcessInfo.processInfo.environment
            let isolatedHome = environment["BUSINESSBAR_COVERAGE_HOME"]
            precondition(isolatedHome != nil && environment["HOME"] == isolatedHome && NSHomeDirectory() == isolatedHome, "Owned accessibility requires the verified isolated coverage home")
            precondition(Bundle.main.bundleIdentifier != "com.businessbar.app", "Owned accessibility must not initialize the production application")
            precondition(application.delegate == nil, "Owned accessibility requires a delegate-free fixture application")
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
            precondition(application.delegate == nil, "Owned accessibility must not construct an application delegate")
            preparedApplication = true
        }
        let process = ProcessInfo.processInfo.processIdentifier
        let application = AXUIElementCreateApplication(process)
        var actualProcess: pid_t = 0
        guard AXUIElementGetPid(application, &actualProcess) == .success, actualProcess == process else { return }
        var children: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &children)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    static func elements(in root: Any) -> [Element] {
        materialize()
        var found: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ item: Any, depth: Int) {
            guard depth < 40, let object = item as? NSObject,
                  seen.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object)
            found.append(element)
            for child in element.value("accessibilityChildren") as? [Any] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found
    }
}
