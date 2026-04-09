import XCTest
@testable import BusinessBarCore

@MainActor
final class NoSleepManagerTests: XCTestCase {

    func test_initialStateIsInactive() {
        let manager = NoSleepManager()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.timeRemaining, 0)
    }

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

    func test_deactivateResetsState() {
        let manager = NoSleepManager()
        manager.activate(duration: 60)
        manager.deactivate()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.timeRemaining, 0)
    }

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

    func test_activateWithMode() {
        let manager = NoSleepManager()
        manager.activate(duration: nil, mode: .systemAndDisplay)
        XCTAssertEqual(manager.mode, .systemAndDisplay)
    }
}
