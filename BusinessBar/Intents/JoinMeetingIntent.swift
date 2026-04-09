import AppIntents
import AppKit
import BusinessBarCore
import Foundation

struct JoinNextMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Join Next Meeting"
    static var description = IntentDescription("Opens the meeting link for your next scheduled event")
    static var openAppWhenRun: Bool = false
    
    func perform() async throws -> some IntentResult {
        let isFeatureEnabled = await MainActor.run {
            UserDefaults.standard.bool(forKey: Constants.Defaults.featureCalendar)
        }
        guard isFeatureEnabled else { throw IntentError.featureDisabled }

        // Access the meeting manager from the app delegate
        guard let (nextEvent, meetingLink) = await MainActor.run(body: { () -> (CalendarEvent, URL)? in
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
                  let meetingManager = appDelegate.getMeetingManager(),
                  let nextEvent = meetingManager.nextEvent,
                  let meetingLink = nextEvent.meetingLink else {
                return nil
            }
            return (nextEvent, meetingLink)
        }) else {
            throw IntentError.noMeeting
        }
        
        _ = await MainActor.run {
            NSWorkspace.shared.open(meetingLink)
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
