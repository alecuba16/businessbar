import AppIntents
import AppKit
import BusinessBarCore
import Foundation

struct ToggleNoSleepIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle NoSleep"
    static var description = IntentDescription("Toggles the NoSleep feature on or off")
    static var openAppWhenRun: Bool = false
    private var featureEnabled: @MainActor () -> Bool
    private var toggle: @MainActor () throws -> Bool

    init() {
        featureEnabled = { UserDefaults.standard.bool(forKey: Constants.Defaults.featureNoSleep) }
        toggle = {
            guard let manager = (NSApplication.shared.delegate as? AppDelegate)?.getNoSleepManager() else {
                throw IntentError.managerNotAvailable
            }
            manager.toggle()
            return manager.isActive
        }
    }

    init(featureEnabled: @escaping @MainActor () -> Bool, toggle: @escaping @MainActor () throws -> Bool) {
        self.featureEnabled = featureEnabled
        self.toggle = toggle
    }
    
    func perform() async throws -> some IntentResult {
        let isFeatureEnabled = await MainActor.run {
            featureEnabled()
        }
        guard isFeatureEnabled else { throw IntentError.featureDisabled }

        let newState = try await MainActor.run { () throws -> Bool in
            try toggle()
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
