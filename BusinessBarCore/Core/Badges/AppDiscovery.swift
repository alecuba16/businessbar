import AppKit
import Foundation

public final class AppDiscovery {
    public static func apps(at paths: [String]) -> [MonitoredApp] {
        paths.compactMap { path -> MonitoredApp? in
            guard let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier else { return nil }
            let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleName"] as? String
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return MonitoredApp(bundleIdentifier: identifier, displayName: name, iconPath: path)
        }.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

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

                    var paths: [String] = []

                    for i in 0 ..< query.resultCount {
                        guard
                            let item = query.result(at: i) as? NSMetadataItem,
                            let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                        else { continue }

                        paths.append(path)
                    }

                    continuation.resume(returning: apps(at: paths))
                }

                query.start()
            }
        }
    }
}
