import Foundation

// MARK: - MLXServerConfig

/// UserDefaults-backed settings for the local MLX server. Read on every
/// spawn so preference edits apply to the next start without a restart.
public enum MLXServerConfig {
    public static let defaultPort = 8790
    public static let defaultIdleMinutes = 5

    // Keys live beside the settings, not in a shared table: only this
    // file and the preferences tab reference them.
    private static let portKey = "companionMLXPort"
    private static let idleMinutesKey = "companionMLXIdleMinutes"
    private static let keepLoadedKey = "companionMLXKeepLoaded"
    private static let activeModelKey = "companionMLXActiveModel"

    public static func port() -> Int {
        let raw = UserDefaults.standard.integer(forKey: portKey)
        return (1...65_535).contains(raw) ? raw : defaultPort
    }

    public static func setPort(_ port: Int) {
        let safe = (1...65_535).contains(port) ? port : defaultPort
        UserDefaults.standard.set(safe, forKey: portKey)
    }

    public static func idleMinutes() -> Int {
        let raw = UserDefaults.standard.integer(forKey: idleMinutesKey)
        return raw > 0 ? raw : defaultIdleMinutes
    }

    public static func setIdleMinutes(_ minutes: Int) {
        UserDefaults.standard.set(max(1, minutes), forKey: idleMinutesKey)
    }

    /// Disables the idle auto-stop timer. Off by default: a loaded model
    /// holds wired memory that nothing else can use.
    public static func keepLoaded() -> Bool {
        UserDefaults.standard.bool(forKey: keepLoadedKey)
    }

    public static func setKeepLoaded(_ keep: Bool) {
        UserDefaults.standard.set(keep, forKey: keepLoadedKey)
    }

    /// Repo id of the model the local server serves and the preset profile
    /// points at. Nil until the user picks one.
    public static func activeModelID() -> String? {
        UserDefaults.standard.string(forKey: activeModelKey)
    }

    public static func setActiveModelID(_ id: String?) {
        UserDefaults.standard.set(id, forKey: activeModelKey)
    }

    /// The base URL the preset profile uses. Kept in sync with the port.
    public static func baseURLString() -> String {
        "http://127.0.0.1:\(port())/v1"
    }
}