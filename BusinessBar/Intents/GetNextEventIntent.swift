import AppIntents
import AppKit
import BusinessBarCore
import Foundation

struct GetNextEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Next Event"
    static var description = IntentDescription("Returns details about your next scheduled calendar event")
    static var openAppWhenRun: Bool = false
    private var featureEnabled: @MainActor () -> Bool
    private var nextEvent: @MainActor () -> CalendarEvent?

    init() {
        featureEnabled = { UserDefaults.standard.bool(forKey: Constants.Defaults.featureCalendar) }
        nextEvent = {
            (NSApplication.shared.delegate as? AppDelegate)?.getMeetingManager()?.nextEvent
        }
    }

    init(featureEnabled: @escaping @MainActor () -> Bool, nextEvent: @escaping @MainActor () -> CalendarEvent?) {
        self.featureEnabled = featureEnabled
        self.nextEvent = nextEvent
    }
    
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let isFeatureEnabled = await MainActor.run {
            featureEnabled()
        }
        guard isFeatureEnabled else { throw IntentError.featureDisabled }

        guard let nextEvent = await MainActor.run(body: { () -> CalendarEvent? in
            self.nextEvent()
        }) else {
            throw IntentError.noEvent
        }
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        let startTime = timeFormatter.string(from: nextEvent.startDate)
        let endTime = timeFormatter.string(from: nextEvent.endDate)
        
        let eventInfo = """
        \(nextEvent.title)
        Time: \(startTime) - \(endTime)
        \(nextEvent.location != nil ? "Location: \(nextEvent.location!)" : "")
        """
        
        return .result(value: eventInfo, dialog: "Your next event is \(nextEvent.title) at \(startTime)")
    }
    
    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case featureDisabled
        case noEvent
        
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .featureDisabled:
                return "Calendar feature is disabled"
            case .noEvent:
                return "No upcoming events found"
            }
        }
    }
}
