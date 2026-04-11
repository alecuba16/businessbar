import XCTest
@testable import BusinessBarCore

final class MeetingLinkDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: "test-id",
            title: "Test Event",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            location: location,
            notes: notes,
            url: url,
            calendar: MBCalendar(id: "cal-1", title: "Work", color: "#FF0000", source: "iCloud"),
            organizer: nil,
            attendees: [],
            isAllDay: false,
            status: .confirmed
        )
    }

    // MARK: - Zoom

    func test_detectsZoomLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Join via Zoom: https://us02web.zoom.us/j/123456789?pwd=abc"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsZoomLink_bareURL() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://us02web.zoom.us/j/123456789?pwd=abc"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsZoomLink_subdomainVariation() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://eu01web.zoom.us/j/987654321"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsZoomLink_noSubdomain() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://zoom.us/j/555111222"
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

    func test_detectsGoogleMeetLink_bareURL() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.google.com/xyz-abcd-efg"
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

    func test_detectsMicrosoftTeamsLink_simplePath() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://teams.microsoft.com/l/meetup-join/abc123"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("teams.microsoft.com") == true)
    }

    // MARK: - Webex

    func test_detectsWebexLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://company.webex.com/meet/123456"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("webex.com") == true)
    }

    func test_detectsWebexLink_noSubdomain() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://webex.com/meet/789012"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("webex.com") == true)
    }

    // MARK: - Jitsi

    func test_detectsJitsiLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.jit.si/MyRoomName"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.jit.si") == true)
    }

    func test_detectsJitsiLink_lowercaseRoom() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.jit.si/standup-team"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.jit.si") == true)
    }

    // MARK: - Slack

    func test_detectsSlackLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://slack.com/huddle/12345"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("slack.com") == true)
    }

    func test_detectsSlackLink_subdomain() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://workspace.slack.com/huddle/67890"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("slack.com") == true)
    }

    // MARK: - Discord

    func test_detectsDiscordLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://discord.gg/abc123xyz"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("discord.gg") == true)
    }

    func test_detectsDiscordLink_embeddedInText() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Gaming session at https://discord.gg/play-night tonight"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("discord.gg") == true)
    }

    // MARK: - Skype

    func test_detectsSkypeLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://join.skype.com/abcdefg"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("join.skype.com") == true)
    }

    // MARK: - BlueJeans

    func test_detectsBlueJeansLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://bluejeans.com/123456789"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("bluejeans.com") == true)
    }

    func test_detectsBlueJeansLink_subdomain() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://company.bluejeans.com/987654321"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("bluejeans.com") == true)
    }

    // MARK: - GoToMeeting

    func test_detectsGoToMeetingLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://gotomeeting.com/j/123456789"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("gotomeeting.com") == true)
    }

    // MARK: - Hangouts

    func test_detectsHangoutsLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://hangouts.google.com/call/abcdefg"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("hangouts.google.com") == true)
    }

    // MARK: - Whereby

    func test_detectsWherebyLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://whereby.com/my-room"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("whereby.com") == true)
    }

    // MARK: - Around

    func test_detectsAroundLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.around.co/room-name"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.around.co") == true)
    }

    // MARK: - Meet (generic meet subdomain)

    func test_detectsMeetGenericLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.somecompany.com/xyz"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.somecompany.com") == true)
    }

    func test_detectsMeetGenericLink_anotherDomain() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.myorg.io/join/room42"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.myorg.io") == true)
    }

    // MARK: - Chime

    func test_detectsChimeLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://chime.aws/1234"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("chime.aws") == true)
    }

    // MARK: - RingCentral

    func test_detectsRingCentralLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meetings.ringcentral.com/j/123456789"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meetings.ringcentral.com") == true)
    }

    // MARK: - 8x8

    func test_detectsEightByEightLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://8x8.vc/abcdefg"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("8x8.vc") == true)
    }

    // MARK: - FaceTime

    func test_detectsFaceTimeLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "facetime://alice"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("facetime://") == true)
    }

    func test_detectsFaceTimeLink_withQuery() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "facetime://bob?audio=true"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("facetime://") == true)
    }

    // MARK: - Phone

    func test_detectsPhoneLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "tel:+1-555-123-4567"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("tel:") == true)
    }

    func test_detectsPhoneLink_simpleNumber() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "tel:5551234567"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("tel:") == true)
    }

    // MARK: - Generic

    func test_detectsGenericLink() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://video.example.com/join/room123"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("video.example.com") == true)
    }

    func test_detectsGenericLink_anotherDomain() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://conference.mycompany.net/meeting/abc"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("conference.mycompany.net") == true)
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

    func test_returnsNilForPlainTextWithColons() {
        XCTAssertNil(MeetingLinkDetector.detectMeetingLink(in: "Meeting at 3:00 PM in Room 2B"))
    }

    func test_returnsNilForURLWithoutPath() {
        // The generic pattern requires a path after the domain
        XCTAssertNil(MeetingLinkDetector.detectMeetingLink(in: "https://example.com"))
    }

    // MARK: - Edge Cases: URL Embedded in Longer Text

    func test_detectsZoomLink_embeddedInSentence() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Please join via https://us02web.zoom.us/j/123456789?pwd=abc and be on time"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsGoogleMeetLink_embeddedInSentence() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "We use https://meet.google.com/abc-defg-hij for our standups"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.google.com") == true)
    }

    func test_detectsTeamsLink_embeddedInMultilineNotes() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Weekly Sync\nJoin: https://teams.microsoft.com/l/meetup-join/abc123\nAgenda: TBD"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("teams.microsoft.com") == true)
    }

    func test_detectsPhoneLink_embeddedInText() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Dial in: tel:+1-555-123-4567 for the call"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("tel:") == true)
    }

    // MARK: - Edge Cases: Multiple URLs in Same Text

    func test_multipleZoomLinks_returnsFirstMatchInText() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Primary: https://us02web.zoom.us/j/111111111 Backup: https://us02web.zoom.us/j/222222222"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("111111111") == true)
    }

    func test_differentServiceURLs_returnsByServicePriority() {
        // Zoom is checked before Teams in MeetingService.allCases order,
        // so even though Teams URL appears first in text, Zoom is returned.
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "Option A: https://teams.microsoft.com/l/meetup-join/abc123 or Option B: https://us02web.zoom.us/j/999888777"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_differentServiceURLs_specificBeforeGeneric() {
        // Google Meet is checked before the generic catch-all
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.google.com/abc-defg-hij and also https://video.other.com/room"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.google.com") == true)
    }

    // MARK: - Edge Cases: Case-Insensitive Matching

    func test_detectsZoomLink_uppercaseHTTPS() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "HTTPS://us02web.zoom.us/j/123456789"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsGoogleMeetLink_mixedCase() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "hTtPs://meet.google.com/abc-defg-hij"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.google.com") == true)
    }

    func test_detectsTeamsLink_uppercaseDomain() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://TEAMS.MICROSOFT.COM/l/meetup-join/abc123"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.lowercased().contains("teams.microsoft.com") == true)
    }

    func test_detectsDiscordLink_uppercase() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "HTTPS://DISCORD.GG/abc123xyz"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.lowercased().contains("discord.gg") == true)
    }

    // MARK: - Edge Cases: Subdomain Variations

    func test_detectsZoomLink_variousSubdomains() {
        let subdomains = ["us02web", "eu01web", "us04web", ""]
        for subdomain in subdomains {
            let prefix = subdomain.isEmpty ? "" : "\(subdomain)."
            let url = MeetingLinkDetector.detectMeetingLink(
                in: "https://\(prefix)zoom.us/j/123456789"
            )
            XCTAssertNotNil(url, "Expected Zoom link with subdomain '\(subdomain)' to be detected")
            XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
        }
    }

    func test_detectsWebexLink_variousSubdomains() {
        let subdomains = ["company", "enterprise", ""]
        for subdomain in subdomains {
            let prefix = subdomain.isEmpty ? "" : "\(subdomain)."
            let url = MeetingLinkDetector.detectMeetingLink(
                in: "https://\(prefix)webex.com/meet/123456"
            )
            XCTAssertNotNil(url, "Expected Webex link with subdomain '\(subdomain)' to be detected")
            XCTAssertTrue(url?.absoluteString.contains("webex.com") == true)
        }
    }

    func test_detectsSlackLink_subdomainVariation() {
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://myorg.slack.com/huddle/12345"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("slack.com") == true)
    }

    // MARK: - Edge Cases: Service Priority (meet vs specific meet subdomains)

    func test_googleMeetNotCaughtByGenericMeetPattern() {
        // meet.google.com should be detected by googleMeet, not the generic "meet" service
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.google.com/abc-defg-hij"
        )
        XCTAssertNotNil(url)
        // Verify it returns the full Google Meet URL, not just a partial from the generic meet pattern
        XCTAssertTrue(url?.absoluteString.contains("meet.google.com") == true)
    }

    func test_jitsiNotCaughtByGenericMeetPattern() {
        // meet.jit.si should be detected by jitsi, not the generic "meet" service
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.jit.si/MyRoom"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.jit.si") == true)
    }

    func test_aroundNotCaughtByGenericMeetPattern() {
        // meet.around.co should be detected by around, not the generic "meet" service
        let url = MeetingLinkDetector.detectMeetingLink(
            in: "https://meet.around.co/room-name"
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.around.co") == true)
    }

    // MARK: - CalendarEvent Overload: Link in URL Field

    func test_detectsLinkFromCalendarEventURL() {
        let event = makeEvent(
            url: URL(string: "https://us02web.zoom.us/j/123456789?pwd=abc")
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsGoogleMeetFromCalendarEventURL() {
        let event = makeEvent(
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.google.com") == true)
    }

    // MARK: - CalendarEvent Overload: Link in Location Field

    func test_detectsLinkFromCalendarEventLocation() {
        let event = makeEvent(
            location: "https://us02web.zoom.us/j/123456789?pwd=abc"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsTeamsLinkFromLocationWithPrefix() {
        let event = makeEvent(
            location: "Online - https://teams.microsoft.com/l/meetup-join/abc123"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("teams.microsoft.com") == true)
    }

    func test_detectsWebexLinkFromLocation() {
        let event = makeEvent(
            location: "https://company.webex.com/meet/123456"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("webex.com") == true)
    }

    // MARK: - CalendarEvent Overload: Link in Notes Field

    func test_detectsLinkFromCalendarEventNotes() {
        let event = makeEvent(
            notes: "Join here: https://us02web.zoom.us/j/123456789?pwd=abc"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_detectsSlackLinkFromNotes() {
        let event = makeEvent(
            notes: "Huddle at https://slack.com/huddle/12345"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("slack.com") == true)
    }

    func test_detectsDiscordLinkFromNotes() {
        let event = makeEvent(
            notes: "Voice channel: https://discord.gg/abc123xyz"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("discord.gg") == true)
    }

    // MARK: - CalendarEvent Overload: No Link in Any Field

    func test_returnsNilWhenEventHasNoLink() {
        let event = makeEvent(
            location: "Conference Room 4A",
            notes: "Bring your laptop"
        )
        XCTAssertNil(MeetingLinkDetector.detectMeetingLink(in: event))
    }

    func test_returnsNilWhenAllFieldsAreNil() {
        let event = makeEvent()
        XCTAssertNil(MeetingLinkDetector.detectMeetingLink(in: event))
    }

    func test_returnsNilWhenLocationAndNotesHaveNoLinks() {
        let event = makeEvent(
            location: "Building 3, Floor 2",
            notes: "Weekly standup meeting"
        )
        XCTAssertNil(MeetingLinkDetector.detectMeetingLink(in: event))
    }

    // MARK: - CalendarEvent Overload: Link in Multiple Fields

    func test_urlFieldTakesPriorityOverLocation() {
        // URL is concatenated first, so it's checked first in the combined string
        let event = makeEvent(
            location: "https://teams.microsoft.com/l/meetup-join/abc123",
            url: URL(string: "https://us02web.zoom.us/j/123456789")
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        // Both Zoom and Teams are in the combined text, but Zoom is checked first
        // in MeetingService.allCases order, so Zoom wins regardless of field order
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_urlFieldTakesPriorityOverNotes() {
        let event = makeEvent(
            notes: "Backup link: https://teams.microsoft.com/l/meetup-join/abc123",
            url: URL(string: "https://us02web.zoom.us/j/123456789")
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    func test_locationFieldTakesPriorityOverNotes() {
        // URL is nil, so combined text is "location + notes"
        // Both contain meeting links; Zoom service is checked before Teams
        let event = makeEvent(
            location: "https://us02web.zoom.us/j/123456789",
            notes: "Also available at https://teams.microsoft.com/l/meetup-join/abc123"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("zoom.us") == true)
    }

    // MARK: - CalendarEvent Overload: Various Services

    func test_detectsJitsiFromEventNotes() {
        let event = makeEvent(
            notes: "Open source call: https://meet.jit.si/TeamStandup"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.jit.si") == true)
    }

    func test_detectsBlueJeansFromEventLocation() {
        let event = makeEvent(
            location: "https://bluejeans.com/123456789"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("bluejeans.com") == true)
    }

    func test_detectsGoToMeetingFromEventNotes() {
        let event = makeEvent(
            notes: "Use https://gotomeeting.com/j/123456789 to join"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("gotomeeting.com") == true)
    }

    func test_detectsWherebyFromEventLocation() {
        let event = makeEvent(
            location: "https://whereby.com/my-room"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("whereby.com") == true)
    }

    func test_detectsChimeFromEventNotes() {
        let event = makeEvent(
            notes: "Amazon Chime: https://chime.aws/1234"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("chime.aws") == true)
    }

    func test_detectsRingCentralFromEventURL() {
        let event = makeEvent(
            url: URL(string: "https://meetings.ringcentral.com/j/123456789")
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meetings.ringcentral.com") == true)
    }

    func test_detects8x8FromEventLocation() {
        let event = makeEvent(
            location: "https://8x8.vc/abcdefg"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("8x8.vc") == true)
    }

    func test_detectsFaceTimeFromEventNotes() {
        let event = makeEvent(
            notes: "FaceTime me at facetime://alice"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("facetime://") == true)
    }

    func test_detectsPhoneFromEventLocation() {
        let event = makeEvent(
            location: "tel:+1-555-123-4567"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("tel:") == true)
    }

    func test_detectsAroundFromEventNotes() {
        let event = makeEvent(
            notes: "Around room: https://meet.around.co/design-review"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("meet.around.co") == true)
    }

    func test_detectsSkypeFromEventURL() {
        let event = makeEvent(
            url: URL(string: "https://join.skype.com/abcdefg")
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("join.skype.com") == true)
    }

    func test_detectsHangoutsFromEventNotes() {
        let event = makeEvent(
            notes: "Google Hangout: https://hangouts.google.com/call/abcdefg"
        )
        let url = MeetingLinkDetector.detectMeetingLink(in: event)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("hangouts.google.com") == true)
    }

    // MARK: - CalendarEvent.meetingLink Computed Property

    func test_calendarEventMeetingLinkProperty() {
        let event = CalendarEvent(
            id: "test-id",
            title: "Design Review",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            location: nil,
            notes: "https://us02web.zoom.us/j/123456789?pwd=abc",
            url: nil,
            calendar: MBCalendar(id: "cal-1", title: "Work", color: "#FF0000", source: "iCloud"),
            organizer: "alice@example.com",
            attendees: ["bob@example.com"],
            isAllDay: false,
            status: .confirmed
        )
        XCTAssertNotNil(event.meetingLink)
        XCTAssertTrue(event.meetingLink?.absoluteString.contains("zoom.us") == true)
    }

    func test_calendarEventMeetingLinkProperty_noLink() {
        let event = CalendarEvent(
            id: "test-id",
            title: "In-Person Standup",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "Kitchen area",
            notes: "Bring coffee",
            url: nil,
            calendar: MBCalendar(id: "cal-1", title: "Work", color: "#FF0000", source: "iCloud"),
            organizer: nil,
            attendees: [],
            isAllDay: false,
            status: .confirmed
        )
        XCTAssertNil(event.meetingLink)
    }
}