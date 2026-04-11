import XCTest
@testable import BusinessBarCore

@MainActor
final class NoSleepManagerTests: XCTestCase {

    // MARK: - Initial State

    func test_initialStateIsInactive() {
        let manager = NoSleepManager()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.timeRemaining, 0)
    }

    func test_initialModeIsSystemOnly() {
        let manager = NoSleepManager()
        XCTAssertEqual(manager.mode, .systemOnly)
    }

    // MARK: - Activation

    func test_activateWithDurationSetsActiveAndTimeRemaining() {
        let manager = NoSleepManager()
        manager.activate(duration: 3600)
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.timeRemaining, 3600, accuracy: 1)
    }

    func test_activateIndefinitelySetsInfiniteTimeRemaining() {
        let manager = NoSleepManager()
        manager.activate(duration: nil)
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.timeRemaining.isInfinite)
    }

    func test_activateWithMode() {
        let manager = NoSleepManager()
        manager.activate(duration: nil, mode: .systemAndDisplay)
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.mode, .systemAndDisplay)
    }

    func test_activateWithoutModePreservesCurrentMode() {
        let manager = NoSleepManager()

        // Default mode is systemOnly; activating without an explicit mode keeps it
        manager.activate(duration: nil)
        XCTAssertEqual(manager.mode, .systemOnly)
        manager.deactivate()

        // Set mode to systemAndDisplay, deactivate, then reactivate without mode
        manager.activate(duration: nil, mode: .systemAndDisplay)
        XCTAssertEqual(manager.mode, .systemAndDisplay)
        manager.deactivate()

        // Mode persists across deactivate; activating without mode should keep it
        manager.activate(duration: nil)
        XCTAssertEqual(manager.mode, .systemAndDisplay)
    }

    func test_activateWithDurationNilAndNoModeUsesDefaults() {
        let manager = NoSleepManager()
        manager.activate(duration: nil)
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.timeRemaining.isInfinite)
        XCTAssertEqual(manager.mode, .systemOnly)
    }

    // MARK: - Deactivation

    func test_deactivateResetsState() {
        let manager = NoSleepManager()
        manager.activate(duration: 60)
        manager.deactivate()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.timeRemaining, 0)
    }

    func test_deactivatePreservesMode() {
        let manager = NoSleepManager()
        manager.activate(duration: nil, mode: .systemAndDisplay)
        XCTAssertEqual(manager.mode, .systemAndDisplay)

        manager.deactivate()

        // Mode is NOT reset by deactivate — it persists for the next activation
        XCTAssertEqual(manager.mode, .systemAndDisplay)
    }

    func test_deactivateAfterIndefiniteActivation() {
        let manager = NoSleepManager()
        manager.activate(duration: nil)
        XCTAssertTrue(manager.timeRemaining.isInfinite)

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.timeRemaining, 0)
    }

    // MARK: - Toggle

    func test_toggleActivatesWhenInactive() {
        let manager = NoSleepManager()
        XCTAssertFalse(manager.isActive)

        manager.toggle()

        XCTAssertTrue(manager.isActive)
    }

    func test_toggleDeactivatesWhenActive() {
        let manager = NoSleepManager()
        manager.activate(duration: nil)
        XCTAssertTrue(manager.isActive)

        manager.toggle()

        XCTAssertFalse(manager.isActive)
    }

    func test_toggleUsesCurrentMode() {
        let manager = NoSleepManager()

        // Set mode to systemAndDisplay, deactivate, then toggle
        manager.activate(duration: nil, mode: .systemAndDisplay)
        manager.deactivate()
        XCTAssertEqual(manager.mode, .systemAndDisplay)

        manager.toggle()

        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.mode, .systemAndDisplay)
    }

    func test_toggleWithConfiguredDefaultDuration() {
        // When no default duration is set, toggle activates indefinitely
        let manager = NoSleepManager()
        manager.toggle()
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.timeRemaining.isInfinite)
        manager.deactivate()

        // Configure a default duration (5 minutes) in UserDefaults
        UserDefaults.standard.set(5, forKey: Constants.Defaults.noSleepDefaultDuration)
        defer {
            UserDefaults.standard.removeObject(forKey: Constants.Defaults.noSleepDefaultDuration)
        }

        let managerWithDefault = NoSleepManager()
        managerWithDefault.toggle()
        XCTAssertTrue(managerWithDefault.isActive)
        // 5 minutes = 300 seconds
        XCTAssertEqual(managerWithDefault.timeRemaining, 300, accuracy: 1)
    }

    // MARK: - Multiple Activations

    func test_reactivatingWithDifferentModeUpdatesMode() {
        let manager = NoSleepManager()
        manager.activate(duration: nil, mode: .systemOnly)
        XCTAssertEqual(manager.mode, .systemOnly)

        // Reactivate with a different mode while already active
        manager.activate(duration: nil, mode: .systemAndDisplay)

        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.mode, .systemAndDisplay)
    }

    func test_reactivatingWithDurationUpdatesTimeRemaining() {
        let manager = NoSleepManager()
        manager.activate(duration: 3600)
        XCTAssertEqual(manager.timeRemaining, 3600, accuracy: 1)

        // Reactivate with a different duration while already active
        manager.activate(duration: 120)

        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.timeRemaining, 120, accuracy: 1)
    }

    func test_reactivatingIndefinitelyAfterTimed() {
        let manager = NoSleepManager()
        manager.activate(duration: 3600)
        XCTAssertFalse(manager.timeRemaining.isInfinite)

        // Switch from timed to indefinite while already active
        manager.activate(duration: nil)

        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.timeRemaining.isInfinite)
    }

    // MARK: - timeRemaining Computation

    func test_timeRemainingIsZeroWhenInactive() {
        let manager = NoSleepManager()

        // Never activated
        XCTAssertEqual(manager.timeRemaining, 0)

        // After activation and deactivation
        manager.activate(duration: 60)
        manager.deactivate()
        XCTAssertEqual(manager.timeRemaining, 0)
    }

    func test_timeRemainingDecreasesOverTime() async throws {
        let manager = NoSleepManager()
        manager.activate(duration: 10)

        let firstReading = manager.timeRemaining

        // Since timeRemaining is computed on-demand, it should reflect
        // the passage of time after a short wait.
        try await Task.sleep(for: .milliseconds(200))

        let secondReading = manager.timeRemaining

        XCTAssertLessThan(secondReading, firstReading)
        XCTAssertGreaterThan(secondReading, 0)
    }

    // MARK: - SleepMode Codable

    func test_sleepModeCodableRoundTrip() throws {
        let modes: [SleepMode] = [.systemOnly, .systemAndDisplay]

        for mode in modes {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(SleepMode.self, from: encoded)
            XCTAssertEqual(decoded, mode, "Round-trip failed for \(mode.rawValue)")
        }
    }

    func test_sleepModeRawValues() {
        XCTAssertEqual(SleepMode.systemOnly.rawValue, "systemOnly")
        XCTAssertEqual(SleepMode.systemAndDisplay.rawValue, "systemAndDisplay")
    }

    func test_sleepModeDecodingInvalidRawValueReturnsNil() {
        let invalidMode = SleepMode(rawValue: "invalidMode")
        XCTAssertNil(invalidMode)

        let emptyMode = SleepMode(rawValue: "")
        XCTAssertNil(emptyMode)
    }
}