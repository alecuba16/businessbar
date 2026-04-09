import Foundation

/// Loads credentials at runtime from bundled JSON resource files.
///
/// Resolution order:
///   1. `credentials.local.json` — real values for local development (gitignored)
///   2. `credentials.json`      — default file bundled with the app
///
/// For release builds, `bundle_app.sh` or CI bakes real values into
/// `credentials.json`, so no `.local.json` file is needed.
///
/// For local debug (`swift run`), the `.local.json` file lives in the
/// project's Resources directory on disk.  SPM includes it in the
/// resource bundle automatically when it exists, so `Bundle.main` finds it.
enum CredentialLoader {

    // MARK: - Public API

    /// Cached result of the credential lookup.
    private static let resolved: CredentialValues = load()

    /// Google OAuth credentials resolved at startup.
    static var googleClientNumber: String { resolved.googleClientNumber }
    static var googleClientSecret: String { resolved.googleClientSecret }

    // MARK: - Model

    struct CredentialValues {
        var googleClientNumber: String
        var googleClientSecret: String
    }

    // MARK: - Loading

    private static func load() -> CredentialValues {
        // 1. Try credentials.local.json (local dev override)
        if let url = Bundle.main.url(forResource: "credentials.local", withExtension: "json"),
           let values = parseJSON(url) {
            AppLogger.debug("Loaded credentials from credentials.local.json", category: "Credentials")
            return values
        }

        // 2. Try credentials.json (bundled default — real in release, placeholder in debug)
        if let url = Bundle.main.url(forResource: "credentials", withExtension: "json"),
           let values = parseJSON(url) {
            let isPlaceholder = values.googleClientNumber.hasPrefix("YOUR_")
            AppLogger.debug("Loaded credentials from credentials.json (placeholder: \(isPlaceholder))", category: "Credentials")
            return values
        }

        // 3. Fallback — neither file found (shouldn't happen in a properly built app)
        AppLogger.warning("No credentials file found in bundle", category: "Credentials")
        return CredentialValues(
            googleClientNumber: "YOUR_GOOGLE_CLIENT_NUMBER",
            googleClientSecret: "YOUR_GOOGLE_CLIENT_SECRET"
        )
    }

    // MARK: - JSON Parsing

    private static func parseJSON(_ url: URL) -> CredentialValues? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLogger.error("Failed to read credentials file: \(error.localizedDescription)", category: "Credentials")
            return nil
        }

        let json: [String: Any]
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            json = dict
        } catch {
            AppLogger.error("Failed to parse credentials JSON: \(error.localizedDescription)", category: "Credentials")
            return nil
        }

        return CredentialValues(
            googleClientNumber: json["google_client_number"] as? String ?? "YOUR_GOOGLE_CLIENT_NUMBER",
            googleClientSecret: json["google_client_secret"] as? String ?? "YOUR_GOOGLE_CLIENT_SECRET"
        )
    }
}