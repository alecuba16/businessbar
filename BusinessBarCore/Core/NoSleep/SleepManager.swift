import AppKit
import IOKit.pwr_mgt
import Foundation
import os.log

// MARK: - SleepMode

public enum SleepMode: String, Codable {
    case systemOnly
    case systemAndDisplay

    public var assertionType: CFString {
        switch self {
        case .systemOnly:
            return kIOPMAssertPreventUserIdleSystemSleep as CFString
        case .systemAndDisplay:
            return kIOPMAssertPreventUserIdleDisplaySleep as CFString
        }
    }

    public var description: String {
        switch self {
        case .systemOnly:
            return "Prevent system sleep only"
        case .systemAndDisplay:
            return "Prevent system + display sleep"
        }
    }
}

// MARK: - SleepManager
// Manages IOKit power assertions to prevent system/display sleep.
// Handles fast-user-switch (session resign/become-active) by pausing and
// resuming the assertion automatically.

final class SleepManager {
    // MARK: - Private state

    private static let logger = Logger(subsystem: "com.businessbar.app", category: "SleepManager")

    private var assertionID: IOPMAssertionID = 0
    private var mode: SleepMode = .systemOnly
    private var isAssertionActive = false
    /// Set to true only by activate(), false only by deactivate().
    /// Guards session observers so they never touch IOKit unless NoSleep
    /// was explicitly started — prevents spurious assertions on session events.
    private var intentionallyActive = false

    // MARK: - Lifecycle

    init() {
        setupSessionObservers()
    }

    deinit {
        removeSessionObservers()
        if isAssertionActive { releaseAssertion() }
    }

    // MARK: - Public API

    func activate(mode: SleepMode) {
        intentionallyActive = true
        self.mode = mode
        // Release any existing assertion before creating a new one, otherwise
        // the old assertionID is overwritten and that assertion leaks forever.
        if isAssertionActive { releaseAssertion() }
        createAssertion()
    }

    func deactivate() {
        intentionallyActive = false
        releaseAssertion()
    }

    // MARK: - IOKit assertion management

    private func createAssertion() {
        let assertionName    = "BusinessBar NoSleep" as CFString
        let assertionDetails = "Preventing sleep via BusinessBar" as CFString

        let result = IOPMAssertionCreateWithDescription(
            mode.assertionType,
            assertionName,
            assertionDetails,
            assertionDetails,
            nil,
            0,           // no timeout: assertion lives until IOPMAssertionRelease is called
            nil,
            &assertionID
        )

        if result == kIOReturnSuccess {
            isAssertionActive = true
            Self.logger.info("Sleep assertion created (ID: \(self.assertionID))")
        } else {
            Self.logger.error("Failed to create sleep assertion: \(result)")
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }

        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            Self.logger.info("Sleep assertion released (ID: \(self.assertionID))")
        } else {
            Self.logger.error("Failed to release sleep assertion: \(result)")
        }
        assertionID = 0
        isAssertionActive = false
    }

    // MARK: - Fast-user-switch session handling

    private func setupSessionObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func removeSessionObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        guard intentionallyActive else { return }
        Self.logger.info("Session resigned active — pausing assertion")
        releaseAssertion()
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        guard intentionallyActive else { return }
        Self.logger.info("Session became active — resuming assertion")
        createAssertion()
    }
}
