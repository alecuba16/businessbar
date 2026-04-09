import CoreGraphics
import IOKit
import Foundation
import AppKit
import os.log

final class ActivitySimulator {
    private var simulationTimer: Timer?
    private static let logger = Logger(subsystem: "com.businessbar.app", category: "ActivitySimulator")

    // MARK: - Public API

    func startSimulation() {
        guard simulationTimer == nil else {
            Self.logger.debug("Already running — skipping restart")
            return
        }
        let interval = currentCheckInterval()
        let threshold = currentIdleThreshold(forInterval: interval)
        Self.logger.info("Starting — checks every \(Int(interval))s, fires after \(threshold)s idle")
        simulationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkAndSimulate()
        }
    }

    func stopSimulation() {
        guard simulationTimer != nil else { return }
        simulationTimer?.invalidate()
        simulationTimer = nil
        Self.logger.info("Stopped")
    }

    // MARK: - Settings helpers

    private func currentCheckInterval() -> TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: Constants.Defaults.activityCheckInterval)
        let value = stored > 0 ? stored : Constants.DefaultValues.activityCheckInterval
        return TimeInterval(value)
    }

    private func currentIdleThreshold(forInterval interval: TimeInterval) -> Int {
        let stored = UserDefaults.standard.integer(forKey: Constants.Defaults.activityIdleMultiplier)
        let multiplier = stored > 0 ? stored : Constants.DefaultValues.activityIdleMultiplier
        return Int(interval) * multiplier
    }

    // MARK: - Simulation logic

    private func checkAndSimulate() {
        let interval = currentCheckInterval()
        let threshold = currentIdleThreshold(forInterval: interval)
        let idleTime = getSystemIdleTime()
        if idleTime > TimeInterval(threshold) {
            Self.logger.debug("Idle \(String(format: "%.1f", idleTime))s > threshold \(threshold)s — simulating")
            simulateMouseMovement()
        }
    }

    private func getSystemIdleTime() -> TimeInterval {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }

        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else {
            return 0
        }

        let entry = IOIteratorNext(iterator)
        defer { IOObjectRelease(entry) }
        guard entry != 0 else { return 0 }

        guard let prop = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0),
              let idleNanos = prop.takeRetainedValue() as? Int64 else {
            return 0
        }

        return TimeInterval(idleNanos) / TimeInterval(NSEC_PER_SEC)
    }

    private func simulateMouseMovement() {
        let currentLocation = NSEvent.mouseLocation
        let newLocation = CGPoint(x: currentLocation.x + 1, y: currentLocation.y + 1)

        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: newLocation, mouseButton: .left) else {
            return
        }
        moveEvent.post(tap: .cghidEventTap)

        guard let returnEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: currentLocation, mouseButton: .left) else {
            return
        }
        returnEvent.post(tap: .cghidEventTap)
    }
}
