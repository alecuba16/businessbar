import AppIntents
import AppKit
import BusinessBarCore
import Foundation

struct ToggleNoSleepIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle NoSleep"
    static var description = IntentDescription("Toggles the NoSleep feature on or off")
    static var openAppWhenRun: Bool = false
    
    func perform() async throws -> some IntentResult {
        let isFeatureEnabled = await MainActor.run {
            UserDefaults.standard.bool(forKey: Constants.Defaults.featureNoSleep)
        }
        guard isFeatureEnabled else { throw IntentError.featureDisabled }

        let newState = try await MainActor.run { () throws -> Bool in
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
                  let noSleepManager = appDelegate.getNoSleepManager() else {
                throw IntentError.managerNotAvailable
            }
            noSleepManager.toggle()
            return noSleepManager.isActive
        }
        
        let message: LocalizedStringResource = newState ? "NoSleep activated" : "NoSleep deactivated"
        return .result(dialog: IntentDialog(message))
    }
    
    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case featureDisabled
        case managerNotAvailable
        
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .featureDisabled:
                return "NoSleep feature is disabled"
            case .managerNotAvailable:
                return "NoSleep manager not available"
            }
        }
    }
}
