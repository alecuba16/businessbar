import AppAuth
import AppKit
import Foundation
import os.log

// MARK: - Configuration
//
// Google OAuth credentials are loaded at runtime from JSON resource files
// by CredentialLoader:
//   • credentials.local.json — local dev override (gitignored)
//   • credentials.json      — bundled default (placeholders or real in release)
//
// For release builds, bundle_app.sh / CI bake real values into
// credentials.json.  For local debug, credentials.local.json takes
// precedence.  See credentials.local.json.example for setup instructions.
//
enum GoogleAuthConfig {
    static let clientNumber = CredentialLoader.googleClientNumber
    static let clientSecret = CredentialLoader.googleClientSecret
    static let keychainKey  = "com.businessbar.app.googleAuthState"

    // Derived — do not edit these.
    static var clientID:    String { "\(clientNumber).apps.googleusercontent.com" }
    static var redirectURI: String { "com.googleusercontent.apps.\(clientNumber):/oauthredirect" }
    static let issuer = URL(string: "https://accounts.google.com")!

    static let scopes = [
        "email",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly"
    ]

    /// True only when real credentials are available (from .local.json or baked-in .json).
    static var isConfigured: Bool {
        !clientNumber.hasPrefix("YOUR_") && !clientSecret.hasPrefix("YOUR_")
    }
}

// MARK: - OIDAuthState helpers

extension OIDAuthState {
    /// Token is considered fresh if it expires more than 5 minutes from now.
    var isTokenFresh: Bool {
        guard let exp = lastTokenResponse?.accessTokenExpirationDate else { return false }
        return exp > Date().addingTimeInterval(300)
    }

    /// Email decoded from the JWT ID token — no signature verification needed.
    var userEmail: String? {
        guard let idToken = lastTokenResponse?.idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }
}

