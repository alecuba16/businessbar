import AppIntents
import AppKit
import BusinessBarCore
import Foundation

struct JoinNextMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Join Next Meeting"
    static var description = IntentDescription("Opens the meeting link for your next scheduled event")
    static var openAppWhenRun: Bool = false
    private var featureEnabled: @MainActor () -> Bool
    private var nextEvent: @MainActor () -> CalendarEvent?
    private var openMeeting: @MainActor (URL) -> Void

    init() {
        featureEnabled = { UserDefaults.standard.bool(forKey: Constants.Defaults.featureCalendar) }
        nextEvent = { (NSApplication.shared.delegate as? AppDelegate)?.getMeetingManager()?.nextEvent }
        openMeeting = { NSWorkspace.shared.open($0) }
    }

    init(
        featureEnabled: @escaping @MainActor () -> Bool,
        nextEvent: @escaping @MainActor () -> CalendarEvent?,
        openMeeting: @escaping @MainActor (URL) -> Void
    ) {
        self.featureEnabled = featureEnabled
        self.nextEvent = nextEvent
        self.openMeeting = openMeeting
    }
    
    func perform() async throws -> some IntentResult {
        let isFeatureEnabled = await MainActor.run {
            featureEnabled()
        }
        guard isFeatureEnabled else { throw IntentError.featureDisabled }

        guard let (nextEvent, meetingLink) = await MainActor.run(body: { () -> (CalendarEvent, URL)? in
            guard let nextEvent = self.nextEvent(),
                  let meetingLink = nextEvent.meetingLink else {
                return nil
            }
            return (nextEvent, meetingLink)
        }) else {
            throw IntentError.noMeeting
        }
        
        _ = await MainActor.run {
            openMeeting(meetingLink)
        }
        
        return .result(dialog: "Opening \(nextEvent.title)")
    }
    
    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case featureDisabled
        case noMeeting
        
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .featureDisabled:
                return "Calendar feature is disabled"
            case .noMeeting:
                return "No upcoming meeting found or meeting has no link"
            }
        }
    }
}
