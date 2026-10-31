import Sparkle
import SwiftUI

@MainActor
protocol UpdaterBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func start() throws
    func checkForUpdates()
}

@MainActor
final class UpdaterViewModel: ObservableObject {
    private let backend: any UpdaterBackend
    private var updaterStarted = false

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            backend.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            if automaticallyChecksForUpdates { startUpdaterIfNeeded() }
        }
    }

    var canCheckForUpdates: Bool { updaterStarted && backend.canCheckForUpdates }

    convenience init() {
        self.init(backend: SparkleUpdaterBackend())
    }

    init(backend: any UpdaterBackend) {
        self.backend = backend
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        startUpdaterIfNeeded()
        backend.checkForUpdates()
    }

    private func startUpdaterIfNeeded() {
        guard !updaterStarted else { return }
        try? backend.start()
        updaterStarted = true
    }
}

@MainActor
private final class SparkleUpdaterBackend: UpdaterBackend {
    private let controller: SPUStandardUpdaterController
    // Sparkle retains its delegate weakly.
    private let delegate = UpdaterDelegate()

    init() {
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    func start() throws { try controller.updater.start() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }
}