// MARK: - GoogleAuth
//
// Implements OIDExternalUserAgent so the OAuth flow uses the system browser
// (Safari / Chrome / etc.) rather than an embedded WKWebView or a modal sheet.
// The browser redirect back to the app is received by AppDelegate via the
// registered CFBundleURLTypes URL scheme and forwarded here via
// `resumeExternalUserAgentFlow(with:)`.
//
@MainActor
final class GoogleAuth: NSObject, ObservableObject,
                        @preconcurrency OIDExternalUserAgent,
                        @preconcurrency OIDAuthStateChangeDelegate,
                        @preconcurrency OIDAuthStateErrorDelegate {

    private static let logger = Logger(subsystem: "com.businessbar.app", category: "GoogleAuth")

    // MARK: Published state
    @Published private(set) var isAuthenticated = false
    @Published private(set) var userEmail: String?

    // MARK: Private state
    private(set) var currentAuthorizationFlow: OIDExternalUserAgentSession?

    private var authState: OIDAuthState? {
        didSet {
            authState?.stateChangeDelegate = self
            authState?.errorDelegate = self
            isAuthenticated = authState?.isAuthorized ?? false
            userEmail = authState?.userEmail
            persistAuthState()
        }
    }

    // Deduplicate concurrent sign-in / refresh requests.
    private var signInTask: Task<Void, Error>?
    private var refreshTask: Task<String, Error>?

    // MARK: Init
    override init() {
        super.init()
        if let restored = restoreAuthState() {
            Self.logger.info("Restored existing Google auth state — authenticated: \(restored.isAuthorized)")
            // Set directly to avoid triggering persistAuthState() on restore.
            self.authState = restored
            self.authState?.stateChangeDelegate = self
            self.authState?.errorDelegate = self
            self.isAuthenticated = restored.isAuthorized
            self.userEmail = restored.userEmail
        } else {
            Self.logger.info("No existing Google auth state found")
        }
    }

    // MARK: - Public API

    func signIn(forcePrompt: Bool = false) async throws {
        guard GoogleAuthConfig.isConfigured else {
            Self.logger.error("Sign-in attempted but Google OAuth not configured")
            throw GoogleAuthError.notConfigured
        }
        guard let redirectURL = URL(string: GoogleAuthConfig.redirectURI) else {
            Self.logger.error("Sign-in attempted but redirect URI is invalid")
            throw GoogleAuthError.notConfigured
        }

        if authState?.isAuthorized == true {
            Self.logger.info("Already authenticated — skipping sign-in")
            return
        }
        Self.logger.info("Starting Google sign-in flow (forcePrompt: \(forcePrompt))")

        // Discover OIDC configuration for the Google issuer.
        let config = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OIDServiceConfiguration, Error>) in
            OIDAuthorizationService.discoverConfiguration(forIssuer: GoogleAuthConfig.issuer) { cfg, err in
                if let cfg { cont.resume(returning: cfg) }
                else { cont.resume(throwing: err ?? GoogleAuthError.discoveryFailed) }
            }
        }

        var extra: [String: String] = ["access_type": "offline"]
        if forcePrompt { extra["prompt"] = "consent" }

        let request = OIDAuthorizationRequest(
            configuration: config,
            clientId: GoogleAuthConfig.clientID,
            clientSecret: GoogleAuthConfig.clientSecret,
            scopes: GoogleAuthConfig.scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: extra
        )

        // OIDAuthState.authState(byPresenting:externalUserAgent:) calls
        // self.present(_:session:) → we open the system browser there.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                externalUserAgent: self
            ) { [weak self] state, error in
                guard let self else { return }
                if let state {
                    Self.logger.info("Google sign-in successful — authenticated: \(state.isAuthorized)")
                    self.authState = state
                    cont.resume()
                } else {
                    Self.logger.error("Google sign-in failed: \(error?.localizedDescription ?? "unknown error")")
                    cont.resume(throwing: error ?? GoogleAuthError.authorizationFailed)
                }
            }
        }
    }

    func signOut() {
        Self.logger.info("Signing out of Google")
        currentAuthorizationFlow?.cancel()
        currentAuthorizationFlow = nil

        // Revoke tokens best-effort in the background.
        let access  = authState?.lastTokenResponse?.accessToken
        let refresh = authState?.lastTokenResponse?.refreshToken
        Task {
            if let t = access  { try? await self.revoke(token: t) }
            if let t = refresh { try? await self.revoke(token: t) }
        }

        clearAuthState()
    }

    /// Called by AppDelegate when the OS routes the OAuth redirect URL back.
    func resumeAuthorizationFlow(with url: URL) {
        currentAuthorizationFlow?.resumeExternalUserAgentFlow(with: url)
    }

    /// Performs an authenticated GET and returns the raw Data.
    func performRequest(url: URL) async throws -> Data {
        let token = try await validAccessToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            if (http.statusCode == 401 || http.statusCode == 403) {
                clearAuthState()
                throw GoogleAuthError.notAuthenticated
            }
            throw GoogleAuthError.apiError("HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - OIDExternalUserAgent

    /// Open the authorization URL in the system default browser.
    /// No window or sheet is needed — the redirect comes back via URL scheme.
    func present(_ request: OIDExternalUserAgentRequest,
                 session: OIDExternalUserAgentSession) -> Bool {
        guard let url = request.externalUserAgentRequestURL() else { return false }
        return NSWorkspace.shared.open(url)
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        completion()
    }

    // MARK: - OIDAuthState delegates

    func didChange(_ state: OIDAuthState) {
        persistAuthState()
    }

    func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: Error) {
        let err = error as NSError
        Self.logger.error("Google auth state encountered authorization error: domain=\(err.domain), code=\(err.code)")
        if err.domain == OIDOAuthTokenErrorDomain {
            Self.logger.critical("OAuth token error — clearing auth state")
            clearAuthState()
        }
    }

    // MARK: - Token management

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let state = authState else { throw GoogleAuthError.notAuthenticated }

        if !forceRefresh, state.isTokenFresh,
           let token = state.lastTokenResponse?.accessToken {
            return token
        }

        if let running = refreshTask { return try await running.value }

        let task = Task<String, Error> {
            defer { self.refreshTask = nil }
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                if forceRefresh { state.setNeedsTokenRefresh() }
                state.performAction { [weak self] accessToken, _, error in
                    if let token = accessToken {
                        cont.resume(returning: token)
                    } else {
                        if let err = error as NSError?,
                                   err.domain == OIDOAuthTokenErrorDomain {
                                    Self.logger.error("Token refresh failed with OAuth error — clearing auth state")
                                    self?.clearAuthState()
                                } else {
                                    Self.logger.error("Token refresh failed: \(error?.localizedDescription ?? "unknown")")
                                }
                                cont.resume(throwing: error ?? GoogleAuthError.refreshFailed)
                    }
                }
            }
        }
        refreshTask = task
        return try await task.value
    }

    // MARK: - Keychain persistence

    private func persistAuthState() {
        guard let state = authState else {
            do {
                try KeychainHelper.delete(key: GoogleAuthConfig.keychainKey)
            } catch {
                Self.logger.error("Failed to delete keychain entry during clear: \(error.localizedDescription)")
            }
            return
        }
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: state, requiringSecureCoding: true
        ) else {
            Self.logger.error("Failed to archive auth state for keychain persistence")
            return
        }
        do {
            try KeychainHelper.save(key: GoogleAuthConfig.keychainKey, data: data)
        } catch {
            Self.logger.error("Failed to save auth state to keychain: \(error.localizedDescription)")
        }
    }

    private func restoreAuthState() -> OIDAuthState? {
        let data: Data
        do {
            data = try KeychainHelper.load(key: GoogleAuthConfig.keychainKey)
        } catch {
            Self.logger.info("No saved Google auth state in keychain (expected on first launch)")
            return nil
        }
        do {
            let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
            if state != nil {
                Self.logger.info("Successfully restored Google auth state from keychain")
            }
            return state
        } catch {
            Self.logger.error("Failed to unarchive Google auth state from keychain: \(error.localizedDescription) — clearing corrupted state")
            try? KeychainHelper.delete(key: GoogleAuthConfig.keychainKey)
            return nil
        }
    }

    private func clearAuthState() {
        Self.logger.info("Clearing Google auth state")
        authState = nil
        userEmail = nil
        isAuthenticated = false
        do {
            try KeychainHelper.delete(key: GoogleAuthConfig.keychainKey)
        } catch {
            Self.logger.error("Failed to delete keychain entry during auth state clear: \(error.localizedDescription)")
        }
    }

    // MARK: - Token revocation

    private func revoke(token: String) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("token=\(token)".utf8)
        _ = try await URLSession.shared.data(for: req)
    }
}

// MARK: - Errors

enum GoogleAuthError: LocalizedError {
    case notConfigured
    case discoveryFailed
    case authorizationFailed
    case notAuthenticated
    case refreshFailed
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return "Google OAuth credentials not configured. See credentials.local.json.example for setup instructions."
        case .discoveryFailed:    return "Failed to discover Google OAuth configuration"
        case .authorizationFailed: return "Google authorization failed"
        case .notAuthenticated:   return "Not signed in to Google"
        case .refreshFailed:      return "Failed to refresh Google access token"
        case .apiError(let msg):  return "Google API error: \(msg)"
        }
    }
}
