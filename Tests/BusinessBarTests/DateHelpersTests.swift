import XCTest
@testable import BusinessBarCore

final class DateHelpersTests: XCTestCase {

    // MARK: - relativeString()
    // All relativeString tests pass a fixed `now:` so results don't depend on
    // scheduling gaps between creating the date and calling the formatter.

    func testRelativeString_futureDateLessThanOneMinute_returnsNow() {
        let now = Date()
        let date = now.addingTimeInterval(30) // 30 seconds ahead
        XCTAssertEqual(date.relativeString(now: now), "now")
    }

    func testRelativeString_futureDateFiveMinutes_returnsIn5m() {
        let now = Date()
        let date = now.addingTimeInterval(5 * 60) // 5 minutes ahead
        XCTAssertEqual(date.relativeString(now: now), "in 5m")
    }

    func testRelativeString_futureDateNinetyMinutes_returnsIn1h() {
        let now = Date()
        let date = now.addingTimeInterval(90 * 60) // 90 minutes ahead
        XCTAssertEqual(date.relativeString(now: now), "in 1h")
    }

    func testRelativeString_futureDateTwentyFiveHours_returnsIn1d() {
        let now = Date()
        let date = now.addingTimeInterval(25 * 60 * 60) // 25 hours ahead
        XCTAssertEqual(date.relativeString(now: now), "in 1d")
    }

    func testRelativeString_pastDate_returnsPassed() {
        let now = Date()
        let date = now.addingTimeInterval(-60) // 1 minute ago
        XCTAssertEqual(date.relativeString(now: now), "passed")
    }

    func testRelativeString_dateApproximatelyNow_returnsNow() {
        // Tiny future offset relative to the pinned `now` keeps this on the
        // "now" side of the minute boundary regardless of test scheduling.
        let now = Date()
        let date = now.addingTimeInterval(0.001)
        XCTAssertEqual(date.relativeString(now: now), "now")
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