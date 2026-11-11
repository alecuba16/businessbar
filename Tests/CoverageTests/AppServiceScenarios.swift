import AppAuth
import AppKit
import BusinessBarCore
import Carbon
import Foundation
import KeyboardShortcuts
import Security
import UserNotifications
@testable import BusinessBar

@MainActor
enum AppServiceScenarios {
    private enum FixtureError: Error { case unavailable }

    private final class Updater: UpdaterBackend {
        var automaticallyChecksForUpdates = false
        var canCheckForUpdates = true
        var starts = 0
        var checks = 0
        var failsStart = false
        func start() throws {
            starts += 1
            if failsStart { throw FixtureError.unavailable }
        }
        func checkForUpdates() { checks += 1 }
    }

    private final class AuthorizationSession: NSObject, OIDExternalUserAgentSession {
        var cancellations = 0
        var resumed: [URL] = []
        func cancel() { cancellations += 1 }
        func cancel(completion: (() -> Void)?) { cancel(); completion?() }
        func resumeExternalUserAgentFlow(with url: URL) -> Bool {
            resumed.append(url)
            return true
        }
        func failExternalUserAgentFlowWithError(_ error: Error) {}
    }

    static func run(_ context: CoverageContext) async throws {
        try keychain(context)
        try credentials(context)
        try await authentication(context)
        try await oauth(context)
        try updaterAndLifecycle(context)
        try await calendars(context)
        try await gcRespond(context)
        try await notifications(context)
        try await rsvpNotifications(context)
        try await lifecycle(context)
        try await appDelegateLiveClosures(context)
    }

    private static func keychain(_ context: CoverageContext) throws {
        let payload = Data("fixture-credential".utf8)
        var calls: [String] = []
        var queries: [[String: Any]] = []
        var status = errSecSuccess
        var result: AnyObject? = payload as NSData
        let operations = KeychainHelper.Operations(
            add: { query in
                calls.append("add")
                queries.append(query as! [String: Any])
                return status
            },
            copy: { query in
                calls.append("copy")
                queries.append(query as! [String: Any])
                return (status, result)
            },
            delete: { query in
                calls.append("delete")
                queries.append(query as! [String: Any])
                return status
            }
        )
        try KeychainHelper.save(key: "coverage-only", data: payload, operations: operations)
        try context.equal(calls, ["delete", "add"], "Saving replaces the existing credential")
        try context.equal(queries.last?[kSecAttrAccount as String] as? String, "coverage-only", "Account is passed to Security")
        try context.equal(queries.last?[kSecValueData as String] as? Data, payload, "Payload is passed to Security")
        let loaded = try KeychainHelper.load(key: "coverage-only", operations: operations)
        try context.equal(loaded, payload, "Load returns Security data")
        try context.equal(queries.last?[kSecReturnData as String] as? Bool, true, "Load requests credential data")
        result = "not data" as NSString
        try context.expectThrows("Non-data results are rejected") {
            _ = try KeychainHelper.load(key: "coverage-only", operations: operations)
        }
        status = errSecAuthFailed
        try context.expectThrows("Save failures propagate") {
            try KeychainHelper.save(key: "coverage-only", data: payload, operations: operations)
        }
        try context.expectThrows("Load failures propagate") {
            _ = try KeychainHelper.load(key: "coverage-only", operations: operations)
        }
        try context.expectThrows("Delete failures propagate") {
            try KeychainHelper.delete(key: "coverage-only", operations: operations)
        }
        status = errSecItemNotFound
        try KeychainHelper.delete(key: "coverage-only", operations: operations)
        status = errSecSuccess
        try KeychainHelper.delete(key: "coverage-only", operations: operations)
    }

