import XCTest
@testable import BusinessBarCore

final class MeetingLinkDetectorTests: XCTestCase {

    // MARK: - Zoom

    func test_detectsZoomLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Join via Zoom: https://us02web.zoom.us/j/123456789?pwd=abc"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    // MARK: - Google Meet

    func test_detectsGoogleMeetLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Video call: https://meet.google.com/abc-defg-hij"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.google.com") == true)
    }

    // MARK: - Microsoft Teams

    func test_detectsMicrosoftTeamsLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("teams.microsoft.com") == true)
    }

    // MARK: - No link

    func test_returnsNilWhenNoLinkPresent() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Quarterly all-hands — Conference Room 4A"
        )
        XCTAssertNil(url)
    }

    func test_returnsNilForEmptyString() {
        XCTAssertNil(MeetingLinkDetector.detectMeetingLink(in: ""))
    }
}
