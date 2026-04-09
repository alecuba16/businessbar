import AppKit
import Foundation

public final class AppDiscovery {

    /// Discovers all installed `.app` bundles via `NSMetadataQuery`.
    /// The query **must** run on the main thread (it needs a RunLoop); we
    /// dispatch there explicitly and resume the async continuation once
    /// `NSMetadataQueryDidFinishGathering` fires.
    public static func findInstalledApps() async -> [MonitoredApp] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let query = NSMetadataQuery()
                query.predicate = NSPredicate(
                    format: "kMDItemContentType == 'com.apple.application-bundle'"
                )
                query.searchScopes = [
                    "/Applications",
                    "/System/Applications",
                    NSHomeDirectory() + "/Applications"
                ]

                var observerToken: NSObjectProtocol?
                observerToken = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: query,
                    queue: .main
                ) { _ in
                    if let token = observerToken {
                        NotificationCenter.default.removeObserver(token)
                        observerToken = nil
                    }

                    query.disableUpdates()
                    query.stop()

                    var apps: [MonitoredApp] = []

                    for i in 0 ..< query.resultCount {
                        guard
                            let item = query.result(at: i) as? NSMetadataItem,
                            let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                        else { continue }

                        guard let bundle = Bundle(path: path),
                              let bundleID = bundle.bundleIdentifier
                        else { continue }

                        // Prefer CFBundleDisplayName, fall back to CFBundleName, then
                        // the last path component without extension.
                        let displayName: String =
                            bundle.infoDictionary?["CFBundleDisplayName"] as? String
                            ?? bundle.infoDictionary?["CFBundleName"] as? String
                            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

                        let app = MonitoredApp(
                            bundleIdentifier: bundleID,
                            displayName: displayName,
                            iconPath: path   // MonitoredApp.icon resolves via NSWorkspace
                        )
                        apps.append(app)
                    }

                    let sorted = apps.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
                    continuation.resume(returning: sorted)
                }

                query.start()
            }
        }
    }
}
