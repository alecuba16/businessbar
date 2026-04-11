import XCTest
@testable import BusinessBarCore

final class DateHelpersTests: XCTestCase {

    // MARK: - relativeString()

    func testRelativeString_futureDateLessThanOneMinute_returnsNow() {
        let date = Date().addingTimeInterval(30) // 30 seconds from now
        let result = date.relativeString()
        XCTAssertEqual(result, "now")
    }

    func testRelativeString_futureDateFiveMinutes_returnsIn5m() {
        let date = Date().addingTimeInterval(5 * 60) // 5 minutes from now
        let result = date.relativeString()
        XCTAssertEqual(result, "in 5m")
    }

    func testRelativeString_futureDateNinetyMinutes_returnsIn1h() {
        let date = Date().addingTimeInterval(90 * 60) // 90 minutes from now
        let result = date.relativeString()
        XCTAssertEqual(result, "in 1h")
    }

    func testRelativeString_futureDateTwentyFiveHours_returnsIn1d() {
        let date = Date().addingTimeInterval(25 * 60 * 60) // 25 hours from now
        let result = date.relativeString()
        XCTAssertEqual(result, "in 1d")
    }

    func testRelativeString_pastDate_returnsPassed() {
        let date = Date().addingTimeInterval(-60) // 1 minute ago
        let result = date.relativeString()
        XCTAssertEqual(result, "passed")
    }

    func testRelativeString_dateApproximatelyNow_returnsNow() {
        // Use a tiny future offset to avoid the race between Date() inside
        // relativeString() and the test's Date() — a bare Date() can appear
        // in the past by microseconds, producing "passed" instead of "now".
        let date = Date().addingTimeInterval(0.001)
        let result = date.relativeString()
        XCTAssertEqual(result, "now")
    }

    // MARK: - timeRemaining(until:)

    func testTimeRemaining_endDateInThePast_returnsEnded() {
        let start = Date()
        let end = start.addingTimeInterval(-60) // end is 1 minute before start
        let result = start.timeRemaining(until: end)
        XCTAssertEqual(result, "ended")
    }

    func testTimeRemaining_endDateFiveMinutes_returns5m() {
        let start = Date()
        let end = start.addingTimeInterval(5 * 60)
        let result = start.timeRemaining(until: end)
        XCTAssertEqual(result, "5m")
    }

    func testTimeRemaining_endDateNinetyMinutes_returns1h30m() {
        let start = Date()
        let end = start.addingTimeInterval(90 * 60)
        let result = start.timeRemaining(until: end)
        XCTAssertEqual(result, "1h 30m")
    }

    func testTimeRemaining_endDate125Minutes_returns2h5m() {
        let start = Date()
        let end = start.addingTimeInterval(125 * 60)
        let result = start.timeRemaining(until: end)
        XCTAssertEqual(result, "2h 5m")
    }

    func testTimeRemaining_endDateExactlyZeroMinutes_returns0m() {
        let start = Date()
        let end = start
        let result = start.timeRemaining(until: end)
        // Interval is 0, which is not < 0, so it falls through to the else branch
        XCTAssertEqual(result, "0m")
    }
}