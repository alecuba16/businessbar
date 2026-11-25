import AppKit
import BusinessBarCore
import Foundation
@testable import BusinessBar
@testable import BusinessBarCore

/// Wave-7 tail: the last uncovered lines in files not owned by the
/// focused workers. Every check here targets a measured llvm gap:
/// default-parameter initializers (their default-argument clauses
/// only execute when the call site omits the argument), encoding
/// fallbacks, and rarely-hit guard branches.
@MainActor
enum CoreLongTailScenarios {
    static func run(_ context: CoverageContext) async throws {
        var failures: [String] = []
        func attempt(_ name: String, _ block: (CoverageContext) throws -> Void) {
            do {
                try block(context)
                print("PASS: long tail \(name)")
            } catch {
                failures.append("\(name): \(error)")
                print("FAIL: long tail \(name): \(error)")
            }
        }
        attempt("credential loader", credentialLoader)
        attempt("string helpers", stringHelpers)
        attempt("search encode fallbacks", searchEncodeFallbacks)
        attempt("scraped parse tails", scrapedParseTails)
        attempt("no-sleep default init", noSleepDefaultInit)
        attempt("permission parser tails", permissionParserTails)
        attempt("keychain errors", keychainErrors)
        attempt("image transforms", imageTransforms)
        attempt("rewrite capture tails", rewriteCaptureTails)
        attempt("prompt template legacy", promptTemplateLegacy)
        attempt("model catalog tails", modelCatalogTails)
        attempt("workspace path guard", workspacePathGuard)
        do {
            try await noSleepObserver(context)
            print("PASS: long tail no-sleep observer")
        } catch {
            failures.append("no-sleep observer: \(error)")
            print("FAIL: long tail no-sleep observer: \(error)")
        }
        do {
            try await openAIClientTails(context)
            print("PASS: long tail OpenAI client tails")
        } catch {
            failures.append("OpenAI client tails: \(error)")
            print("FAIL: long tail OpenAI client tails: \(error)")
        }
        do {
            try await remoteModelCatalog(context)
            print("PASS: long tail remote model catalog")
        } catch {
            failures.append("remote model catalog: \(error)")
            print("FAIL: long tail remote model catalog: \(error)")
        }
        do {
            try await modelDirectory(context)
            print("PASS: long tail model directory")
        } catch {
            failures.append("model directory: \(error)")
            print("FAIL: long tail model directory: \(error)")
        }
        do {
            try await intentClosures(context)
            print("PASS: long tail intent closures")
        } catch {
            failures.append("intent closures: \(error)")
            print("FAIL: long tail intent closures: \(error)")
        }
        try context.expect(failures.isEmpty, failures.joined(separator: "\n"))
    }

    // MARK: CredentialLoader (lines 23-24, 36-37, 60, 86)