    private static func credentials(_ context: CoverageContext) throws {
        let local = URL(fileURLWithPath: "/fixture/credentials.local.json")
        let bundled = URL(fileURLWithPath: "/fixture/credentials.json")
        let resource: (String) -> URL? = { $0 == "credentials.local" ? local : bundled }
        var reads: [URL] = []
        let values = CredentialLoader.load(resourceURL: resource, read: { url in
            reads.append(url)
            return Data(#"{"google_client_number":"fixture-number","google_client_secret":"fixture-secret"}"#.utf8)
        })
        try context.equal(values.googleClientNumber, "fixture-number", "Local credentials have precedence")
        try context.equal(values.googleClientSecret, "fixture-secret", "Secret parsed from fixture only")
        try context.equal(reads, [local], "Bundled credentials not read after local success")
        let fallback = CredentialLoader.load(resourceURL: resource, read: { url in
            if url == local { throw FixtureError.unavailable }
            return Data(#"{"google_client_number":"bundled"}"#.utf8)
        })
        try context.equal(fallback.googleClientNumber, "bundled", "Unreadable local file falls back to bundle")
        try context.equal(fallback.googleClientSecret, "YOUR_GOOGLE_CLIENT_SECRET", "Missing secret receives placeholder")
        for invalid in ["not-json", "[]"] {
            let missing = CredentialLoader.load(resourceURL: resource, read: { _ in Data(invalid.utf8) })
            try context.equal(missing.googleClientNumber, "YOUR_GOOGLE_CLIENT_NUMBER", "Malformed files fall back safely")
        }
        let absent = CredentialLoader.load(resourceURL: { _ in nil }, read: { _ in throw FixtureError.unavailable })
        try context.equal(absent.googleClientSecret, "YOUR_GOOGLE_CLIENT_SECRET", "Missing files do not load live credentials")
        let config = GoogleAuth.Configuration(clientNumber: "fixture", clientSecret: "secret")
        try context.expect(config.isConfigured, "Non-placeholder configuration accepted")
        try context.equal(config.clientID, "fixture.apps.googleusercontent.com", "OAuth client ID derived")
        try context.equal(config.redirectURI, "com.googleusercontent.apps.fixture:/oauthredirect", "OAuth redirect derived")
    }

    private static func authState(idToken: String? = nil, expiresIn: Int = 3600) -> OIDAuthState {
        let config = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://fixture.invalid/authorize")!,
            tokenEndpoint: URL(string: "https://fixture.invalid/token")!
        )
        let redirect = URL(string: "fixture:/redirect")!
        let request = OIDAuthorizationRequest(
            configuration: config, clientId: "fixture", scopes: ["email"],
            redirectURL: redirect, responseType: OIDResponseTypeCode, additionalParameters: nil
        )
        let authorization = OIDAuthorizationResponse(request: request, parameters: ["code": "fixture-code" as NSString])
        let tokenRequest = OIDTokenRequest(
            configuration: config, grantType: "authorization_code", authorizationCode: "fixture-code",
            redirectURL: redirect, clientID: "fixture", clientSecret: nil, scopes: ["email"],
            refreshToken: nil, codeVerifier: nil, additionalParameters: nil
        )
        var parameters: [String: NSCopying & NSObjectProtocol] = [
            "access_token": "fixture-access" as NSString,
            "token_type": "Bearer" as NSString,
            "expires_in": NSNumber(value: expiresIn),
            "refresh_token": "fixture-refresh" as NSString
        ]
        if let idToken { parameters["id_token"] = idToken as NSString }
        let token = OIDTokenResponse(request: tokenRequest, parameters: parameters)
        return OIDAuthState(authorizationResponse: authorization, tokenResponse: token)
    }

    private static func authentication(_ context: CoverageContext) async throws {
        var deletes = 0
        var saves: [Data] = []
        var requests: [URLRequest] = []
        var code = 200
        var restored: Data?
        var throwsSave = false
        var throwsDelete = false
        let dependencies = GoogleAuth.Dependencies(
            loadCredential: {
                guard let restored else { throw FixtureError.unavailable }
                return restored
            },
            saveCredential: {
                if throwsSave { throw FixtureError.unavailable }
                saves.append($0)
            },
            deleteCredential: {
                deletes += 1
                if throwsDelete { throw FixtureError.unavailable }
            },
            configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") },
            request: { request in
                requests.append(request)
                return (Data("fixture-body".utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            },
            openURL: { _ in false },
            oauth: .init(discover: { _, callback in callback(nil, FixtureError.unavailable) },
                         authorize: { _, _, callback in callback(nil, FixtureError.unavailable); return nil },
                         refresh: { _, callback in callback(nil, FixtureError.unavailable) })
        )
        let empty = GoogleAuth(dependencies: dependencies)
        try context.expect(!empty.isAuthenticated && empty.userEmail == nil, "Absent credential produces signed-out state")
        try await context.expectThrowsAsync("Unconfigured sign-in fails before OAuth discovery") { try await empty.signIn(forcePrompt: true) }
        try await context.expectThrowsAsync("Signed-out requests fail before transport") {
            _ = try await empty.performRequest(url: URL(string: "https://fixture.invalid/api")!)
        }
        try context.expect(requests.isEmpty, "No request issued while signed out")
        empty.resumeAuthorizationFlow(with: URL(string: "fixture:/redirect")!)
        var dismissed = false
        empty.dismiss(animated: false) { dismissed = true }
        try context.expect(dismissed, "External agent dismissal completes")
        let jwtPayload = Data(#"{"email":"fixture@example.invalid"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = authState(idToken: "header.\(jwtPayload).signature")
        try context.expect(state.isTokenFresh, "Long-lived fixture token is fresh")
        try context.equal(state.userEmail, "fixture@example.invalid", "JWT email decoded")
        try context.expect(!authState(expiresIn: 1).isTokenFresh, "Near-expiry token requires refresh")
        for token in ["bad", "a.%%.c", "a.W10.c"] {
            try context.equal(authState(idToken: token).userEmail, nil, "Invalid JWT payload has no email")
        }
        restored = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let auth = GoogleAuth(dependencies: dependencies)
        try context.expect(auth.isAuthenticated, "Archived auth state restored")
        try context.equal(auth.userEmail, "fixture@example.invalid", "Restored auth publishes email")
        let body = try await auth.performRequest(url: URL(string: "https://fixture.invalid/api")!)
        try context.equal(body, Data("fixture-body".utf8), "Authenticated GET returns transport data")
        try context.equal(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access", "Bearer token attached")
        let jsonBody = try await auth.performJSONRequest(url: URL(string: "https://fixture.invalid/api")!, method: "PATCH", body: Data("{\"rsvp\":true}".utf8))
        try context.equal(jsonBody, Data("fixture-body".utf8), "Authenticated PATCH returns transport data")
        try context.equal(requests.last?.httpMethod, "PATCH", "JSON request keeps the method")
        try context.equal(requests.last?.value(forHTTPHeaderField: "Content-Type"), "application/json", "JSON request declares its content type")
        try context.equal(requests.last?.httpBody, Data("{\"rsvp\":true}".utf8), "JSON request carries the body")
        auth.didChange(state)
        try context.equal(saves.count, 1, "State delegate persists archive")
        throwsSave = true
        auth.didChange(state)
        code = 500
        try await context.expectThrowsAsync("Server errors propagate") { _ = try await auth.performRequest(url: URL(string: "https://fixture.invalid/api")!) }
        try context.expect(auth.isAuthenticated, "Server error does not clear authentication")
        for status in [401, 403] {
            let rejected = GoogleAuth(dependencies: dependencies)
            code = status
            try await context.expectThrowsAsync("Authorization rejection clears state") {
                _ = try await rejected.performRequest(url: URL(string: "https://fixture.invalid/api")!)
            }
            try context.expect(!rejected.isAuthenticated && rejected.userEmail == nil, "Rejected state cleared")
        }
        let ignoredError = GoogleAuth(dependencies: dependencies)
        ignoredError.authState(state, didEncounterAuthorizationError: NSError(domain: "fixture", code: 1))
        try context.expect(ignoredError.isAuthenticated, "Non-OAuth error preserves credentials")
        throwsDelete = true
        ignoredError.authState(state, didEncounterAuthorizationError: NSError(domain: OIDOAuthTokenErrorDomain, code: 1))
        try context.expect(!ignoredError.isAuthenticated, "OAuth token error clears state even if deletion fails")
        throwsDelete = false
        auth.signOut()
        try context.expect(!auth.isAuthenticated, "Sign-out resets published authentication")
        for _ in 0..<100 {
            if requests.contains(where: { $0.httpBody == Data("token=fixture-refresh".utf8) }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.expect(requests.contains { $0.httpMethod == "POST" && $0.httpBody == Data("token=fixture-refresh".utf8) }, "Sign-out revokes fixture refresh token through injected transport")
        try context.expect(deletes > 0, "Credential deletion routed through injected store")
        restored = Data("not-a-keyed-archive".utf8)
        let deletesBeforeCorruption = deletes
        let corrupted = GoogleAuth(dependencies: dependencies)
        try context.expect(!corrupted.isAuthenticated, "Corrupted credential does not restore authentication")
        try context.equal(deletes, deletesBeforeCorruption + 1, "Corrupted credential deleted through injected store")
        for error in [GoogleAuthError.notConfigured, .discoveryFailed, .authorizationFailed, .notAuthenticated, .refreshFailed, .apiError("fixture")] {
            try context.expect(!(error.errorDescription ?? "").isEmpty, "Auth errors provide user-facing descriptions")
        }
    }

    private static func oauth(_ context: CoverageContext) async throws {
        let service = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://fixture.invalid/authorize")!,
            tokenEndpoint: URL(string: "https://fixture.invalid/token")!
        )
        var discoveryFails = false
        var authorizationFails = false
        var refreshError: Error?
        var refreshToken: String? = "refreshed-fixture"
        var refreshes = 0
        var authorizations: [OIDAuthorizationRequest] = []
        var stored: Data?
        var headers: [String?] = []
        let session = AuthorizationSession()
        var opened: [URL] = []
        let dependencies = GoogleAuth.Dependencies(
            loadCredential: { guard let stored else { throw FixtureError.unavailable }; return stored },
            saveCredential: { stored = $0 }, deleteCredential: { stored = nil },
            configuration: { .init(clientNumber: "fixture", clientSecret: "fixture-secret") },
            request: { request in
                headers.append(request.value(forHTTPHeaderField: "Authorization"))
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            openURL: { opened.append($0); return true },
            oauth: .init(
                discover: { _, callback in callback(discoveryFails ? nil : service, nil) },
                authorize: { request, _, callback in
                    authorizations.append(request)
                    callback(authorizationFails ? nil : authState(expiresIn: 1), nil)
                    return session
                },
                refresh: { _, callback in
                    refreshes += 1
                    callback(refreshToken, refreshError)
                }
            )
        )
        let auth = GoogleAuth(dependencies: dependencies)
        var invalidRedirectDependencies = dependencies
        invalidRedirectDependencies.configuration = { .init(clientNumber: "://[", clientSecret: "fixture-secret") }
        let invalidRedirect = GoogleAuth(dependencies: invalidRedirectDependencies)
        try await context.expectThrowsAsync("Invalid OAuth redirect rejected before discovery") { try await invalidRedirect.signIn() }
        try context.expect(authorizations.isEmpty, "Invalid redirect never presents authorization")
        discoveryFails = true
        try await context.expectThrowsAsync("Missing discovery response fails") { try await auth.signIn() }
        discoveryFails = false
        authorizationFails = true
        try await context.expectThrowsAsync("Missing authorization response fails") { try await auth.signIn() }
        authorizationFails = false
        try await auth.signIn(forcePrompt: true)
        try context.expect(auth.isAuthenticated, "Injected OAuth response authenticates")
        try context.equal(authorizations.last?.additionalParameters?["prompt"], "consent", "Forced consent passed to OAuth")
        try context.expect(authorizations.last?.scope?.contains(GoogleAuthConfig.scopes.last!) == true, "Authorization requests the calendar write scope")
        try context.expect(auth.present(authorizations.last!, session: session), "External agent forwards browser open result")
        try context.equal(opened.first?.host, "fixture.invalid", "Only fixture authorization URL opened through callback")
        let redirect = URL(string: "fixture:/redirect?code=fixture")!
        auth.resumeAuthorizationFlow(with: redirect)
        try context.equal(session.resumed, [redirect], "OAuth redirect forwarded to active session")
        let authorizationCount = authorizations.count
        try await auth.signIn()
        try context.equal(authorizations.count, authorizationCount, "Authenticated sign-in skips presentation")
        _ = try await auth.performRequest(url: URL(string: "https://fixture.invalid/api")!)
        try context.equal(headers.last!, "Bearer refreshed-fixture", "Expired token uses injected refresh")
        try context.equal(refreshes, 1, "One refresh performed")
        refreshToken = nil
        refreshError = FixtureError.unavailable
        try await context.expectThrowsAsync("Refresh transport error propagates") {
            _ = try await auth.performRequest(url: URL(string: "https://fixture.invalid/api")!)
        }
        try context.expect(auth.isAuthenticated, "Non-OAuth refresh failure preserves state")
        refreshError = NSError(domain: OIDOAuthTokenErrorDomain, code: 1)
        try await context.expectThrowsAsync("OAuth refresh failure clears credentials") {
            _ = try await auth.performRequest(url: URL(string: "https://fixture.invalid/api")!)
        }
        try context.expect(!auth.isAuthenticated, "OAuth refresh failure signed out")
        refreshError = nil
        let missingToken = GoogleAuth(dependencies: dependencies)
        try await missingToken.signIn()
        try await context.expectThrowsAsync("Absent refresh token and error produce refreshFailed") {
            _ = try await missingToken.performRequest(url: URL(string: "https://fixture.invalid/api")!)
        }

        // JSON transport: 200 carries the payload through, 401 clears the
        // signed-in state, and the GC adapter's auth-based convenience init
        // routes its PATCH through performJSONRequest.
        var jsonStatus = 200
        var jsonBodies: [Data?] = []
        var jsonMethods: [String?] = []
        let jsonDependencies = GoogleAuth.Dependencies(
            loadCredential: { throw FixtureError.unavailable },
            saveCredential: { _ in }, deleteCredential: {},
            configuration: { .init(clientNumber: "fixture-client", clientSecret: "fixture-secret") },
            request: { request in
                jsonMethods.append(request.httpMethod)
                jsonBodies.append(request.httpBody)
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: jsonStatus, httpVersion: nil, headerFields: nil)!)
            },
            openURL: { _ in false },
            oauth: .init(
                discover: { _, callback in callback(service, nil) },
                authorize: { _, _, callback in callback(authState(expiresIn: 600), nil); return session },
                refresh: { _, callback in callback("refreshed-fixture", nil) }
            )
        )
        let jsonAuth = GoogleAuth(dependencies: jsonDependencies)
        try await jsonAuth.signIn()
        try context.expect(jsonAuth.isAuthenticated, "JSON transport fixture signs in")
        let patchData = try JSONSerialization.data(withJSONObject: ["attendees": [["self": true, "responseStatus": "accepted"]]])
        _ = try await jsonAuth.performJSONRequest(url: URL(string: "https://fixture.invalid/calendar/evt")!, method: "PATCH", body: patchData)
        try context.equal(jsonMethods, ["PATCH"], "JSON request carries the method")
        try context.equal(jsonBodies, [patchData], "JSON request carries the body")
        let adapter = GCEventStoreAdapter(auth: jsonAuth)
        var answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .accepted)
        try context.expect(answered && jsonMethods == ["PATCH", "PATCH"], "Auth-based adapter PATCHes the reply")
        try context.expect(jsonMethods.last == "PATCH" && jsonBodies.last != nil, "Adapter PATCH carries a body")
        jsonStatus = 401
        answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .declined)
        try context.expect(!answered, "401 reply surfaces as failure")
        try context.expect(!jsonAuth.isAuthenticated, "401 clears the signed-in state")
    }

    private static func updaterAndLifecycle(_ context: CoverageContext) throws {
        let backend = Updater()
        let updater = UpdaterViewModel(backend: backend)
        try context.expect(!updater.canCheckForUpdates, "Updater is lazy")
        try context.equal(backend.starts, 0, "Construction does not start updater")
        updater.automaticallyChecksForUpdates = true
        try context.expect(backend.automaticallyChecksForUpdates, "Automatic check setting forwarded")
        try context.expect(updater.canCheckForUpdates, "Started updater reports backend readiness")
        updater.checkForUpdates()
        updater.checkForUpdates()
        try context.equal(backend.starts, 1, "Updater starts only once")
        try context.equal(backend.checks, 2, "Manual checks forwarded")
        updater.automaticallyChecksForUpdates = false
        backend.canCheckForUpdates = false
        try context.expect(!updater.canCheckForUpdates, "Backend readiness observed")
        let failing = Updater()
        failing.failsStart = true
        let failedUpdater = UpdaterViewModel(backend: failing)
        failedUpdater.checkForUpdates()
        try context.equal(failing.checks, 1, "Manual check retains existing start-error semantics")
        let auth = GoogleAuth(dependencies: .init(
            loadCredential: { throw FixtureError.unavailable }, saveCredential: { _ in }, deleteCredential: {},
            configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") },
            request: { _ in throw FixtureError.unavailable }, openURL: { _ in false }
        ))
        var terminations = 0
        let delegate = AppDelegate(googleAuth: auth, updaterViewModel: updater, terminateServices: { terminations += 1 })
        try context.expect(delegate.googleAuth === auth && delegate.updaterViewModel === updater, "Lifecycle uses injected services")
        try context.expect(delegate.getMeetingManager() == nil && delegate.getNoSleepManager() == nil, "No managers eagerly started")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try context.equal(terminations, 1, "Termination delegates synchronously without killing real services")
    }

    private static func calendars(_ context: CoverageContext) async throws {
        var authenticated = false
        var signIns = 0
        var urls: [URL] = []
        var calendarJSON = ##"{"items":[{"id":"team@example.invalid","summary":"Team","backgroundColor":"#112233"},{"id":"fallback","summary":"Fallback"},{"id":"invalid"}]}"##
        var eventJSON = #"{"items":[{"id":"timed","summary":"Planning","start":{"dateTime":"2026-10-30T10:00:00Z"},"end":{"dateTime":"2026-10-30T11:00:00Z"},"location":"https://meet.google.com/abc-defg-hij","description":"Agenda","organizer":{"email":"owner@example.invalid"},"attendees":[{"displayName":"Guest"},{"email":"other@example.invalid"},{}],"status":"cancelled"},{"id":"all-day","summary":"Holiday","start":{"date":"2026-10-30"},"end":{"date":"2026-10-31"}},{"id":"missing"},{"id":"bad-date","summary":"Bad","start":{"date":"no"},"end":{"date":"no"}}]}"#
        let adapter = GCEventStoreAdapter(dependencies: .init(
            isAuthenticated: { authenticated },
            signIn: { signIns += 1; authenticated = true },
            request: { url in
                urls.append(url)
                return Data((url.path.hasSuffix("calendarList") ? calendarJSON : eventJSON).utf8)
            },
            requestJSON: { url, _, _ in
                urls.append(url)
                return Data(eventJSON.utf8)
            }
        ))
        let signedOutCalendars = try await adapter.fetchCalendars()
        let signedOutEvents = try await adapter.fetchEvents(from: .distantPast, to: .distantFuture, calendars: ["fixture"])
        try context.expect(signedOutCalendars.isEmpty && signedOutEvents.isEmpty && urls.isEmpty, "Signed-out calendar reads avoid transport")
        let granted = try await adapter.requestAccess()
        let alreadyGranted = try await adapter.requestAccess()
        try context.expect(granted && alreadyGranted, "Access reflects authentication")
        try context.equal(signIns, 1, "Already authorized access avoids duplicate sign-in")
        let calendars = try await adapter.fetchCalendars()
        try context.equal(calendars.count, 2, "Incomplete calendars skipped")
        try context.equal(calendars.first?.title, "Team", "Calendar summary parsed")
        let events = try await adapter.fetchEvents(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600), calendars: ["team@example.invalid", "unknown"])
        try context.equal(events.count, 4, "Timed and all-day events collected across calendars")
        try context.equal(events.first?.organizer, "owner@example.invalid", "Organizer email fallback")
        try context.equal(events.first?.attendees, ["Guest", "other@example.invalid"], "Attendees parsed with fallback")
        try context.equal(events.first?.status, .canceled, "Cancelled Google event mapped")
        try context.expect(events[1].isAllDay, "Date-only events are all day")
        try context.equal(events[2].calendar.id, "unknown", "Unknown calendar gets fallback metadata")
        try context.expect(events.first?.meetingLink != nil, "Conference link detected")
        let query = URLComponents(url: urls.first { $0.path.hasSuffix("events") }!, resolvingAgainstBaseURL: false)!.queryItems!
        try context.equal(query.first { $0.name == "maxResults" }?.value, "50", "Google event query limit preserved")
        try context.equal(query.first { $0.name == "singleEvents" }?.value, "true", "Recurring events expanded")
        calendarJSON = "{}"
        try await context.expectThrowsAsync("Malformed calendar list rejected") { _ = try await adapter.fetchCalendars() }
        calendarJSON = #"{"items":[]}"#
        eventJSON = "{}"
        try await context.expectThrowsAsync("Malformed event list rejected") {
            _ = try await adapter.fetchEvents(from: .distantPast, to: .distantFuture, calendars: ["fixture"])
        }
    }

    /// RSVP replies against Google Calendar: guard paths and the PATCH body.
    private static func gcRespond(_ context: CoverageContext) async throws {
        var authenticated = true
        var patchCalls: [(URL, String, Data)] = []
        var transportFails = false
        let adapter = GCEventStoreAdapter(dependencies: .init(
            isAuthenticated: { authenticated },
            signIn: { authenticated = true },
            request: { url in Data("[]".utf8) },
            requestJSON: { url, method, body in
                patchCalls.append((url, method, body))
                if transportFails { throw FixtureError.unavailable }
                return Data("{}".utf8)
            }
        ))
        authenticated = false
        var answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .accepted)
        try context.expect(!answered, "Signed-out RSVP is rejected")
        authenticated = true
        answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .pending)
        try context.expect(!answered && patchCalls.isEmpty, "Non-answerable status never reaches transport")
        answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .unknown)
        try context.expect(!answered && patchCalls.isEmpty, "Unknown status never reaches transport")
        answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .declined)
        try context.expect(answered && patchCalls.count == 1, "Declined answer PATCHes Google")
        try context.expect(patchCalls[0].0.absoluteString.contains("/calendars/cal/events/evt?"), "PATCH URL targets the event resource")
        try context.expect(patchCalls[0].0.absoluteString.contains("sendUpdates=none"), "PATCH avoids emailing attendees")
        try context.equal(patchCalls[0].1, "PATCH", "RSVP uses PATCH method")
        let body = try JSONSerialization.jsonObject(with: patchCalls[0].2) as? [String: Any]
        try context.expect((body?["attendeesOmitted"] as? Bool) == true, "PATCH omits other attendees")
        let attendees = body?["attendees"] as? [[String: Any]]
        try context.expect(attendees?.first?["self"] as? Bool == true, "PATCH marks the self attendee")
        try context.expect(attendees?.first?["responseStatus"] as? String == "declined", "PATCH carries the declined status")
        answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .tentative)
        try context.expect(answered && patchCalls.count == 2, "Tentative answer PATCHes Google")
        let tentativeBody = try JSONSerialization.jsonObject(with: patchCalls[1].2) as? [String: Any]
        let tentativeAttendees = tentativeBody?["attendees"] as? [[String: Any]]
        try context.expect(tentativeAttendees?.first?["responseStatus"] as? String == "tentative", "PATCH carries the tentative status")
        transportFails = true
        answered = await adapter.respond(toEventID: "evt", calendarID: "cal", status: .accepted)
        try context.expect(!answered, "Transport failure returns false")
    }

    private static func notifications(_ context: CoverageContext) async throws {
        var enabled = true
        var available = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var categories = Set<UNNotificationCategory>()
        var authorizations = 0
        var requests: [UNNotificationRequest] = []
        var removals: [[String]] = []
        var clears = 0
        var opened: [URL] = []
        let dependencies = NotificationManager.Dependencies(
            isAvailable: { available }, isEnabled: { enabled }, now: { now },
            configure: { _, value in categories = value }, authorize: { authorizations += 1 },
            add: { requests.append($0) }, remove: { removals.append($0) },
            removeAll: { clears += 1 }, openURL: { opened.append($0) },
            isNewEventsEnabled: { false }, isPendingInvitesEnabled: { false }
        )
        let manager = NotificationManager(dependencies: dependencies)
        // The configure boundary receives a Set: iteration order is not
        // guaranteed, so assert membership per identifier instead of first.
        try context.expect(categories.contains { $0.identifier == "EVENT_NOTIFICATION" }, "Meeting category configured")
        try context.expect(categories.contains { $0.identifier == "EVENT_INVITE" }, "Invite category configured")
        try context.expect(categories.contains { $0.identifier == "NEW_EVENT" }, "New-event category configured")
        let meetingCategory = categories.first { $0.identifier == "EVENT_NOTIFICATION" }
        try context.equal(meetingCategory?.actions.map(\.identifier), ["JOIN_ACTION", "SNOOZE_5", "SNOOZE_10", "DISMISS_ACTION"], "Category actions configured")
        manager.requestAuthorization()
        try context.equal(authorizations, 1, "Authorization uses injected boundary")
        let calendar = MBCalendar(id: "fixture", title: "Fixture", color: "#112233", source: "Fixture")
        let event = CalendarEvent(id: "meeting", title: "Planning", startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(7200), location: nil, notes: nil, url: URL(string: "https://meet.google.com/abc-defg-hij"), calendar: calendar, organizer: nil, attendees: [])
        manager.scheduleNotification(for: event, minutesBefore: 5)
        try context.equal(requests.last?.identifier, "meeting_5", "Reminder identifier contains lead time")
        try context.equal(requests.last?.content.body, "Planning", "Reminder body uses title")
        try context.equal(requests.last?.content.userInfo["eventID"] as? String, "meeting", "Reminder stores event identifier")
        try context.expect(requests.last?.trigger is UNCalendarNotificationTrigger, "Calendar trigger used for scheduled reminder")
        manager.scheduleNotification(for: event, minutesBefore: 61)
        try context.equal(requests.count, 1, "Past reminders not scheduled")
        manager.handleAction("JOIN_ACTION", meetingLink: "https://fixture.invalid/meeting", eventID: "meeting")
        try context.equal(opened.map(\.absoluteString), ["https://fixture.invalid/meeting"], "Join opens injected URL")
        manager.handleAction("JOIN_ACTION", meetingLink: nil, eventID: nil)
        manager.handleAction("SNOOZE_5", meetingLink: nil, eventID: "meeting")
        try context.equal((requests.last?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 300, "Five-minute snooze interval")
        manager.handleAction("SNOOZE_10", meetingLink: nil, eventID: "meeting")
        try context.equal((requests.last?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 600, "Ten-minute snooze interval")
        try context.equal(requests.last?.identifier, "meeting_snoozed", "Snooze replaces previous snoozed request")
        manager.handleAction("SNOOZE_5", meetingLink: nil, eventID: nil)
        manager.handleAction("SNOOZE_10", meetingLink: nil, eventID: nil)
        manager.handleAction("DISMISS_ACTION", meetingLink: nil, eventID: nil)
        manager.handleAction("unknown", meetingLink: nil, eventID: nil)
        manager.cancelNotifications(for: "meeting")
        try context.equal(removals, [["meeting"]], "Cancellation forwards existing identifier semantics")
        manager.cancelAllNotifications()
        try context.equal(clears, 1, "Cancel all clears pending and delivered through boundary")
        enabled = false
        manager.requestAuthorization()
        manager.scheduleNotification(for: event, minutesBefore: 5)
        manager.handleAction("JOIN_ACTION", meetingLink: "https://fixture.invalid/disabled", eventID: nil)
        manager.cancelNotifications(for: "disabled")
        try context.equal(authorizations, 1, "Disabled feature avoids authorization")
        try context.equal(requests.count, 3, "Disabled feature avoids delivery")
        try context.equal(opened.count, 1, "Disabled feature avoids opening links")
        NotificationCenter.default.post(name: .businessBarPreferencesDidChange, object: nil)
        for _ in 0..<100 {
            if clears >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.expect(clears >= 2, "Disabling preferences clears existing notifications")
        available = false
        let unavailable = NotificationManager(dependencies: dependencies)
        unavailable.requestAuthorization()
        unavailable.scheduleNotification(for: event, minutesBefore: 5)
        unavailable.cancelNotifications(for: "meeting")
        unavailable.cancelAllNotifications()
        try context.equal(authorizations, 1, "Unavailable notification service avoids authorization")
    }
}

@MainActor
private extension AppServiceScenarios {
    @MainActor
    final class LifecycleMonitor: BadgeMonitoring {
        var onBadgeUpdate: ((String, Int) -> Void)?
        func startMonitoring(apps: [MonitoredApp]) {}
        func stopMonitoring() {}
        func updateAppElements(for apps: [MonitoredApp]) {}
        func restartPollTimer() {}
    }

    @MainActor
    final class LifecycleStore: EventStoreProtocol {
        var events: [CalendarEvent] = []
        let calendar = MBCalendar(id: "lifecycle", title: "Lifecycle", color: "#123456", source: "Fixture")
        var receivedRSVPs: [(String, String, CalendarEvent.RSVPStatus)] = []
        var respondResult = true
        func requestAccess() async throws -> Bool { true }
        func fetchCalendars() async throws -> [MBCalendar] { [calendar] }
        func fetchEvents(from: Date, to: Date, calendars: [String]) async throws -> [CalendarEvent] { events }
        func respond(toEventID eventID: String, calendarID: String, status: CalendarEvent.RSVPStatus) async -> Bool {
            receivedRSVPs.append((eventID, calendarID, status))
            return respondResult
        }
    }

    @MainActor
    final class LifecycleEffects {
        var order: [String] = []
        var newEventsEnabled = false
        var pendingInvitesEnabled = false
        var templates: [PromptTemplate] = []
        var templateLoads = 0
        var templateSaves = 0
        var shortcuts: [KeyboardShortcuts.Shortcut] = []
        var providers: [CalendarProvider] = []
        var configured = false
        var trusted = false
        var permissionDecision = true
        var permissionAlerts = 0
        var openedSettings = 0
        var preferencesFail = false
        var preferencesCreations = 0
        var preferenceTabs: [PreferencesView.PreferenceTab?] = []
        var preferencesShows = 0
        var preferencesErrors = 0
        var onboardingCreations = 0
        var onboardingShows = 0
        var authorizations = 0
        var requests: [UNNotificationRequest] = []
        var removals: [[String]] = []
        var clears = 0
        var powerActivations = 0
        var powerDeactivations = 0
        var terminations = 0
        var statusAction: (@MainActor () -> Void)?
        var queued: [@MainActor () -> Void] = []
        var delayed: [(TimeInterval, @MainActor () -> Void)] = []
        weak var statusBacking: NSObject?

        func drain() {
            while !queued.isEmpty { queued.removeFirst()() }
        }
    }

    /// Live Dependency closures the injected lifecycle scenarios leave
    /// cold: the convenience inits (GoogleAuth/UpdaterViewModel defaults plus
    /// .live), the safe live factories, and the stored terminate closure.
    /// Deliberately NOT invoked: the status factory (real menu bar item,
    /// global hotkey registration, minute timer), the activation policy
    /// write (visible Dock state), the crash handlers, both modal alerts,
    /// and the global shortcut write. The preferences and onboarding
    /// factories are constructed but never shown: building an NSWindow
    /// without orderFront commits nothing to the window server.
    private static func appDelegateLiveClosures(_ context: CoverageContext) async throws {
        let defaults = try context.defaults("appdelegate-live")
        defaults.registerDefaults()

        // Convenience init chain: GoogleAuth() live ctor loads through the
        // isolated-home keychain (absent entry throws, ctor catches),
        // UpdaterViewModel() builds the Sparkle controller without starting
        // it, and the terminating closure stays stored, not executed.
        let plainInit = AppDelegate()
        try context.expect(plainInit.getMeetingManager() == nil, "Convenience init stays lazy: no managers before launch")

        // Safe live factories, invoked one at a time against fixture state.
        let live = AppDelegate.Dependencies.live
        try context.expect(live.googleConfigured() == false, "Live Google configuration reads the absent bundle credentials")
        _ = live.axTrusted() // reads TCC state; answer not asserted (host-dependent)
        let templates = live.loadTemplates()
        try context.expect(templates == PromptTemplate.defaults, "Live template store loads the shipped defaults")
        live.saveTemplates(templates)
        try context.expect(live.loadTemplates() == templates, "Live template store round-trips through the fixture home")

        let auth = GoogleAuth(dependencies: .init(
            loadCredential: { throw FixtureError.unavailable }, saveCredential: { _ in }, deleteCredential: {},
            configuration: { .init(clientNumber: "fixture", clientSecret: "fixture-secret") },
            request: { _ in throw FixtureError.unavailable }, openURL: { _ in false }
        ))
        let eventKitStore = live.eventStore(.eventKit, auth)
        try context.expect(eventKitStore is EKEventStoreAdapter, "Live eventStore factory builds the EventKit adapter")
        let googleStore = live.eventStore(.google, auth)
        try context.expect(googleStore is GCEventStoreAdapter, "Live eventStore factory builds the Google adapter")

        let meeting = live.meeting(eventKitStore)
        try context.expect(meeting.nextEvent == nil, "Live meeting factory loads without events")
        let badge = live.badge()
        try context.expect(badge.monitoredApps.isEmpty, "Live badge factory starts with no monitored apps")
        let noSleep = live.noSleep()
        try context.expect(noSleep.isActive == false, "Live no-sleep factory starts inactive")
        let notification = live.notification()
        _ = notification // bundle-absent guard skips UNUserNotificationCenter setup

        // Preferences and onboarding factories construct their windows but
        // the returned presentations are never shown.
        let updater = UpdaterViewModel(backend: Updater())
        let preferences = live.preferences(updater, badge, meeting, auth, .general)
        try context.expect(preferences != nil, "Live preferences factory builds the window controller")
        let onboarding = live.onboarding()
        try context.expect(onboarding != nil, "Live onboarding factory builds the window controller")

        // registerURL installs the handler on this process only; no event
        // is ever delivered to the coverage binary.
        live.registerURL(plainInit)

        // enqueue/after dispatch on the main queue; drain both.
        var enqueued = false
        live.enqueue { enqueued = true }
        var delayedRan = false
        live.after(0.01) { delayedRan = true }
        for _ in 0..<100 where !(enqueued && delayedRan) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        try context.expect(enqueued, "Live enqueue dispatches the action")
        try context.expect(delayedRan, "Live after fires the delayed action")
    }

    @MainActor
    final class LifecycleFixture {
        let defaults: UserDefaults
        let center: NotificationCenter
        let workspace: NotificationCenter
        let effects: LifecycleEffects
        let store: LifecycleStore
        let now: Date
        let auth: GoogleAuth
        let updater: UpdaterViewModel
        let meeting: MeetingManager
        let badge: BadgeManager
        let noSleep: NoSleepManager
        let notification: NotificationManager

        init(_ context: CoverageContext, label: String, trusted: Bool = false) throws {
            let defaults = try context.defaults(label)
            self.defaults = defaults
            let effects = LifecycleEffects()
            let center = NotificationCenter()
            let workspace = NotificationCenter()
            let store = LifecycleStore()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            self.effects = effects
            self.center = center
            self.workspace = workspace
            self.store = store
            self.now = now
            effects.trusted = trusted
            defaults.set([store.calendar.id], forKey: Constants.Defaults.selectedCalendars)
            defaults.set(0, forKey: Constants.Defaults.noSleepDefaultDuration)
            auth = GoogleAuth(dependencies: .init(
                loadCredential: { throw FixtureError.unavailable }, saveCredential: { _ in }, deleteCredential: {},
                configuration: { .init(clientNumber: "YOUR_FIXTURE", clientSecret: "YOUR_FIXTURE") },
                request: { _ in throw FixtureError.unavailable }, openURL: { _ in false },
                oauth: .init(discover: { _, callback in callback(nil, FixtureError.unavailable) },
                             authorize: { _, _, callback in callback(nil, FixtureError.unavailable); return nil },
                             refresh: { _, callback in callback(nil, FixtureError.unavailable) })
            ))
            updater = UpdaterViewModel(backend: Updater())
            meeting = MeetingManager(eventStore: store, nowProvider: { now }, defaults: defaults, notificationCenter: center)
            badge = BadgeManager(
                defaults: defaults, notifications: center, trust: { effects.trusted }, monitor: LifecycleMonitor(),
                schedule: { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } },
                requestPermission: {}, openSettings: { _ in effects.openedSettings += 1 }
            )
            noSleep = NoSleepManager(
                defaults: defaults, notifications: center, workspace: workspace, trust: { false }, now: { now },
                schedule: { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } },
                activateSleep: { _ in effects.powerActivations += 1 }, deactivateSleep: { effects.powerDeactivations += 1 },
                startActivity: {}, stopActivity: {}
            )
            notification = NotificationManager(dependencies: .init(
                isAvailable: { true },
                isEnabled: { defaults.object(forKey: Constants.Defaults.featureNotifications) as? Bool ?? true },
                now: { now }, configure: { _, _ in }, authorize: { effects.authorizations += 1 },
                add: { effects.requests.append($0) }, remove: { effects.removals.append($0) },
                removeAll: { effects.clears += 1 }, openURL: { _ in }, notificationCenter: center,
                isNewEventsEnabled: { effects.newEventsEnabled }, isPendingInvitesEnabled: { effects.pendingInvitesEnabled }
            ))
        }

        func event(_ id: String, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, title: id, startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(7200), location: nil, notes: nil, url: nil, calendar: store.calendar, organizer: nil, attendees: [], isAllDay: allDay)
        }

        func delegate() -> AppDelegate {
            let effects = effects
            let defaults = defaults
            let store = store
            let meeting = meeting
            let badge = badge
            let noSleep = noSleep
            let notification = notification
            return AppDelegate(googleAuth: auth, updaterViewModel: updater, terminateServices: { effects.terminations += 1 }, dependencies: .init(
                defaults: defaults, notifications: center,
                loadTemplates: { effects.order.append("templates.load"); effects.templateLoads += 1; return effects.templates },
                saveTemplates: { effects.order.append("templates.save"); effects.templateSaves += 1; effects.templates = $0 },
                eventStore: { provider, _ in effects.order.append("eventStore"); effects.providers.append(provider); return store },
                meeting: { _ in effects.order.append("meeting"); return meeting },
                badge: { effects.order.append("badge"); return badge },
                noSleep: { effects.order.append("noSleep"); return noSleep },
                notification: { effects.order.append("notification"); return notification },
                status: { _, _, _, action in
                    effects.order.append("status")
                    effects.statusAction = action
                    let backing = NSObject()
                    effects.statusBacking = backing
                    return backing
                },
                preferences: { _, _, _, _, tab in
                    effects.preferencesCreations += 1
                    effects.preferenceTabs.append(tab)
                    if effects.preferencesFail { return nil }
                    return .init(show: { effects.preferencesShows += 1 })
                },
                onboarding: {
                    effects.order.append("onboarding")
                    effects.onboardingCreations += 1
                    return .init(show: { effects.onboardingShows += 1 })
                },
                activationPolicy: { policy in effects.order.append("activation:\(policy.rawValue)") },
                installCrash: { effects.order.append("crash.install") },
                crashAlert: { effects.order.append("crash.alert") },
                registerURL: { _ in effects.order.append("url.register") },
                shortcut: { effects.order.append("shortcut"); effects.shortcuts.append($0) },
                googleConfigured: { effects.configured }, axTrusted: { effects.trusted },
                permissionAlert: { effects.permissionAlerts += 1; return effects.permissionDecision },
                preferencesError: { effects.preferencesErrors += 1 },
                enqueue: { effects.queued.append($0) }, after: { effects.delayed.append(($0, $1)) }
            ))
        }
    }

    /// RSVP confirmation notifications: new-event and invite banners,
    /// answer actions, dedup bookkeeping, and the failure surface.
    private static func rsvpNotifications(_ context: CoverageContext) async throws {
        var enabled = true
        var available = true
        var newEventsEnabled = false
        var pendingInvitesEnabled = false
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var requests: [UNNotificationRequest] = []
        var removals: [[String]] = []
        var opened: [URL] = []
        var deliveredIDs = Set<String>()
        var rsvpReplies: [(String, String, CalendarEvent.RSVPStatus)] = []
        let center = NotificationCenter()
        let dependencies = NotificationManager.Dependencies(
            isAvailable: { available }, isEnabled: { enabled }, now: { now },
            configure: { _, _ in }, authorize: {},
            add: { requests.append($0) }, remove: { removals.append($0) },
            removeAll: {}, openURL: { opened.append($0) }, notificationCenter: center,
            isNewEventsEnabled: { newEventsEnabled },
            isPendingInvitesEnabled: { pendingInvitesEnabled }
        )
        let manager = NotificationManager(dependencies: dependencies)
        manager.setDeliveredInviteBookkeeping(
            delivered: { deliveredIDs },
            mark: { deliveredIDs.insert($0) }
        )
        manager.setRSVPHandler { eventID, calendarID, status in
            rsvpReplies.append((eventID, calendarID, status))
        }

        let calendar = MBCalendar(id: "rsvp-cal", title: "Fixture", color: "#112233", source: "Fixture")
        let invite = CalendarEvent(
            id: "invite-1", title: "Design review",
            startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(7200),
            location: nil, notes: nil, url: nil, calendar: calendar,
            organizer: "Owner", attendees: ["Owner"], myRSVPStatus: .pending
        )
        let fresh = CalendarEvent(
            id: "fresh-1", title: "Synced event",
            startDate: now.addingTimeInterval(5400), endDate: now.addingTimeInterval(9000),
            location: nil, notes: nil, url: nil, calendar: calendar,
            organizer: nil, attendees: [], myRSVPStatus: .accepted
        )

        // Feature off: nothing is presented even with events flowing.
        center.post(name: .businessBarNewEventsAppeared, object: nil, userInfo: ["events": [fresh]])
        center.post(name: .businessBarPendingRSVPsAppeared, object: nil, userInfo: ["events": [invite]])
        try await settleRSVP()
        try context.equal(requests.count, 0, "Disabled confirmations present nothing")

        // New events on, invite off.
        newEventsEnabled = true
        center.post(name: .businessBarNewEventsAppeared, object: nil, userInfo: ["events": [fresh]])
        try await settleRSVP()
        try context.equal(requests.count, 1, "New event posts one banner")
        try context.equal(requests.last?.identifier, "new-event-fresh-1", "New-event identifier embeds event id")
        try context.equal(requests.last?.content.categoryIdentifier, "NEW_EVENT", "New-event banner uses its category")
        center.post(name: .businessBarNewEventsAppeared, object: nil, userInfo: ["events": [invite]])
        try await settleRSVP()
        try context.equal(requests.count, 2, "Second new event posts its own banner")

        // Invites on: delivered bookkeeping suppresses duplicates while up.
        pendingInvitesEnabled = true
        center.post(name: .businessBarPendingRSVPsAppeared, object: nil, userInfo: ["events": [invite]])
        try await settleRSVP()
        try context.equal(requests.count, 3, "Pending invite posts a banner")
        try context.equal(requests.last?.identifier, "invite-invite-1", "Invite identifier embeds event id")
        try context.equal(requests.last?.content.categoryIdentifier, "EVENT_INVITE", "Invite banner uses its category")
        try context.equal(requests.last?.content.userInfo["calendarID"] as? String, "rsvp-cal", "Invite banner carries calendar id")
        try context.expect(deliveredIDs.contains("invite-1"), "Delivered invite marked in bookkeeping")
        center.post(name: .businessBarPendingRSVPsAppeared, object: nil, userInfo: ["events": [invite]])
        try await settleRSVP()
        try context.equal(requests.count, 3, "Delivered-but-unanswered invite is not duplicated")

        // Answer actions route through the injected handler.
        manager.handleAction("RSVP_ACCEPT", meetingLink: nil, eventID: "invite-1", calendarID: "rsvp-cal")
        manager.handleAction("RSVP_DECLINE", meetingLink: nil, eventID: "invite-2", calendarID: "rsvp-cal")
        manager.handleAction("RSVP_TENTATIVE", meetingLink: nil, eventID: "invite-3", calendarID: "rsvp-cal")
        try context.equal(rsvpReplies.map(\.2), [.accepted, .declined, .tentative], "RSVP actions map to statuses")
        manager.handleAction("RSVP_ACCEPT", meetingLink: nil, eventID: nil, calendarID: "rsvp-cal")
        manager.handleAction("NEW_EVENT_KEEP", meetingLink: nil, eventID: nil, calendarID: nil)
        try context.equal(rsvpReplies.count, 3, "Missing identifiers do not reach the handler")

        manager.cancelInviteNotification(for: "invite-1")
        try context.equal(removals, [["invite-invite-1"]], "Answered invite notification removed")

        manager.notifyRSVPFailure(for: "invite-1")
        try context.equal(requests.last?.identifier, "rsvp-failed-invite-1", "Failed answer surfaces a notification")

        // Handler missing: the action must not crash and drops silently.
        manager.setRSVPHandler(nil)
        manager.handleAction("RSVP_ACCEPT", meetingLink: nil, eventID: "invite-9", calendarID: "rsvp-cal")
        try context.equal(rsvpReplies.count, 3, "Unset handler drops the answer without crash")

        // Disabled or unavailable: no failure banner, no invite banner.
        manager.setRSVPHandler { _, _, _ in }
        pendingInvitesEnabled = false
        available = false
        manager.notifyRSVPFailure(for: "invite-1")
        deliveredIDs.removeAll()
        center.post(name: .businessBarPendingRSVPsAppeared, object: nil, userInfo: ["events": [invite]])
        try await settleRSVP()
        try context.equal(requests.count, 4, "Guards stop every later presentation path")

        // The delegate-extracted dispatch entry: scenarios cannot build a
        // UNNotificationResponse, so this is the closest drivable surface.
        enabled = true
        available = true
        rsvpReplies.removeAll()
        manager.setRSVPHandler { eventID, calendarID, status in
            rsvpReplies.append((eventID, calendarID, status))
        }
        manager.dispatchAction("RSVP_ACCEPT", userInfo: ["eventID": "dispatch-1", "calendarID": "rsvp-cal"])
        try context.equal(rsvpReplies.map(\.0), ["dispatch-1"], "Dispatch entry forwards payload fields")
        manager.dispatchAction("JOIN_ACTION", userInfo: ["meetingLink": "https://fixture.invalid/join"])
        try context.equal(opened.last?.absoluteString, "https://fixture.invalid/join", "Dispatch entry routes join links")

        // Live dependency closures: the flag readers default to
        // UserDefaults.standard, so seed the isolated domain and read back.
        let liveManager = NotificationManager()
        UserDefaults.standard.set(true, forKey: BusinessBar.Constants.Defaults.notifyNewEvents)
        UserDefaults.standard.set(true, forKey: BusinessBar.Constants.Defaults.notifyPendingInvites)
        try context.expect(liveManager.dependenciesForCoverage.isNewEventsEnabled(), "Live new-events flag reads the default")
        try context.expect(liveManager.dependenciesForCoverage.isPendingInvitesEnabled(), "Live pending-invites flag reads the default")
        UserDefaults.standard.set(false, forKey: BusinessBar.Constants.Defaults.notifyNewEvents)
        UserDefaults.standard.set(false, forKey: BusinessBar.Constants.Defaults.notifyPendingInvites)
        try context.expect(!liveManager.dependenciesForCoverage.isNewEventsEnabled(), "Live new-events flag follows the stored value")
        try context.expect(!liveManager.dependenciesForCoverage.isPendingInvitesEnabled(), "Live pending-invites flag follows the stored value")
    }

    private static func settleRSVP() async {
        for _ in 0..<8 { await Task.yield() }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func lifecycle(_ context: CoverageContext) async throws {
        let fixture = try LifecycleFixture(context, label: "lifecycle-first")
        let effects = fixture.effects
        let defaults = fixture.defaults
        let originalID = UUID()
        let oldPrompt = "Improve the writing of the following text. Keep its language, meaning and approximate length. Reply with the improved text only, no commentary.\n\n[placeholder]"
        effects.templates = [
            PromptTemplate(id: originalID, name: "Improve writing", prompt: oldPrompt),
            PromptTemplate(name: "Custom", prompt: "Keep my custom prompt"),
            PromptTemplate(name: "Renamed old template", prompt: oldPrompt)
        ]
        let shortcutKey = "KeyboardShortcuts_" + KeyboardShortcuts.Name.toggleCompanionChat.rawValue
        let oldShortcut = KeyboardShortcuts.Shortcut(.l, modifiers: [.command, .shift])
        defaults.set(String(data: try JSONEncoder().encode(oldShortcut), encoding: .utf8), forKey: shortcutKey)
        defaults.set(true, forKey: Constants.Defaults.noSleepActivateOnStart)
        defaults.set(5, forKey: Constants.Defaults.notificationMinutesBefore)
        defaults.set(true, forKey: Constants.Defaults.endOfEventNotification)
        fixture.badge.addApp(MonitoredApp(bundleIdentifier: "coverage.lifecycle", displayName: "Fixture"))
        fixture.store.events = [fixture.event("timed"), fixture.event("all-day", allDay: true)]
        let delegate = fixture.delegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try context.equal(Array(effects.order.prefix(4)), ["activation:\(NSApplication.ActivationPolicy.accessory.rawValue)", "crash.install", "url.register", "shortcut"], "Launch effect order preserved")
        try context.equal(effects.order.last, "crash.alert", "Prior-crash alert stays last")
        try context.equal(effects.shortcuts, [KeyboardShortcuts.Shortcut(.b, modifiers: [.command])], "Old default shortcut migrated without global registration")
        try context.expect(defaults.bool(forKey: "companionChatShortcutMigratedToCmdB"), "Shortcut migration flag persisted privately")
        try context.equal(effects.templates.first?.id, originalID, "Template migration preserves identifier")
        try context.equal(effects.templates.first?.prompt, PromptTemplate.defaults.first?.prompt, "Exact old shipped template upgraded")
        try context.equal(effects.templates[1].prompt, "Keep my custom prompt", "Edited template preserved")
        try context.equal(effects.templates[2].prompt, oldPrompt, "Unknown template name preserved")
        try context.equal(effects.templateSaves, 1, "Changed template set saved once")
        try context.equal(effects.providers, [.eventKit], "Default provider creates injected EventKit boundary")
        try context.equal(effects.authorizations, 1, "Launch requests injected notification authorization")
        try context.expect(delegate.getMeetingManager() === fixture.meeting && delegate.getNoSleepManager() === fixture.noSleep, "Launch retains injected real managers")
        try context.expect(delegate.preferencesBadgeManager === fixture.badge && delegate.preferencesMeetingManager === fixture.meeting, "Preferences reuse initialized managers")
        try context.expect(effects.statusBacking != nil, "Status factory backing retained by delegate")
        try context.equal(effects.onboardingShows, 1, "First launch shows injected onboarding")
        try context.expect(defaults.bool(forKey: "hasLaunchedBefore"), "First launch flag written privately")
        try context.equal(effects.powerActivations, 1, "Configured no-sleep launch routes only injected power callback")
        try context.equal(effects.delayed.map(\.0), [1.5], "Accessibility prompt delay preserved")
        effects.delayed.removeFirst().1()
        try context.equal(effects.permissionAlerts, 1, "Delayed callback presents injected permission decision")
        try context.equal(effects.openedSettings, 1, "Permission approval uses fake manager settings callback")
        effects.statusAction?()
        delegate.showPreferences(initialTab: .general)
        try context.equal(effects.preferencesCreations, 1, "Preferences window created once")
        try context.equal(effects.preferencesShows, 2, "Repeated preferences requests show retained presentation")

        for _ in 0..<100 {
            await fixture.meeting.refreshEvents()
            effects.drain()
            if effects.requests.contains(where: { $0.identifier == "timed_5" }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try context.expect(effects.requests.contains { $0.identifier == "timed_5" }, "Published events schedule lead reminder")
        try context.expect(effects.requests.contains { $0.identifier == "timed_0" }, "End-of-event setting retains existing zero-minute semantics")
        try context.expect(!effects.requests.contains { $0.identifier.hasPrefix("all-day_") }, "All-day events never schedule reminders")
        fixture.store.events = [fixture.event("replacement")]
        await fixture.meeting.refreshEvents()
        effects.drain()
        try context.expect(effects.removals.contains(["timed"]), "Removed calendar events cancel prior identifiers")
        defaults.set(false, forKey: Constants.Defaults.featureCalendar)
        fixture.center.post(name: .businessBarPreferencesDidChange, object: nil)
        effects.drain()
        try context.expect(effects.clears > 0, "Disabled calendar clears notifications")

        // RSVP routing installed at launch: notification answers reach the
        // meeting manager, success clears bookkeeping and removes the
        // banner, failure surfaces the retry banner. The feature flag was
        // switched off by the clearing check above, so it goes back on for
        // the fixture refresh to post invites.
        effects.pendingInvitesEnabled = true
        defaults.set(true, forKey: Constants.Defaults.featureCalendar)
        let inviteEvent = CalendarEvent(
            id: "invite", title: "Launch invite",
            startDate: fixture.now.addingTimeInterval(3600), endDate: fixture.now.addingTimeInterval(7200),
            location: nil, notes: nil, url: nil, calendar: fixture.store.calendar,
            organizer: "Owner", attendees: ["Owner"], myRSVPStatus: .pending
        )
        fixture.store.events = [inviteEvent]
        await fixture.meeting.refreshEvents()
        effects.drain()
        for _ in 0..<100 {
            if effects.requests.contains(where: { $0.identifier == "invite-invite" }) { break }
            await settleRSVP()
        }
        try context.expect(effects.requests.contains { $0.identifier == "invite-invite" }, "Invite identifier embeds event id")
        fixture.notification.handleAction("RSVP_ACCEPT", meetingLink: nil, eventID: "invite", calendarID: "lifecycle")
        for _ in 0..<100 {
            if !fixture.store.receivedRSVPs.isEmpty { break }
            await settleRSVP()
        }
        try context.equal(fixture.store.receivedRSVPs.map(\.2), [.accepted], "Notification answer routes to the manager")
        try context.expect(effects.removals.contains(["invite-invite"]), "Answered invite banner removed")
        fixture.store.respondResult = false
        fixture.notification.handleAction("RSVP_DECLINE", meetingLink: nil, eventID: "invite", calendarID: "lifecycle")
        for _ in 0..<100 {
            if fixture.store.receivedRSVPs.count >= 2 { break }
            await settleRSVP()
        }
        try context.equal(fixture.store.receivedRSVPs.count, 2, "Failed answer still reaches the manager")
        try context.expect(effects.requests.contains { $0.identifier == "rsvp-failed-invite" }, "Failed answer posts the retry banner")
        let previousDelegate = NSApp.delegate
        NSApp.delegate = delegate
        try context.expect(AppDelegate.sharedMeetingManager() === fixture.meeting, "Shared manager accessor finds the delegate's manager")

        // Shared panel against the swapped delegate: the live effects read
        // the shared manager, and the last answer dismisses through onFinish.
        let panelInvite = CalendarEvent(
            id: "panel-invite", title: "Panel invite",
            startDate: fixture.now.addingTimeInterval(3600), endDate: fixture.now.addingTimeInterval(7200),
            location: "Fixture room", notes: nil, url: nil, calendar: fixture.store.calendar,
            organizer: "Owner", attendees: ["Owner", "Me"], myRSVPStatus: .pending
        )
        fixture.store.events = [panelInvite]
        await fixture.meeting.refreshEvents()
        RSVPPanelController.shared.present()
        let sharedStore = RSVPPanelController.shared.storeForCoverage
        try context.expect(RSVPPanelController.shared.panelForCoverage != nil, "Shared panel materializes on present")
        try context.equal(sharedStore.current?.id, "panel-invite", "Shared panel lists the pending invite")
        NSApp.delegate = previousDelegate
        sharedStore.answer(.accepted)
        for _ in 0..<100 {
            if sharedStore.lastError != nil { break }
            await settleRSVP()
        }
        try context.expect(sharedStore.lastError != nil, "Answer without a live manager surfaces the failure")
        NSApp.delegate = delegate
        fixture.store.respondResult = true
        sharedStore.answer(.accepted)
        for _ in 0..<100 {
            if fixture.store.receivedRSVPs.count >= 3 { break }
            await settleRSVP()
        }
        try context.equal(fixture.store.receivedRSVPs.last?.0, "panel-invite", "Shared panel answer routes to the manager")
        try context.expect(fixture.store.receivedRSVPs.count == 3, "Panel answers join the earlier notification answers")
        for _ in 0..<100 {
            if RSVPPanelController.shared.panelForCoverage?.isVisible == false { break }
            await settleRSVP()
        }
        try context.expect(RSVPPanelController.shared.panelForCoverage?.isVisible == false, "Last answer closes the shared panel")
        NSApp.delegate = previousDelegate

        let reply = NSAppleEventDescriptor.null()
        delegate.handleURLEvent(getURLEvent: NSAppleEventDescriptor.null(), replyEvent: reply)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "fixture:/redirect?code=fixture"), forKeyword: AEKeyword(keyDirectObject))
        delegate.handleURLEvent(getURLEvent: event, replyEvent: reply)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try context.equal(effects.terminations, 1, "Lifecycle termination remains synchronous and injected")
        try await lifecycleVariants(context)
    }

    static func lifecycleVariants(_ context: CoverageContext) async throws {
        for (index, configured) in [true, false].enumerated() {
            let fixture = try LifecycleFixture(context, label: "lifecycle-provider-\(index)", trusted: configured)
            let effects = fixture.effects
            effects.configured = configured
            effects.preferencesFail = true
            effects.permissionDecision = false
            effects.templates = [PromptTemplate(name: "Custom", prompt: "Unchanged")]
            fixture.defaults.set(CalendarProvider.google.rawValue, forKey: Constants.Defaults.calendarProvider)
            fixture.defaults.set(true, forKey: "hasLaunchedBefore")
            fixture.defaults.set(false, forKey: Constants.Defaults.featureNoSleep)
            fixture.defaults.set(true, forKey: Constants.Defaults.noSleepActivateOnStart)
            let key = "KeyboardShortcuts_" + KeyboardShortcuts.Name.toggleCompanionChat.rawValue
            fixture.defaults.set(index == 0 ? "not-json" : String(data: try JSONEncoder().encode(KeyboardShortcuts.Shortcut(.k, modifiers: [.command])), encoding: .utf8), forKey: key)
            if index == 0 {
                fixture.defaults.set(true, forKey: "companionTemplatesMigratedToOutputTags")
                fixture.badge.addApp(MonitoredApp(bundleIdentifier: "coverage.trusted", displayName: "Trusted fixture"))
            }
            let delegate = fixture.delegate()
            try context.expect(delegate.preferencesBadgeManager === fixture.badge, "Prelaunch preferences badge factory remains lazy and safe")
            try context.expect(delegate.preferencesMeetingManager === fixture.meeting, "Prelaunch preferences meeting factory remains safe")
            delegate.showPreferences(initialTab: .general)
            try context.equal(effects.preferencesErrors, 1, "Failed preferences construction uses injected error presentation")
            effects.preferencesFail = false
            delegate.showPreferences(initialTab: .general)
            delegate.showPreferences()
            try context.equal(effects.preferencesCreations, 2, "Failed window can retry, successful window retained")
            // initializeManagers reads the stored provider from the
            // process-standard suite (not the injected fixture defaults), so
            // the fallback branch needs google seeded in standard; the
            // private rewrite write lands in the injected defaults. The
            // static GoogleAuthConfig.isConfigured is false in this harness,
            // so the provider itself is EventKit either way, and the injected
            // closure only gates the stored-key rewrite.
            let standard = UserDefaults.standard
            let previousStandardProvider = standard.string(forKey: Constants.Defaults.calendarProvider)
            defer { standard.set(previousStandardProvider, forKey: Constants.Defaults.calendarProvider) }
            standard.set(CalendarProvider.google.rawValue, forKey: Constants.Defaults.calendarProvider)
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            try context.equal(effects.providers.last, .eventKit, "Unconfigured Google credentials fall back to EventKit")
            try context.equal(
                fixture.defaults.string(forKey: Constants.Defaults.calendarProvider),
                configured ? CalendarProvider.google.rawValue : CalendarProvider.eventKit.rawValue,
                "Stored provider survives a configured claim and falls back privately otherwise"
            )
            try context.equal(effects.onboardingCreations, 0, "Returning launch skips onboarding")
            try context.equal(effects.powerActivations, 0, "Disabled no-sleep feature suppresses activation")
            try context.expect(effects.shortcuts.isEmpty, "Malformed or customized shortcut is not overwritten")
            try context.equal(effects.templateSaves, 0, "Unchanged or already migrated templates are not rewritten")
            try context.expect(effects.delayed.isEmpty, "Trusted or empty monitored-app set suppresses permission prompt")
            effects.drain()
        }
        let denied = try LifecycleFixture(context, label: "lifecycle-permission-denied")
        denied.effects.permissionDecision = false
        denied.badge.addApp(MonitoredApp(bundleIdentifier: "coverage.denied", displayName: "Denied fixture"))
        let delegate = denied.delegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        denied.effects.delayed.removeFirst().1()
        try context.equal(denied.effects.openedSettings, 0, "Declining accessibility alert does not open settings")
        denied.effects.drain()
    }
}
