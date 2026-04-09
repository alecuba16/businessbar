import Sparkle
import SwiftUI

// MARK: - UpdaterViewModel
// A thin ObservableObject wrapper around SPUUpdater that exposes the
// properties SwiftUI's GeneralTab needs (automatic-check toggle, manual
// check button) without leaking Sparkle types into the view layer.

@MainActor
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    // SPUStandardUpdaterController holds a weak reference to the delegate,
    // so we must own it here to keep it alive for the app's lifetime.
    private let updaterDelegate = UpdaterDelegate()

    /// Tracks whether SPUUpdater.start() has been called.
    /// The updater is started lazily — only when the user enables automatic
    /// checks or explicitly triggers a manual check — to avoid any Sparkle
    /// network activity (or permission dialogs) at app launch.
    private var updaterStarted = false

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            if automaticallyChecksForUpdates {
                startUpdaterIfNeeded()
            }
        }
    }

    var canCheckForUpdates: Bool {
        updaterStarted && updaterController.updater.canCheckForUpdates
    }

    init() {
        // Write false to the PERSISTENT domain before Sparkle starts.
        // registerDefaults() only sets a fallback in the registration domain,
        // which Sparkle 2.x bypasses when deciding whether to do a first-launch
        // check. An explicit set() here ensures Sparkle sees false from the start.
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
        }

        let delegate = updaterDelegate
        // startingUpdater: false — defer SPUUpdater.start() so Sparkle does
        // not perform any network activity or show any UI at app launch.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        updaterController = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        startUpdaterIfNeeded()
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Private

    private func startUpdaterIfNeeded() {
        guard !updaterStarted else { return }
        try? updaterController.updater.start()
        updaterStarted = true
    }
}

// MARK: - UpdaterDelegate

// NSObject subclass so it can be passed as an Objective-C delegate.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Suppress Sparkle 2.x's first-launch "enable automatic updates?" prompt.
    /// Without this, Sparkle shows the dialog regardless of SUEnableAutomaticChecks
    /// if it has never recorded the user's answer in the persistent domain.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        return false
    }
}