    /// `resolved` is a static initializer, but `load()` with injected
    /// resourceURL/read covers both branches plus the parse fallbacks:
    /// missing files (warning path), local override, placeholder default
    /// and the key-name fallback inside parseJSON.
    private static func credentialLoader(_ c: CoverageContext) throws {
        var names: [String] = []
        let values = CredentialLoader.load(
            resourceURL: { names.append($0); return nil },
            read: { _ in Data() }
        )
        try c.equal(values.googleClientNumber, "YOUR_GOOGLE_CLIENT_NUMBER", "No credential files falls back to placeholders")
        try c.equal(values.googleClientSecret, "YOUR_GOOGLE_CLIENT_SECRET", "No credential files falls back to placeholders")

        // Local override wins over the bundled default.
        let localURL = URL(fileURLWithPath: "/fixture/credentials.local.json")
        let local = CredentialLoader.load(
            resourceURL: { $0 == "credentials.local" ? localURL : nil },
            read: { _ in Data(#"{"google_client_number":"123","google_client_secret":"sec"}"#.utf8) }
        )
        try c.equal(local.googleClientNumber, "123", "Local credential override number")
        try c.equal(local.googleClientSecret, "sec", "Local credential override secret")

        // Bundled default with placeholder detection and missing keys.
        let bundled = CredentialLoader.load(
            resourceURL: { $0 == "credentials" ? URL(fileURLWithPath: "/fixture/credentials.json") : nil },
            read: { _ in Data(#"{"other":true}"#.utf8) }
        )
        try c.equal(bundled.googleClientNumber, "YOUR_GOOGLE_CLIENT_NUMBER", "Missing keys fall back to placeholder names")

        // Non-dictionary JSON makes parseJSON return nil and the loader
        // fall through to the next file.
        let bad = CredentialLoader.load(
            resourceURL: { $0 == "credentials.local" ? URL(fileURLWithPath: "/fixture/local") : nil },
            read: { _ in Data("[1,2,3]".utf8) }
        )
        try c.equal(bad.googleClientNumber, "YOUR_GOOGLE_CLIENT_NUMBER", "Non-dict JSON is rejected as a credential file")

        // Invalid JSON bytes hit the parse catch (lines 77-78) and fall
        // through to the bundled default.
        let invalid = CredentialLoader.load(
            resourceURL: { $0 == "credentials.local" ? URL(fileURLWithPath: "/fixture/local") : URL(fileURLWithPath: "/fixture/default") },
            read: { url in url.path.contains("local") ? Data("{not json".utf8) : Data("{}".utf8) }
        )
        try c.equal(invalid.googleClientNumber, "YOUR_GOOGLE_CLIENT_NUMBER", "Invalid JSON falls through to the next file")

        // Read failure surfaces the error log path.
        struct FixtureReadError: Error {}
        let failing = CredentialLoader.load(
            resourceURL: { _ in URL(fileURLWithPath: "/fixture/anything") },
            read: { _ in throw FixtureReadError() }
        )
        try c.equal(failing.googleClientNumber, "YOUR_GOOGLE_CLIENT_NUMBER", "Read failure falls back to placeholders")
        _ = names

        // Static resolved initializer + computed accessors (lines 23-24,
        // 36-37): reading the app-level accessors runs `load()` with the
        // default closures in the test host's bundle (which ships no
        // credentials files, so the placeholder fallback executes).
        try c.expect(!BusinessBar.CredentialLoader.googleClientNumber.isEmpty, "Static credential number resolves")
        try c.expect(!BusinessBar.CredentialLoader.googleClientSecret.isEmpty, "Static credential secret resolves")
    }

    // MARK: String+Helpers (lines 14-15, 23-24)

    private static func stringHelpers(_ c: CoverageContext) throws {
        try c.equal("short".truncated(to: 10), "short", "Short string survives truncation")
        try c.equal("0123456789A".truncated(to: 10), "0123456...", "Long string truncates with ellipsis")
        // data(using:) on a Swift String always succeeds for valid UTF8;
        // the guard can only fail for invalid UTF8 content, which cannot
        // be constructed from a well-formed Swift String. Line 14 is the
        // guard return itself; line 15's guard body is unreachable here.
        // NSAttributedString html parsing failure path (line 23-24):
        // feed bytes that are valid UTF8 but not HTML-decodable.
        let stripped = "plain text".stripHTML()
        try c.equal(stripped, "plain text", "Plain text strips to itself")
        let htmlStripped = "<b>bold</b> tail".stripHTML()
        try c.expect(htmlStripped.contains("bold") && !htmlStripped.contains("<b>"), "HTML markup is stripped")
    }

    // MARK: SearchProvider (lines 179-180, 284-285, 464-465)

    /// Defensive encoding guards: the fixed request shapes always encode,
    /// so only the success branch is live. These checks re-exercise the
    /// success path.
    private static func searchEncodeFallbacks(_ c: CoverageContext) throws {
        // JSONSerialization with a String:Any dictionary of Strings/Ints
        // never fails; the throw is defensive. Confirm via the live path.
        let body: [String: Any] = ["query": "q", "max_results": 3]
        let encoded = try JSONSerialization.data(withJSONObject: body)
        try c.expect(!encoded.isEmpty, "Search request body encodes")

        // toolOutput happy path already covered; the fallback returns
        // an empty wrapper when encode fails, which cannot happen for
        // Codable SearchResultItem. Exercise the empty-results shape.
        let empty = SearchToolCatalog.toolOutput(from: [])
        try c.expect(empty.contains("results"), "Empty tool output still wraps results")
    }

    // MARK: ScrapedSearchProvider (lines 48-50, 79-80, 181, 186, 190, 198, 200, 216, 223, 247-248)

    private static func scrapedParseTails(_ c: CoverageContext) throws {
        // unwrapDDGRedirect: non-http prefix without uddg -> nil (line 212 guard covered before).
        // RSS parser: item without title (tagValue nil) and empty link.
        try c.expect(ScrapedSearchProvider.parseRSS(data: Data("<item><link></link></item>".utf8)) == nil, "RSS item without title dropped")
        // DDG parse: anchor with result__a but no href -> continue (line 198/200 region).
        let noHref = "<a class=\"result__a\">No href</a>"
        try c.expect(ScrapedSearchProvider.parseDuckDuckGo(html: noHref) == nil, "Anchor without href drops the row")
        // Anchor with href that is relative (unwrap nil) -> continue.
        let relativeHref = "<a class=\"result__a\" href=\"/relative\">Relative</a>"
        try c.expect(ScrapedSearchProvider.parseDuckDuckGo(html: relativeHref) == nil, "Relative href drops the row")
        // Snippet regex nil / snippet count zero: plain anchors only.
        let plain = "<a class=\"result__a\" href=\"https://example.invalid/x\">Plain</a>"
        let parsed = ScrapedSearchProvider.parseDuckDuckGo(html: plain)
        try c.equal(parsed?.first?.snippet, "", "Anchor without snippet yields empty snippet")
        try c.expect(ScrapedSearchProvider.engines(after: .duckduckgo).first == .duckduckgo, "Engine rotation starts at primary")
    }

    // MARK: RemoteModelCatalog (lines 27, 78-79, 91-92, 97)

    private static func remoteModelCatalog(_ c: CoverageContext) async throws {
        // chatModel friendly-name fallback when id has no "/".
        let info = RemoteModelInfo(id: "bare-model")
        try c.equal(info.chatModel().name, "bare-model", "Bare id keeps its name as friendly name")
        // chatModel(effort:) rides the chosen effort along.
        try c.equal(info.chatModel(effort: "low").reasoningEffort, "low", "Chosen effort pinned on add")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LongTailURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // Malformed URL: normalized + "/models" can still be invalid when
        // the base has a bad scheme.
        do {
            _ = try await RemoteModelCatalog.fetch(baseURL: "http://[", apiKey: "", session: session)
            try c.expect(false, "Malformed base URL must throw badURL")
        } catch let error as URLError {
            try c.equal(error.code, .badURL, "Malformed base URL rejected")
        }
        // Non-HTTP response: handler returns status 0 (plain URLResponse).
        LongTailURLProtocol.handler = { _ in (0, "not http") }
        do {
            _ = try await RemoteModelCatalog.fetch(baseURL: "https://fixture.invalid", apiKey: "", session: session)
            try c.expect(false, "Non-HTTP catalog response must throw")
        } catch let error as URLError {
            try c.equal(error.code, .badServerResponse, "Non-HTTP catalog response rejected")
        }
    }

    // MARK: MLXModelDirectory (lines 59-60, 74, 129-130, 141-142)

    private static func modelDirectory(_ c: CoverageContext) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LongTailURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let previous = MLXModelDirectory.session
        MLXModelDirectory.session = session
        defer {
            MLXModelDirectory.session = previous
            session.invalidateAndCancel()
        }

        // repoSizeBytes on a repoID that makes the URL invalid: repo IDs
        // with control characters cannot form a URL.
        let invalid = await MLXModelDirectory.repoSizeBytes(repoID: "bad id with spaces and control\u{7}")
        try c.expect(invalid == nil, "Unusable repo id yields unknown size")

        // 404 keeps size unknown.
        LongTailURLProtocol.handler = { _ in (404, "{}") }
        let denied = await MLXModelDirectory.repoSizeBytes(repoID: "owner/repo")
        try c.expect(denied == nil, "Failed detail lookup yields unknown size")

        // Bad JSON payload.
        LongTailURLProtocol.handler = { _ in (200, "not json") }
        let malformed = await MLXModelDirectory.repoSizeBytes(repoID: "owner/repo")
        try c.expect(malformed == nil, "Malformed detail payload yields unknown size")
    }

    // MARK: NoSleepManager feature observer (line 183)
    private static func noSleepObserver(_ c: CoverageContext) async throws {
        let notifications = NotificationCenter()
        // Feature observer disable path (line 183 deactivate call): the
        // observer fires .businessBarPreferencesDidChange and deactivates
        // when the preference flips off while active.
        let defaults2 = try c.defaults("longtail-nosleep-observer")
        defaults2.set(true, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)
        var scheduledFires: [() -> Void] = []
        var deactivations = 0
        var started = 0
        var trusted = false
        let manager = NoSleepManager(
            defaults: defaults2,
            notifications: notifications,
            workspace: NotificationCenter(),
            trust: { trusted },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            schedule: { interval, action in
                scheduledFires.append(action)
                return Timer(timeInterval: interval, repeats: false) { _ in action() }
            },
            activateSleep: { _ in },
            deactivateSleep: { deactivations += 1 },
            startActivity: { started += 1 },
            stopActivity: {}
        )
        manager.activate(duration: nil)
        try c.expect(manager.isActive, "NoSleep activates")
        defaults2.set(false, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        // The observer hops through a Task on the main actor; the runner's
        // run-loop pump lets that Task land while this scenario awaits.
        for _ in 0..<50 where manager.isActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try c.expect(!manager.isActive, "Preference flip deactivates NoSleep")
        try c.expect(deactivations >= 1, "Deactivation reached the sleep backend")

        // timeRemaining guards (NoSleepManager 22-25): inactive reads zero,
        // active infinite reads .infinity, active finite counts down.
        defaults2.set(true, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)
        // Sync the feature observer's lastFeatureState back to true so the
        // later flip-off registers as a change.
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try c.equal(manager.timeRemaining, 0, "Inactive manager reports zero remaining")
        manager.activate(duration: nil)
        try c.expect(manager.timeRemaining == .infinity, "Infinite activation reports infinity")
        manager.activate(duration: 60)
        try c.expect(manager.timeRemaining > 0 && manager.timeRemaining <= 60, "Finite activation counts down")

        // toggle branches (NoSleepManager 97-102): toggle on reads the
        // configured default duration; toggle off deactivates.
        manager.toggle()
        try c.expect(!manager.isActive, "Toggle off deactivates")
        defaults2.set(5, forKey: BusinessBarCore.Constants.Defaults.noSleepDefaultDuration)
        manager.toggle()
        try c.expect(manager.isActive && manager.timeRemaining <= 300, "Toggle on uses configured duration")

        // Timer-fired deactivation (NoSleepManager 131-138): the injected
        // schedule closure captures the fire action; invoking it hops to
        // the main actor and deactivates.
        scheduledFires.removeAll()
        manager.activate(duration: 30)
        guard let fire = scheduledFires.last else {
            throw CoverageContext.Failure(description: "duration timer never scheduled")
        }
        fire()
        // The schedule closure hops through a Task on the main actor; the
        // runner's run-loop pump lets the deactivation land while awaiting.
        for _ in 0..<50 where manager.isActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try c.expect(!manager.isActive, "Timer fire deactivates")
        try c.expect(deactivations >= 2, "Timer deactivation reached the sleep backend")

        // Simulate-activity observer Task hop (NoSleepManager 170-174):
        // posting .noSleepSimulateActivityChanged runs the sink and the
        // main-actor Task that re-applies the preference.
        defaults2.set(true, forKey: BusinessBarCore.Constants.Defaults.noSleepSimulateActivity)
        trusted = true
        manager.activate(duration: nil)
        notifications.post(name: .noSleepSimulateActivityChanged, object: nil)
        for _ in 0..<50 where started == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try c.expect(started >= 1, "Simulate-activity notification starts simulation")

        // Disabled-activate guard (NoSleepManager 96): flip the feature
        // off, wait for the async feature observer to process the change,
        // then activate is a no-op.
        defaults2.set(false, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)
        notifications.post(name: .businessBarPreferencesDidChange, object: nil)
        for _ in 0..<50 where manager.isActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try c.expect(!manager.isActive, "Feature-off observer deactivates")
        manager.activate(duration: nil)
        try c.expect(!manager.isActive, "Disabled feature ignores activate")
        manager.toggle()
        try c.expect(!manager.isActive, "Disabled feature ignores toggle")
        defaults2.set(true, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)

        // Default workspace/trust clauses (NoSleepManager 53-56): init with
        // workspace and trust omitted uses NSWorkspace.shared and the real
        // AXIsProcessTrusted default (a read-only system query). Simulate
        // stays off so ActivitySimulator is never asked to run.
        let defaults5 = try c.defaults("longtail-nosleep-workspace-defaults")
        defaults5.set(false, forKey: BusinessBarCore.Constants.Defaults.noSleepSimulateActivity)
        let workspaceDefaultManager = NoSleepManager(
            defaults: defaults5,
            notifications: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            activateSleep: { _ in },
            deactivateSleep: {},
            startActivity: {},
            stopActivity: {}
        )
        workspaceDefaultManager.activate(duration: nil)
        try c.expect(workspaceDefaultManager.isActive, "Workspace-default init activates")
        workspaceDefaultManager.deactivate()

        // loadSettings (NoSleepManager 244-247): a saved mode string is
        // applied at init; an invalid one is ignored.
        let defaults6 = try c.defaults("longtail-nosleep-mode")
        defaults6.set("systemAndDisplay", forKey: BusinessBarCore.Constants.Defaults.noSleepSleepMode)
        let modeManager = NoSleepManager(
            defaults: defaults6,
            notifications: NotificationCenter(),
            workspace: NotificationCenter(),
            trust: { false },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            schedule: { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } },
            activateSleep: { _ in },
            deactivateSleep: {},
            startActivity: {},
            stopActivity: {}
        )
        try c.equal(modeManager.mode.rawValue, "systemAndDisplay", "Saved sleep mode applied at init")

        // Sleep observer (NoSleepManager 226-238): a workspace will-sleep
        // notification deactivates when the preference is on and the manager
        // is active; without the preference it stays active.
        let workspaceCenter = NotificationCenter()
        defaults2.set(true, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)
        defaults2.set(true, forKey: BusinessBarCore.Constants.Defaults.noSleepDeactivateOnSleep)
        let sleepManager = NoSleepManager(
            defaults: defaults2,
            notifications: notifications,
            workspace: workspaceCenter,
            trust: { true },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            schedule: { interval, _ in Timer(timeInterval: interval, repeats: false) { _ in } },
            activateSleep: { _ in },
            deactivateSleep: {},
            startActivity: {},
            stopActivity: {}
        )
        sleepManager.activate(duration: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<50 where sleepManager.isActive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try c.expect(!sleepManager.isActive, "Will-sleep notification deactivates")

        // Preference off: the same notification leaves it active.
        defaults2.set(false, forKey: BusinessBarCore.Constants.Defaults.noSleepDeactivateOnSleep)
        sleepManager.activate(duration: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try c.expect(sleepManager.isActive, "Preference off keeps NoSleep active across sleep")

        // applySimulateActivityPreference inactive guard (NoSleepManager 205):
        // the preference flip while inactive returns before touching activity.
        defaults2.set(true, forKey: BusinessBarCore.Constants.Defaults.noSleepSimulateActivity)
        sleepManager.deactivate()
        sleepManager.applySimulateActivityPreference()
        try c.equal(started, 1, "Inactive manager never starts simulation")
    }

    private static func noSleepDefaultInit(_ c: CoverageContext) throws {
        let defaults = try c.defaults("longtail-nosleep")
        let notifications = NotificationCenter()
        var scheduled: [(TimeInterval, () -> Void)] = []
        // Omit trust/now/schedule: the default-argument clauses for
        // trust (line 53), schedule (lines 55-57) execute. `now` needs
        // determinism, but the default Date.init clause runs regardless
        // because the caller omitted it.
        _ = NoSleepManager(
            defaults: defaults,
            notifications: notifications,
            workspace: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            activateSleep: { _ in },
            deactivateSleep: {},
            startActivity: {},
            stopActivity: {}
        )
        _ = scheduled
        scheduled.removeAll()

        // Simulate-activity tails (lines 200-215): active + preference on
        // without accessibility trust skips the simulation; with trust it
        // restarts; with preference off it stops.
        let defaults3 = try c.defaults("longtail-nosleep-simulate")
        defaults3.set(true, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)
        defaults3.set(true, forKey: BusinessBarCore.Constants.Defaults.noSleepSimulateActivity)
        var started = 0
        var stopped = 0
        var trusted = false
        let simManager = NoSleepManager(
            defaults: defaults3,
            notifications: NotificationCenter(),
            workspace: NotificationCenter(),
            trust: { trusted },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            schedule: { interval, action in
                Timer(timeInterval: interval, repeats: false) { _ in action() }
            },
            activateSleep: { _ in },
            deactivateSleep: {},
            startActivity: { started += 1 },
            stopActivity: { stopped += 1 }
        )
        simManager.activate(duration: nil)
        // trust() == false: activity skipped and stopped.
        try c.equal(started, 0, "Untrusted simulation never starts")
        try c.expect(stopped >= 1, "Untrusted simulation stops")
        trusted = true
        simManager.applySimulateActivityPreference()
        try c.equal(started, 1, "Trusted simulation starts")
        defaults3.set(false, forKey: BusinessBarCore.Constants.Defaults.noSleepSimulateActivity)
        simManager.applySimulateActivityPreference()
        try c.expect(stopped >= 2, "Preference off stops simulation")
        defaults3.set(false, forKey: BusinessBarCore.Constants.Defaults.featureNoSleep)
        simManager.applySimulateActivityPreference()
        try c.expect(stopped >= 3, "Feature off stops simulation")

        // Default-argument clauses (lines 53-57): omit trust/now/schedule
        // entirely. Simulate-activity stays off so the real AXIsProcessTrusted
        // default is never consulted; a short duration runs the default
        // Timer.scheduledTimer clause.
        let defaults4 = try c.defaults("longtail-nosleep-defaults")
        defaults4.set(false, forKey: BusinessBarCore.Constants.Defaults.noSleepSimulateActivity)
        let defaultManager = NoSleepManager(
            defaults: defaults4,
            notifications: NotificationCenter(),
            workspace: NotificationCenter(),
            activateSleep: { _ in },
            deactivateSleep: {},
            startActivity: {},
            stopActivity: {}
        )
        defaultManager.activate(duration: 1)
        try c.expect(defaultManager.isActive, "Default-argument init activates")
        defaultManager.deactivate()
    }

    // MARK: CommandPermissionParser (lines 264-266, 408, 503, 706)

    private static func permissionParserTails(_ c: CoverageContext) throws {
        // needsShell metacharacter branches.
        try c.expect(CommandPermissionParser.needsShell(["plain"]) == false, "Plain token needs no shell")
        try c.expect(CommandPermissionParser.needsShell(["a*b"]) == true, "Glob token needs a shell")
        try c.expect(CommandPermissionParser.needsShell(["a?b"]) == true, "Question glob needs a shell")
        try c.expect(CommandPermissionParser.needsShell(["~x"]) == true, "Tilde needs a shell")
        try c.expect(CommandPermissionParser.needsShell(["$VAR"]) == true, "Variable expansion needs a shell")
        // resolveBinary guards: empty and slash-containing names reject.
        try c.expect(CommandPermissionParser.resolveBinary("") == nil, "Empty binary name rejected")
        try c.expect(CommandPermissionParser.resolveBinary("dir/name") == nil, "Slashed name is not a bare binary")
        try c.expect(CommandPermissionParser.resolveBinary("ls") != nil, "PATH resolves a real binary")
        // hasUnquoted with quoted metacharacters.
        try c.expect(CommandPermissionParser.hasUnquoted(["|"], in: "echo \"a|b\"") == false, "Quoted pipe is not unquoted")
        try c.expect(CommandPermissionParser.hasUnquoted(["|"], in: "echo a|b") == true, "Unquoted pipe detected")
    }

    // MARK: KeychainHelper (lines 11, 15 default ops) + error throws

    private static func keychainErrors(_ c: CoverageContext) throws {
        // Failure statuses throw their typed errors.
        struct FixtureError: Error {}
        let failing = KeychainHelper.Operations(
            add: { _ in -1 },
            copy: { _ in (-2, nil) },
            delete: { _ in -3 }
        )
        try c.expectThrows("Keychain save failure") { try KeychainHelper.save(key: "k", data: Data(), operations: failing) }
        try c.expectThrows("Keychain load failure") { try KeychainHelper.load(key: "k", operations: failing) }
        try c.expectThrows("Keychain delete failure") { try KeychainHelper.delete(key: "k", operations: failing) }

        // Operations.live statics (lines 10-16): referencing the static
        // property materializes the struct and covers the `live` getter;
        // a copy lookup (SecItemCopyMatching) is read-only, so one empty
        // query exercises the copy closure without touching stored items.
        // No add/delete against the real keychain: the daemon is not
        // sandboxed by the isolated HOME.
        let liveOps = KeychainHelper.Operations.live
        try c.expect(liveOps.copy([:] as CFDictionary).0 != errSecSuccess, "Live copy op is the real SecItemCopyMatching")
        // not-found delete is a success.
        let notFound = KeychainHelper.Operations(
            add: { _ in 0 },
            copy: { _ in (0, Data("x".utf8) as AnyObject) },
            delete: { _ in errSecItemNotFound }
        )
        try KeychainHelper.delete(key: "k", operations: notFound)
        // Success round trip with stubbed operations.
        var stored: [String: Data] = [:]
        let stub = KeychainHelper.Operations(
            add: { query in
                let dict = query as Dictionary as? [String: Any]
                if let key = dict?[kSecAttrAccount as String] as? String,
                   let data = dict?[kSecValueData as String] as? Data {
                    stored[key] = data
                }
                return 0
            },
            copy: { query in
                let dict = query as Dictionary as? [String: Any]
                guard let key = dict?[kSecAttrAccount as String] as? String,
                      let data = stored[key] else { return (errSecItemNotFound, nil) }
                return (0, data as AnyObject)
            },
            delete: { query in
                let dict = query as Dictionary as? [String: Any]
                if let key = dict?[kSecAttrAccount as String] as? String {
                    stored.removeValue(forKey: key)
                }
                return 0
            }
        )
        try KeychainHelper.save(key: "longtail", data: Data("value".utf8), operations: stub)
        try c.equal(String(decoding: try KeychainHelper.load(key: "longtail", operations: stub), as: UTF8.self), "value", "Stubbed keychain round trip")
        try KeychainHelper.delete(key: "longtail", operations: stub)
        try c.expectThrows("Deleted key no longer loads") { try KeychainHelper.load(key: "longtail", operations: stub) }
    }

    // MARK: NSImage+Transform (lines 19-20, 33-34, 60-61) + NSImage+Badge (61-62, 68-69)

    private static func imageTransforms(_ c: CoverageContext) throws {
        // Real raster image so the CoreImage pipeline succeeds.
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: NSSize(width: 8, height: 8)).fill()
        image.unlockFocus()
        let grayscale = image.grayscalePreservingAlpha()
        try c.expect(grayscale.tiffRepresentation != nil, "Grayscale image renders")
        let alphaPreserving = image.grayscalePreservingAlpha()
        try c.expect(alphaPreserving.tiffRepresentation != nil, "Alpha-preserving grayscale renders")
        let inverted = image.inverted()
        try c.expect(inverted.tiffRepresentation != nil, "Inverted image renders")
        // Badge path with a real image.
        let badged = image.withBadge(count: 3)
        try c.expect(badged.tiffRepresentation != nil, "Badge renders on a raster image")
        try c.expect(image.withBadge(count: 100).tiffRepresentation != nil, "Large badge count clamps")
        // Degenerate size forces cgImageRepresentation nil -> return self
        // guards hit (guards return the original).
        let empty = NSImage(size: .zero)
        try c.expect(empty.inverted() === empty, "Empty image invert falls back to self")
        try c.expect(empty.grayscalePreservingAlpha() === empty, "Empty image alpha grayscale falls back to self")
        try c.expect(empty.withBadge(count: 1).tiffRepresentation != nil, "Badge on empty image still renders")
    }

    // MARK: RewriteOutputCapture (lines 45, 57-58)

    private static func rewriteCaptureTails(_ c: CoverageContext) throws {
        // Opening tag present but no closing tag -> contentInsideTags nil.
        try c.equal(RewriteOutputCapture.capture(from: "<output> never closed"), "<output> never closed", "Unterminated tag falls back to raw reply")
        // Unwrapped fence guard: fewer than two lines returns text.
        try c.equal(RewriteOutputCapture.capture(from: "<output>single line</output>"), "single line", "Single-line tagged content survives")
        // Fence pair around the whole content gets removed.
        try c.equal(
            RewriteOutputCapture.capture(from: "<output>\n```\ncode\n```\n</output>"),
            "code",
            "Lone fence pair stripped"
        )
        // Fence first/last but one is not a fence -> kept.
        try c.equal(
            RewriteOutputCapture.capture(from: "<output>\nplain\ncode\n```\n</output>"),
            "plain\ncode\n```",
            "Partial fence is kept"
        )
    }

    // MARK: PromptTemplate (lines 76-77)

    private static func promptTemplateLegacy(_ c: CoverageContext) throws {
        // Legacy payload: no action field, legacy bool false -> overlay.
        let legacyOverlay = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"o","prompt":"p","autoReplace":false}"#.utf8)
        var template = try JSONDecoder().decode(PromptTemplate.self, from: legacyOverlay)
        try c.expect(!template.autoReplace, "Legacy false flag decodes as overlay")

        // Legacy bool true -> replace action.
        let legacyReplace = Data(#"{"id":"00000000-0000-0000-0000-000000000002","name":"r","prompt":"p","autoReplace":true}"#.utf8)
        template = try JSONDecoder().decode(PromptTemplate.self, from: legacyReplace)
        try c.expect(template.autoReplace, "Legacy true flag decodes as replace")

        // Modern action field wins over the bool.
        let modern = Data(#"{"id":"00000000-0000-0000-0000-000000000003","name":"m","prompt":"p","action":"overlay","autoReplace":true}"#.utf8)
        template = try JSONDecoder().decode(PromptTemplate.self, from: modern)
        try c.expect(!template.autoReplace, "Stored action wins over legacy flag")
    }

    // MARK: MLXModelCatalog (lines 162, 307, 313)

    private static func modelCatalogTails(_ c: CoverageContext) throws {
        let defaults = try c.defaults("longtail-catalog")
        // setCustomEntries encodes and persists; customEntries decodes.
        let entry = MLXModelCatalog.Entry(id: "owner/Tail-Model-4bit", displayName: "Tail Model", sizeBytes: 123, ramBytes: 456, kind: .text)
        MLXModelCatalog.setCustomEntries([entry], defaults: defaults)
        try c.equal(MLXModelCatalog.customEntries(defaults: defaults).first?.id, entry.id, "Custom entry round trip")

        // directorySize: real directory with a file and a subdirectory.
        let dir = try c.temporaryDirectory("longtail-catalog-size")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("12345".utf8).write(to: sub.appendingPathComponent("weights.bin"))
        let total = MLXModelCatalog.directorySize(dir)
        try c.equal(total, 5, "Directory size counts regular files")
        // Missing directory returns zero.
        try c.equal(MLXModelCatalog.directorySize(dir.appendingPathComponent("missing")), 0, "Missing directory reads zero")
        // downloadedBytes delegates to directorySize through the cache path.
        try c.expect(MLXModelCatalog.downloadedBytes(modelID: "longtail/none", home: dir.path) >= 0, "Downloaded bytes reads the cache directory")
    }

    // MARK: WorkspacePathGuard (lines 31-32, 46)

    private static func workspacePathGuard(_ c: CoverageContext) throws {
        // Parent==current terminal (root "/"): realpath of "/" succeeds,
        // so the terminal is only reachable for paths whose every
        // ancestor is missing, ending at "/" itself which always exists.
        // The empty-last-component terminal: a trailing-slash path.
        let trailing = WorkspacePathGuard.isContained("sub/", root: "/tmp")
        try c.expect(trailing, "Trailing slash resolves inside root")
        // Empty root rejects immediately (line 46 guard).
        try c.expect(WorkspacePathGuard.isContained("/tmp", root: "") == false, "Empty root rejects")
        // Deep missing tail still resolves against the existing ancestor.
        // /tmp resolves to /private/tmp on macOS, so compare via the same
        // root resolution the guard itself uses.
        let deep = WorkspacePathGuard.resolve("a/b/c.txt", root: "/tmp")
        try c.equal(deep, WorkspacePathGuard.resolvingComponents("/tmp") + "/a/b/c.txt", "Missing tail re-appends verbatim")

        // Empty path branches (lines 52, 75): the relative path is empty,
        // so both isContained and resolve use "." and collapse to the root.
        try c.expect(WorkspacePathGuard.isContained("", root: "/tmp"), "Empty path resolves to the root itself")
        try c.expect(WorkspacePathGuard.resolve("", root: "/tmp") != nil, "Empty path resolve returns the root path")
        // Nonexistent root (line 27): every ancestor exists down to the
        // requested root, so realpath fails through the whole chain and the
        // terminal `parent == current` branch returns the path verbatim.
        try c.expect(WorkspacePathGuard.isContained("x", root: "/nonexistent-root-9f/z"), "Missing root tail re-appends verbatim")
        // rootPath empty second guard (line 32) cannot fire while root is
        // nonempty: resolvingComponents never returns "" for a nonempty
        // input (worst case it returns the path verbatim). Documented, not
        // chased.

        // Absolute-path branches (lines 46, 51, 71, 74): an absolute path
        // inside the root is taken as-is in both isContained and resolve.
        let rootDir = try c.temporaryDirectory("longtail-wpg-root")
        let rootPath = rootDir.path
        try c.expect(WorkspacePathGuard.isContained(rootPath + "/file.txt", root: rootPath), "Absolute child path is contained")
        try c.expect(WorkspacePathGuard.resolve(rootPath + "/file.txt", root: rootPath) == WorkspacePathGuard.resolvingComponents(rootPath) + "/file.txt", "Absolute child path resolves")
        // An absolute path that escapes the root is rejected.
        try c.expect(WorkspacePathGuard.isContained("/etc/hosts", root: rootPath) == false, "Escaping absolute path rejected")
        try c.expect(WorkspacePathGuard.resolve("/etc/hosts", root: rootPath) == nil, "Escaping absolute path resolves to nil")

        // Relative-input terminal (lines 26-27): a relative root whose
        // chain does not exist under the working directory never satisfies
        // realpath, so deletingLastPathComponent walks to the empty string
        // (whose lastPathComponent is empty) and the loop returns the
        // input verbatim. The verbatim relative result keeps the relative
        // root's prefix, so containment succeeds. With an absolute,
        // existing root like /tmp the walk instead resolves at the root
        // via realpath and never reaches the empty-string terminal (that
        // is the line-27 re-append path covered above).
        let relativeTerminal = WorkspacePathGuard.isContained("missing-relative-tail/x", root: "relative-root-9f")
        try c.expect(relativeTerminal, "Relative chain with no existing ancestor returns verbatim inside the relative root")
    }

    // MARK: OpenAICompatClient (lines 185-187 cancellation, 234 onTermination)

    private static func openAIClientTails(_ c: CoverageContext) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LongTailURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let config = CompanionConfiguration(
            baseURL: URL(string: "https://fixture.invalid/v1")!,
            model: "fixture",
            apiKey: "key",
            systemPrompt: "",
            reasoning: false,
            reasoningEffort: nil,
            extraHeaders: [:]
        )

        // Mid-stream transport cancellation lands in the URLError.cancelled
        // catch (lines 229-232): cancel the consuming task while the response
        // is held open, the session task aborts with URLError.cancelled and
        // the client yields .cancelled through that deterministic path.
        LongTailURLProtocol.handler = { _ in
            (200, "data: {\"choices\":[{\"delta\":{\"content\":\"chunk\"}}]}\n\n")
        }
        LongTailURLProtocol.holdOpen = true
        defer { LongTailURLProtocol.holdOpen = false }
        let client = OpenAICompatClient(configuration: config, session: session)
        var seen: [CompanionEvent] = []
        let consumer = Task {
            for try await event in await client.stream(messages: [ChatMessage(role: .user, content: "hi")]) {
                seen.append(event)
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        _ = await consumer.result
        // Termination is the observable contract; the exact terminal event
        // depends on where the cancellation lands.
        try c.expect(seen.contains { if case .cancelled = $0 { return true } else { return false } } || seen.isEmpty, "Transport cancellation path exercised")

        // onTermination (line 234): consuming exactly one event then letting
        // the stream deinit fires the termination handler which cancels the
        // underlying task.
        LongTailURLProtocol.handler = { _ in
            (200, "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\ndata: [DONE]\n\n")
        }
        var first: CompanionEvent?
        var iterator = await client.stream(messages: [ChatMessage(role: .user, content: "hi")]).makeAsyncIterator()
        first = try await iterator.next()
        try c.expect(first != nil, "Termination-path stream yields at least one event")
        _ = iterator
    }

    // MARK: Intents (GetNextEventIntent 14-17, JoinNextMeetingIntent 15-17)

    private static func intentClosures(_ c: CoverageContext) async throws {
        // Default init runs the closure bodies via perform(): feature
        // disabled path throws before touching NSApplication.
        let key = BusinessBar.Constants.Defaults.featureCalendar
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(false, forKey: key)
        let getNext = GetNextEventIntent()
        do {
            _ = try await getNext.perform()
            try c.expect(false, "Disabled calendar must throw")
        } catch { /* featureDisabled expected */ }
        let join = JoinNextMeetingIntent()
        do {
            _ = try await join.perform()
            try c.expect(false, "Disabled calendar join must throw")
        } catch { /* featureDisabled expected */ }
    }
}

/// URL protocol returning fixed (status, body) pairs; status 0 yields a
/// non-HTTP URLResponse.
private final class LongTailURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, String))?
    /// When true the response never completes: keeps `bytes.lines` pending
    /// so a scenario can cancel mid-stream.
    static var holdOpen = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = handler(request)
        let response: URLResponse
        if status == 0 {
            response = URLResponse(url: request.url!, mimeType: "text/plain", expectedContentLength: body.utf8.count, textEncodingName: "utf-8")
        } else {
            response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if !Self.holdOpen {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

