import Foundation
@testable import BusinessBarCore

private final class CommandProcessDouble: CommandProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Int32) -> Void)?
    private var terminations = 0
    private var kills = 0
    private let immediateExit: Int32?

    init(immediateExit: Int32? = nil) { self.immediateExit = immediateExit }

    func terminate() { lock.withLock { terminations += 1 } }
    func forceKill() { lock.withLock { kills += 1 } }
    func onTermination(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.withLock { self.handler = handler }
        if let immediateExit { handler(immediateExit) }
    }
    func finish(_ code: Int32) { lock.withLock { handler }?(code) }
    var ready: Bool { lock.withLock { handler != nil } }
    var terminationCount: Int { lock.withLock { terminations } }
    var killCount: Int { lock.withLock { kills } }
}

private final class CommandRuntimeDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    private var processes: [(CommandProcessDouble, OutputRingBuffer)] = []
    private var exits: [BackgroundCommandRegistry.CompletedResult] = []
    private let immediateExit: Int32?

    init(immediateExit: Int32? = nil) { self.immediateExit = immediateExit }

    func spawn(_ argv: [String], _ cwd: String) throws -> (any CommandProcess, OutputRingBuffer) {
        guard !argv.isEmpty else { throw ShellExecutor.ExecutionError.emptyArgv }
        let process = CommandProcessDouble(immediateExit: immediateExit)
        let buffer = OutputRingBuffer(headCap: 8, tailCap: 64, killCeiling: 128, now: { [weak self] in self?.now() ?? Date(timeIntervalSince1970: 0) })
        lock.withLock { processes.append((process, buffer)) }
        return (process, buffer)
    }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    func record(_ result: BackgroundCommandRegistry.CompletedResult) { lock.withLock { exits.append(result) } }
    var count: Int { lock.withLock { processes.count } }
    var exitCount: Int { lock.withLock { exits.count } }
    func process(_ index: Int) -> CommandProcessDouble { lock.withLock { processes[index].0 } }
    func buffer(_ index: Int) -> OutputRingBuffer { lock.withLock { processes[index].1 } }
}

private actor CommandSleepDouble {
    private var waiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
    private var registered: [UInt64: Int] = [:]
    private var finished = false
    func sleep(_ duration: UInt64) async {
        guard !finished else { return }
        registered[duration, default: 0] += 1
        await withCheckedContinuation { waiters.append((duration, $0)) }
    }
    func count(_ duration: UInt64) -> Int { registered[duration, default: 0] }
    func advance(_ duration: UInt64) {
        let ready = waiters.filter { $0.0 == duration }
        waiters.removeAll { $0.0 == duration }
        ready.forEach { $0.1.resume() }
    }
    func finish() {
        finished = true
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.1.resume() }
    }
}

private final class NotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor
enum CoreCommandPersistenceScenarios {
    static func run(_ context: CoverageContext) async throws {
        try permissions(context)
        try schemas(context)
        try buffers(context)
        try workspace(context)
        try persistence(context)
        try rewrite(context)
        try await registry(context)
        try await registryInactivity(context)
        try await registryImmediateExitAndHealthyOutput(context)
    }

    private static func permissions(_ c: CoverageContext) throws {
        typealias P = CommandPermissionParser
        try c.equal(P.tokenize(" echo '' \"two words\"\t'end'\nlast "), ["echo", "", "two words", "end", "last"], "Quoted argv preserves empty arguments")
        try c.expect(P.tokenize("   ") == nil, "Empty token stream fails")
        try c.expect(P.tokenize("echo 'unfinished") == nil, "Unclosed single quote fails")
        try c.expect(P.tokenize("echo \"unfinished") == nil, "Unclosed double quote fails")
        try c.equal(P.splitCompounds("one && two || three;four|five&six\nseven"), ["one", "two", "three", "four", "five", "six", "seven"], "Every compound separator splits")
        try c.equal(P.splitCompounds("echo 'a;b' && echo \"c|d\""), ["echo 'a;b'", "echo \"c|d\""], "Quoted separators remain literal")
        try c.expect(P.splitCompounds("; &") == nil, "Empty segments rejected")
        try c.expect(P.splitCompounds("echo '") == nil, "Unclosed compound rejected")
        for command in ["cat *.txt", "echo ?", "cat ~/file", "echo $HOME", "echo \"$HOME\"", "echo \\n", "echo \"\\n\""] {
            try c.expect(P.hasShellExpansion(command), "Expansion detected: \(command)")
        }
        for command in ["echo '$HOME'", "find . -name '*.swift'", "git diff HEAD~1", "echo \"*\""] {
            try c.expect(!P.hasShellExpansion(command), "Literal stays shell-free: \(command)")
        }
        for command in ["echo a|cat", "echo a&cat", "(echo a)", "echo a>file", "cat <file", "echo a\ncat"] {
            try c.expect(P.containsShellOperator(command), "Operator detected: \(command)")
        }
        try c.expect(!P.containsShellOperator("echo 'a|b'"), "Quoted operator ignored")
        try c.expect(P.resolveBinary("") == nil && P.resolveBinary("/bin/echo") == nil, "Binary resolver accepts bare names only")
        try c.expect(P.resolveBinary("businessbar_nonexistent_coverage_binary") == nil, "Missing executable unresolved")
        try c.equal(P.classify("echo plain"), .autoApproved(argv: ["echo", "plain"]), "Read-only command uses argv")
        let risks: [(String, CommandRisk)] = [
            ("", .unparseable), (String(repeating: "x", count: 10_001), .tooLong),
            ("echo $(id)", .substitution), ("echo `id`", .substitution), ("cat <(id)", .substitution), ("cat >(id)", .substitution),
            ("echo a; echo b", .compound), ("echo a > file", .shellSyntax), ("cat *.txt", .shellSyntax),
            ("echo 'unfinished", .unparseable), ("rm scratch", .modifiesFiles), ("unknown_coverage_binary", .unknownCommand),
            ("find . -delete", .modifiesFiles), ("find --pre=runner x", .modifiesFiles), ("git diff --output=file", .modifiesFiles)
        ]
        for (command, risk) in risks {
            try c.equal(P.classify(command), .needsConfirmation(reason: risk), "Risk classification: \(command.prefix(60))")
        }
        for flag in ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fls", "-fprint0", "--output", "--pre", "--pager", "--output=x", "--pre=x", "--pager=x"] {
            try c.expect(P.hasWriteFlag(["find", flag]), "Write flag detected: \(flag)")
        }
        try c.expect(!P.hasWriteFlag(["git", "log", "--pretty=short"]), "Pretty is not preprocessor")
        try c.expect(P.isAllowlisted(binaryName: "git", resolvedPath: "/usr/bin/git", argv: ["git", "-C", "repo", "--no-pager", "status"]), "Read-only git skips globals")
        try c.expect(!P.isAllowlisted(binaryName: "git", resolvedPath: "/usr/bin/git", argv: ["git", "-C"]), "Missing git subcommand rejected")
        try c.expect(!P.isAllowlisted(binaryName: "git", resolvedPath: "/usr/bin/git", argv: ["git", "push"]), "Mutating git rejected")
        try c.expect(!P.isAllowlisted(binaryName: "bad", resolvedPath: "/usr/bin/bad", argv: ["bad"]), "Unlisted executable rejected")
        let categories: [(String, CommandCategory)] = [("ls -l a b c d e", .readOnly), ("mkdir x", .fileWrite), ("rm x", .fileDelete), ("git -C repo push", .gitMutation), ("npm install", .packageManager), ("curl endpoint", .network), ("unknown x", .unknown), ("", .unknown), ("find . -delete", .fileDelete), ("xargs -r rm x", .fileDelete)]
        for (command, category) in categories {
            try c.equal(P.categorize(command).category, category, "Category: \(command)")
        }
        try c.equal(P.categorize("ls -l a b c d e").targets, ["a", "b", "c", "d"], "Targets omit flags and cap at four")
        try c.equal(P.compoundCategory("ls; mkdir x; rm x"), .fileDelete, "Deletion dominates compounds")
        try c.equal(P.compoundCategory("git push; npm install; curl x; mkdir x"), .fileWrite, "Highest compound rank retained")
        try c.equal(P.compoundCategory("unknown; ls"), .unknown, "Unknown risk dominates read-only")
        try c.expect(P.compoundCategory("ls") == nil, "Single command has no compound category")
        try c.equal(CommandCategory.allCases.map(\.label), ["read-only", "writes files or folders", "deletes files or folders", "changes git state", "installs or updates packages", "reaches the network", "unclassified"], "Category labels describe risk")
        try c.equal(CommandCategory.allCases.map(\.title), ["Read-only commands", "File writes", "File deletion", "Git changes", "Package managers", "Network", "Other commands"], "Category titles")
        try c.equal(CommandCategory.allCases.map { P.categoryRank($0) }, [0, 4, 5, 1, 2, 3, 6], "Category severity ordering")
        let riskCases: [CommandRisk] = [.modifiesFiles, .unknownCommand, .compound, .substitution, .shellSyntax, .tooLong, .unparseable]
        try c.equal(riskCases.map(\.label), ["writes files or changes state", "not a known read-only command", "runs multiple commands", "runs embedded command substitutions", "uses shell redirection or pipes", "long command", "could not be parsed safely"], "Risk explanations")
        try c.equal(CommandPermissionMode.allCases.map(\.label), ["Allow", "Ask", "Deny"], "Permission mode labels")
        try c.expect(P.resolve("echo safe", sessionPrefixes: [], mode: .deny).refused, "Deny rejects read-only")
        try c.equal(P.resolve("mkdir scratch", sessionPrefixes: [], mode: .allow).permission, .sessionApproved(command: "mkdir scratch"), "Allow permits ordinary mutation")
        for command in ["rm scratch", "cat .env", "cat config/.env.production", "cat .env.backup", "echo '"] {
            try c.expect(P.isDangerousCommand(command), "Dangerous allow exception: \(command)")
        }
        try c.expect(!P.isDangerousCommand("echo ordinary"), "Ordinary command safe")
        try c.equal(P.resolve("rm scratch", sessionPrefixes: [], mode: .allow).permission, .needsConfirmation(reason: .modifiesFiles), "Deletion still asks in Allow")
        try c.equal(P.classify("mkdir one && mkdir two", sessionPrefixes: ["mkdir *"]), .sessionApproved(command: "mkdir one && mkdir two"), "Every approved segment permits compound")
        try c.expect(!P.segmentMatchesPrefix("github-cli status", prefixes: ["git *"]), "Wildcard requires word boundary")
        try c.expect(!P.segmentMatchesPrefix("git $HOME", prefixes: ["git *"]), "Expansion never session-approved")
        try c.expect(!P.segmentMatchesPrefix("git status > file", prefixes: ["git *"]), "Redirection never segment-approved")
        try c.expect(!P.segmentMatchesPrefix("", prefixes: ["*"]), "Empty segment rejected")
        try c.expect(P.segmentMatchesPrefix("mkdir", prefixes: [" ", "mkdir *"]), "Wildcard covers bare prefix")
        try c.expect(P.segmentMatchesPrefix("mkdir 'two words'", prefixes: ["mkdir two words"]), "Rules compare normalized tokens")
        try c.expect(P.matchesPrefixRule("  git status ", prefixes: ["", "git *"]), "Persistent rules trim whitespace")
        try c.expect(!P.matchesPrefixRule("github-cli", prefixes: ["git *", "*"]), "Empty wildcard base cannot approve")
        try c.expect(!P.matchesPrefixRule("", prefixes: ["git *"]), "Empty command cannot match")
        let denied = P.resolve("mkdir x", sessionPrefixes: ["mkdir *"], mode: .allow, settings: .init(allowedPrefixes: ["mkdir *"], deniedPrefixes: ["mkdir *"]))
        try c.expect(denied.refused, "Persistent denial wins all allows")
        let dial = P.resolve("mkdir x", sessionPrefixes: [], mode: .allow, settings: .init(categoryModes: [.fileWrite: .deny]))
        try c.expect(dial.refused, "Category denial overrides master allow")
        let allowed = P.resolve("mkdir x", sessionPrefixes: [], mode: .ask, settings: .init(allowedPrefixes: ["mkdir *"]))
        try c.equal(allowed.permission, .sessionApproved(command: "mkdir x"), "Persistent allow resolves confirmation")
        try c.equal(allowed.category, .fileWrite, "Settings result retains category")
        try c.expect(CommandPermission.autoApproved(argv: ["a"]) != .sessionApproved(command: "a"), "Different permission variants differ")
        try c.equal(ShellExecutor.argv(for: .autoApproved(argv: ["echo", "x"]), command: "ignored"), ["echo", "x"], "Auto approval bypasses shell")
        for permission in [CommandPermission.sessionApproved(command: "x"), .needsConfirmation(reason: .unknownCommand)] {
            try c.equal(ShellExecutor.argv(for: permission, command: "echo x"), ["/bin/zsh", "-c", "echo x"], "Approved shell command argv")
        }
        for wrapper in ["env echo x", "nice echo x", "nohup echo x", "timeout 1 echo x", "/bin/echo x"] {
            try c.equal(P.classify(wrapper), .needsConfirmation(reason: .unknownCommand), "Wrappers and absolute paths cannot bypass argv allowlist")
        }
        try c.expectThrows("Empty argv rejects before creating a process") {
            _ = try ShellExecutor.spawn(argv: [], cwd: c.root.path)
        }
        let readOnlyGit = P.categorize("git --no-pager --git-dir scratch.git status")
        try c.equal(readOnlyGit.category, .readOnly, "Git read-only category skips standalone and valued global flags")
        try c.equal(readOnlyGit.targets, ["scratch.git", "status"], "Git category preserves non-flag targets")
        let substitutionDenied = P.resolve("echo $(id)", sessionPrefixes: [], mode: .allow, settings: .init(deniedPrefixes: ["echo $(id)"]))
        try c.expect(substitutionDenied.refused, "Persistent deny refuses exact embedded substitution")
        try c.equal(substitutionDenied.permission, .needsConfirmation(reason: .substitution), "Persistent deny retains substitution-specific risk")
    }

    private static func schemas(_ c: CoverageContext) throws {
        let schemas = CommandToolCatalog.toolSchemas()
        let names = schemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        try c.equal(names, ["run_command", "read_file", "list_files", "list_background_processes", "read_background_output", "stop_background_process"], "Catalog advertises every command tool")
        for schema in schemas {
            try c.equal(schema["type"] as? String, "function", "Tool uses function schema")
            let function = schema["function"] as? [String: Any]
            try c.equal((function?["parameters"] as? [String: Any])?["type"] as? String, "object", "Arguments use object schema")
        }
        try c.expect(CommandToolCatalog.decodeRunCommandArguments([:]) == nil, "Missing command rejected")
        try c.expect(CommandToolCatalog.decodeRunCommandArguments(["command": ""]) == nil, "Empty command rejected")
        try c.equal(CommandToolCatalog.decodeRunCommandArguments(["command": "ls"])?.background, false, "Background defaults false")
        try c.equal(CommandToolCatalog.decodeRunCommandArguments(["command": "ls", "background": true])?.command, "ls", "Run command decoded")
        try c.equal(CommandToolCatalog.decodeRunCommandArguments(["command": "ls", "background": true])?.background, true, "Background true retained")
        let read = CommandToolCatalog.decodeReadFileArguments(["path": "a", "offset": -4, "limit": 8_000])
        try c.equal(read.path, "a", "Read path retained")
        try c.equal(read.offset, 1, "Offset lower bound")
        try c.equal(read.limit, 2_000, "Read limit upper bound")
        try c.equal(CommandToolCatalog.decodeReadFileArguments([:]).limit, 500, "Read default limit")
        try c.equal(CommandToolCatalog.decodeReadFileArguments(["limit": 0]).limit, 1, "Read limit lower bound")
        try c.equal(CommandToolCatalog.decodeReadFileArguments(["offset": 9]).offset, 9, "Positive offset retained")
        try c.equal(CommandToolCatalog.decodeListFilesArguments([:]).path, "", "List defaults root")
        try c.expect(!CommandToolCatalog.decodeListFilesArguments([:]).recursive, "List defaults shallow")
        try c.expect(CommandToolCatalog.decodeListFilesArguments(["recursive": true]).recursive, "Recursive list decoded")
        try c.equal(CommandToolCatalog.decodeReadBackgroundArguments([:]).lines, 50, "Background default lines")
        try c.equal(CommandToolCatalog.decodeReadBackgroundArguments(["lines": -1]).lines, 1, "Background lower clamp")
        try c.equal(CommandToolCatalog.decodeReadBackgroundArguments(["handle": "h", "lines": 999]).lines, 500, "Background upper clamp")
        try c.equal(CommandToolCatalog.decodeReadBackgroundArguments(["handle": "h"]).handle, "h", "Handle decoded")
        try c.expect(CommandToolCatalog.decodeStopArguments([:]) == nil, "Missing stop handle rejected")
        try c.expect(CommandToolCatalog.decodeStopArguments(["handle": ""]) == nil, "Empty stop handle rejected")
        try c.equal(CommandToolCatalog.decodeStopArguments(["handle": "h"]), "h", "Stop handle decoded")
    }

    private static func buffers(_ c: CoverageContext) throws {
        let buffer = OutputRingBuffer(headCap: 4, tailCap: 6, killCeiling: 12)
        try c.equal(buffer.snapshot, "", "Initial buffer empty")
        buffer.append(Data("abcd".utf8))
        try c.equal(buffer.snapshot, "abcd", "Head-only output")
        buffer.append(Data("efghij".utf8))
        try c.equal(buffer.snapshot, "abcdefghij", "Head tail overlap removed")
        buffer.append(Data("kl".utf8))
        try c.equal(buffer.snapshot, "abcd\n[… 2 bytes dropped …]\nghijkl", "Elision preserves head and latest tail")
        try c.expect(!buffer.exceededKillCeiling, "Ceiling is exclusive")
        buffer.append(Data("m".utf8))
        try c.expect(buffer.exceededKillCeiling, "Output above ceiling detected")
        try c.expect(buffer.idleInterval >= 0, "Activity time updated")
        let lines = OutputRingBuffer(headCap: 0, tailCap: 100)
        lines.append(Data("one\n\nthree\nfour\n".utf8))
        try c.equal(lines.lastLines(2), "three\nfour\n", "Tail line selection retains final newline")
        try c.equal(lines.lastLines(20), "one\n\nthree\nfour\n", "Short output retained")
        try c.equal(lines.lastLines(0), "\n", "Zero-line request keeps trailing newline")
        let plain = OutputRingBuffer()
        plain.append(Data("one\ntwo".utf8))
        try c.equal(plain.lastLines(1), "two", "No newline invented")
        let utf8 = OutputRingBuffer(headCap: 64, tailCap: 64)
        utf8.append(Data("café 🧪".utf8))
        try c.equal(utf8.snapshot, "café 🧪", "UTF8 retained in untruncated buffer")
        let invalid = OutputRingBuffer(headCap: 4, tailCap: 4)
        invalid.append(Data([0xff, 0x61]))
        try c.equal(invalid.snapshot, "�a", "Invalid UTF8 replaced safely")
        let split = OutputRingBuffer(headCap: 1, tailCap: 4)
        split.append(Data([0xc3]))
        split.append(Data([0xa9, 0x61]))
        try c.equal(split.snapshot, "��a", "UTF8 fragments split at capture boundary use replacement characters")
        let zero = OutputRingBuffer(headCap: 0, tailCap: 0)
        zero.append(Data("abc".utf8))
        try c.equal(zero.snapshot, "\n[… 3 bytes dropped …]\n", "Zero capture capacity remains bounded")
        let time = CommandRuntimeDouble()
        let timed = OutputRingBuffer(headCap: 4, tailCap: 4, killCeiling: 100, now: { time.now() })
        time.advance(12)
        try c.equal(timed.idleInterval, 12, "Buffer idle uses elapsed clock")
        timed.append(Data("x".utf8))
        try c.equal(timed.idleInterval, 0, "Output resets inactivity")
    }

    private static func workspace(_ c: CoverageContext) throws {
        let root = try c.temporaryDirectory("command-workspace")
        let outside = try c.temporaryDirectory("outside")
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside"), withDestinationURL: child)
        try c.expect(WorkspacePathGuard.isContained("", root: root.path), "Empty request resolves root")
        try c.expect(WorkspacePathGuard.isContained(child.path, root: root.path), "Absolute child contained")
        try c.expect(WorkspacePathGuard.isContained("inside/new.txt", root: root.path), "Internal symlink with missing file contained")
        try c.expect(!WorkspacePathGuard.isContained("escape/new.txt", root: root.path), "External symlink escape rejected")
        try c.expect(!WorkspacePathGuard.isContained("../other", root: root.path), "Parent traversal rejected")
        try c.expect(!WorkspacePathGuard.isContained(root.path + "-evil", root: root.path), "Sibling prefix rejected")
        try c.expect(!WorkspacePathGuard.isContained("file", root: ""), "Empty workspace rejected")
        try c.equal(WorkspacePathGuard.resolve("inside/new.txt", root: root.path), child.path + "/new.txt", "Resolver canonicalizes existing symlink ancestor")
        try c.equal(WorkspacePathGuard.resolve(child.path, root: root.path), child.path, "Absolute resolver retained")
        try c.expect(WorkspacePathGuard.resolve("escape/file", root: root.path) == nil, "Escaped resolve returns nil")
        try c.equal(WorkspacePathGuard.resolvingComponents(""), "", "Empty canonicalization has no existing ancestor and remains empty")
    }

    private static func persistence(_ c: CoverageContext) throws {
        let defaults = try c.defaults("command-persistence")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy\"}".utf8)
        let profile = try decoder.decode(ModelProfile.self, from: legacy)
        try c.equal(profile.baseURL, "", "Legacy profile defaults endpoint")
        try c.equal(profile.model, "", "Legacy profile defaults model")
        let profiles = ModelProfileStore(defaults: defaults, key: "profiles")
        try c.equal(profiles.load(), [], "No profile data")
        defaults.set(Data("invalid".utf8), forKey: "profiles")
        try c.equal(profiles.load(), [], "Corrupt profile data ignored")
        let notifications = NotificationCount()
        let observer = NotificationCenter.default.addObserver(forName: ModelProfileStore.didChangeNotification, object: nil, queue: nil) { _ in notifications.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let full = ModelProfile(name: "Local", baseURL: "http://invalid.test", model: "local", reasoningEffort: "high", isLocalMLX: true)
        profiles.save([profile, full])
        try c.equal(profiles.load(), [profile, full], "Profile round trip")
        try c.equal(notifications.value, 1, "Profile save posts notification")
        let providers = ChatProviderStore(defaults: defaults, key: "providers", legacyKey: "profiles")
        try c.expect(!providers.migrated, "Provider migration initially absent")
        let migrated = providers.load()
        try c.equal(migrated.map(\.id), [profile.id, full.id], "Migration preserves credential identifiers")
        try c.equal(migrated.last?.kind, .localMLX, "Legacy local flag migrates kind")
        try c.equal(migrated.last?.models.first?.reasoningEffort, "high", "Migration keeps reasoning effort")
        try c.expect(providers.migrated && defaults.data(forKey: "profiles") != nil, "Migration saves new blob and retains rollback blob")
        try c.equal(providers.load(), migrated, "Migration persisted once")
        let providerNotifications = NotificationCount()
        let providerObserver = NotificationCenter.default.addObserver(forName: ChatProviderStore.didChangeNotification, object: nil, queue: nil) { _ in providerNotifications.increment() }
        defer { NotificationCenter.default.removeObserver(providerObserver) }
        providers.save([])
        try c.equal(providers.load(), [], "Explicit empty providers do not remigrate")
        try c.equal(providerNotifications.value, 1, "Provider notification posted")
        let emptyProviders = ChatProviderStore(defaults: defaults, key: "absent", legacyKey: "absentLegacy")
        try c.equal(emptyProviders.load(), [], "Absent migration returns empty")
        defaults.set(Data("bad".utf8), forKey: "absent")
        try c.equal(emptyProviders.load(), [], "Corrupt provider data ignored")
        let model = try decoder.decode(ChatModel.self, from: legacy)
        try c.equal(model.acceptsText, true, "Legacy model accepts text")
        try c.equal(model.acceptsImages, false, "Legacy model does not accept images")
        try c.equal(model.model, "", "Legacy model missing identifier defaults empty")
        let explicitModel = ChatModel(name: "Test", model: "model", systemPrompt: "system", reasoningEnabled: true, reasoningEffort: "low", acceptsText: false, acceptsImages: true, effortOptions: ["low"])
        try c.equal(try decoder.decode(ChatModel.self, from: encoder.encode(explicitModel)), explicitModel, "Full model Codable round trip")
        var provider = ChatProvider(name: "Agent", baseURL: "", models: [explicitModel], kind: .acpAgent, acpCommand: "agent", acpArguments: ["--stdio"])
        provider.headers = [.init(name: "Authorization", value: "test-secret")]
        let encodedProvider = try encoder.encode(provider)
        let restored = try decoder.decode(ChatProvider.self, from: encodedProvider)
        try c.expect(restored.headers == nil, "Provider JSON excludes secret headers")
        try c.equal(restored.acpArguments, ["--stdio"], "ACP arguments survive Codable")
        try c.equal(restored.model(id: explicitModel.id), explicitModel, "Provider model lookup")
        try c.expect(restored.model(id: UUID()) == nil, "Missing model lookup")
        let legacyProvider = try decoder.decode(ChatProvider.self, from: Data("{\"id\":\"\(id)\",\"name\":\"Local\",\"isLocalMLX\":true}".utf8))
        try c.expect(legacyProvider.isLocalMLXProvider, "Legacy local provider decodes")
        let remote = try decoder.decode(ChatProvider.self, from: legacy)
        try c.equal(remote.kind, .openAICompat, "Missing provider kind defaults remote")
        try c.equal(ChatProviderKind.allCases.map(\.label), ["OpenAI-compatible", "Local", "ACP agent"], "Provider kind labels")
        let templateLegacy = Data("{\"id\":\"\(id)\",\"name\":\"Legacy\",\"prompt\":\"Fix\",\"autoReplace\":true}".utf8)
        try c.equal(try decoder.decode(PromptTemplate.self, from: templateLegacy).action, .replace, "Legacy template flag migrates")
        for action in [TemplateAction.overlay, .replace, .append, .appendLineBreak] {
            let template = PromptTemplate(name: "Custom", prompt: "[placeholder]/[placeholder]", action: action, reasoningEffort: "high", modelID: id)
            try c.equal(try decoder.decode(PromptTemplate.self, from: encoder.encode(template)), template, "Template round trip for \(action)")
            try c.equal(template.render(with: "x"), "x/x", "Every placeholder substituted")
            try c.expect(!action.label.isEmpty, "Template action label")
        }
        try c.equal(PromptTemplate(name: "Plain", prompt: "Fix").render(with: "text"), "Fix\n\ntext", "Missing placeholder appends selection")
        let templates = TemplateStore(defaults: defaults, key: "templates")
        try c.equal(templates.load(), PromptTemplate.defaults, "Template store seeds defaults")
        let edited = PromptTemplate(name: PromptTemplate.defaults[0].name, prompt: "User edit")
        let templateNotifications = NotificationCount()
        let templateObserver = NotificationCenter.default.addObserver(forName: TemplateStore.didChangeNotification, object: nil, queue: nil) { _ in templateNotifications.increment() }
        defer { NotificationCenter.default.removeObserver(templateObserver) }
        templates.save([edited])
        let merged = templates.load()
        try c.equal(merged.first, edited, "Built-in user edit retained")
        try c.equal(merged.count, PromptTemplate.defaults.count, "Missing built-ins merged")
        try c.equal(templates.load(), merged, "Merged defaults saved")
        try c.equal(templateNotifications.value, 1, "Only explicit template save notifies")
        templates.save([])
        try c.equal(templates.load(), PromptTemplate.defaults, "Empty templates recover defaults")
        defaults.set(Data("bad".utf8), forKey: "templates")
        try c.equal(templates.load(), PromptTemplate.defaults, "Corrupt templates recover defaults")
        try c.expectThrows("Required model name must decode") { _ = try decoder.decode(ChatModel.self, from: Data("{}".utf8)) }
        let directory = try c.temporaryDirectory("chat-sessions")
        let store = ChatSessionStore(directoryURL: directory)
        try c.equal(store.loadAll(), [], "Empty session store")
        var oldest = ChatSession(title: "old", createdAt: Date(timeIntervalSince1970: 10.9), updatedAt: Date(timeIntervalSince1970: 20.9))
        store.save(oldest)
        oldest.createdAt = Date(timeIntervalSince1970: 10)
        oldest.updatedAt = Date(timeIntervalSince1970: 20)
        try c.equal(store.load(id: oldest.id), oldest, "Session dates truncate to ISO seconds")
        let middle = ChatSession(title: "middle", updatedAt: Date(timeIntervalSince1970: 100))
        let newest = ChatSession(title: "new", updatedAt: Date(timeIntervalSince1970: 200))
        store.save(middle)
        store.save(newest)
        try Data("bad json".utf8).write(to: directory.appendingPathComponent("bad.json"))
        try Data("keep".utf8).write(to: directory.appendingPathComponent("note.txt"))
        try c.equal(store.loadAll().map(\.id), [newest.id, middle.id, oldest.id], "Sessions sorted and corrupt JSON skipped")
        try c.expect(store.load(id: UUID()) == nil, "Missing session returns nil")
        try c.equal(store.keepNewestSessions(-1), 0, "Negative retention ignored")
        try c.equal(store.keepNewestSessions(10), 0, "No pruning within count")
        try c.equal(store.applyRetention(maxAgeDays: 0, maxSessionCount: 2), 1, "Count retention removes oldest")
        try c.equal(store.applyRetention(maxAgeDays: 1, maxSessionCount: 0), 2, "Age retention removes stale sessions")
        store.save(newest)
        try c.equal(store.keepNewestSessions(0), 1, "Keep zero deletes every valid session")
        store.save(oldest)
        store.delete(id: oldest.id)
        try c.expect(store.load(id: oldest.id) == nil, "Delete removes session")
        store.save(newest)
        store.deleteAll()
        try c.equal(store.loadAll(), [], "Delete all clears valid and corrupt JSON")
        try c.expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("note.txt").path), "Delete all retains unrelated files")
        let blockedURL = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockedURL)
        let blocked = ChatSessionStore(directoryURL: blockedURL)
        blocked.save(newest)
        try c.equal(blocked.loadAll(), [], "Invalid store directory returns empty listing")
        try c.expect(blocked.load(id: newest.id) == nil, "Failed save creates no readable session")
        try c.equal(blocked.deleteOlderThan(days: 1), 0, "Invalid directory pruning is harmless")
        blocked.deleteAll()
        try c.equal(try Data(contentsOf: blockedURL), Data("block".utf8), "Failed store operations preserve blocking file")
    }

    private static func rewrite(_ c: CoverageContext) throws {
        try c.expect(RewriteOutputCapture.containsOutputTags("before<output>x</output>after"), "Complete tags recognized")
        for text in ["x", "<output>x", "</output>x<output>"] {
            try c.expect(!RewriteOutputCapture.containsOutputTags(text), "Incomplete or reversed tags rejected")
        }
        let captures: [(String, String)] = [
            ("before<output>  result \n</output>after", "result"),
            ("<output>```swift\nlet x = 1\n```</output>", "let x = 1"),
            ("<output>paragraph\n```code\ninside\n```\nend</output>", "paragraph\n```code\ninside\n```\nend"),
            ("Sure!\n\nResult", "Result"), ("I corrected the typo\nResult", "Result"),
            ("Sure!", "Sure!"), ("Genuine first line\nsecond", "Genuine first line\nsecond"),
            ("<output></output>", ""), ("<output>```\n```</output>", "")
        ]
        for (input, expected) in captures { try c.equal(RewriteOutputCapture.capture(from: input), expected, "Rewrite extraction") }
    }

    private static func eventually(_ message: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            await Task.yield()
        }
        throw CoverageContext.Failure(description: message)
    }

    private static func registry(_ c: CoverageContext) async throws {
        let runtime = CommandRuntimeDouble()
        let clock = CommandSleepDouble()
        let registry = BackgroundCommandRegistry(onExit: { runtime.record($0) }, inactivity: 120, wallClock: 300, spawn: { try runtime.spawn($0, $1) }, now: { runtime.now() }, sleep: { await clock.sleep($0) })
        let session = UUID()
        let other = UUID()
        let unknown = UUID()
        let unknownInfo = await registry.info(unknown)
        let unknownOutput = await registry.output(unknown)
        let unknownStopped = await registry.stop(unknown)
        try c.expect(unknownInfo == nil, "Unknown registry handle")
        try c.expect(unknownOutput == nil, "Unknown registry output")
        try c.expect(!unknownStopped, "Unknown stop refused")
        try await c.expectThrowsAsync("Injected spawn failures propagate") {
            _ = try await registry.runBackground(sessionID: session, command: "empty", argv: [], cwd: "/unused")
        }
        let first = try await registry.runBackground(sessionID: session, command: "fake background", argv: ["fake"], cwd: "/unused")
        let second = try await registry.runBackground(sessionID: other, command: "other session", argv: ["fake"], cwd: "/unused")
        try c.expect(first.running && first.exitCode == nil, "Background starts running")
        runtime.buffer(0).append(Data("one\ntwo\n".utf8))
        try c.equal(await registry.output(first.handle, lines: 1), "two\n", "Running output uses line tail")
        try c.equal(await registry.listBackground(sessionID: session).map(\.handle), [first.handle], "Session filters handles")
        runtime.process(0).finish(7)
        try await eventually("Background exit callback delivered") { await registry.info(first.handle)?.exitCode == 7 }
        try c.equal(await registry.info(first.handle)?.endedReason, "normal", "Normal exit reason")
        try c.equal(await registry.output(first.handle, lines: 1), "one\ntwo\n", "Exited output returns complete snapshot")
        runtime.process(0).finish(8)
        await Task.yield()
        let pending = await registry.drainPending(sessionID: session)
        try c.equal(pending.count, 1, "Duplicate exit ignored")
        try c.equal(pending.first?.exitCode, 7, "First exit status retained")
        try c.equal(pending.first?.command, "fake background", "Pending preserves command")
        try c.equal(pending.first?.sessionID, session, "Pending preserves session")
        try c.equal(pending.first?.output, "one\ntwo\n", "Pending preserves output")
        try c.equal(runtime.exitCount, 1, "Exit hook once")
        try c.equal(await registry.drainPending(sessionID: session).count, 0, "Drain clears only consumed results")
        let exitedStopped = await registry.stop(first.handle)
        let runningStopped = await registry.stop(second.handle)
        try c.expect(!exitedStopped, "Exited stop refused")
        try c.expect(runningStopped, "Running stop accepted")
        try c.equal(runtime.process(1).terminationCount, 1, "Stop sends graceful termination")
        try await eventually("Stop escalation sleep installed") { await clock.count(3_000_000_000) > 0 }
        await clock.advance(3_000_000_000)
        try await eventually("Stop escalated through fake process") { runtime.process(1).killCount == 1 }
        runtime.process(1).finish(15)
        try await eventually("Stopped exit delivered") { await registry.info(second.handle)?.exitCode == 15 }
        try c.equal(await registry.info(second.handle)?.endedReason, "stoppedByUser", "User stop reason retained")
        try c.equal(await registry.drainPending(sessionID: session).count, 0, "Other session result isolated")
        try c.equal(await registry.drainPending(sessionID: other).count, 1, "Other session drain available")
        runtime.advance(3_601)
        await registry.pruneExited()
        let prunedInfo = await registry.info(first.handle)
        try c.expect(prunedInfo == nil, "Old exited entries pruned")
        let foreground = Task { try await registry.runForeground(sessionID: session, command: "foreground", argv: ["fake"], cwd: "/unused") }
        try await eventually("Foreground fake inserted") { runtime.count == 3 && runtime.process(2).ready }
        runtime.buffer(2).append(Data("done".utf8))
        runtime.process(2).finish(0)
        let outcome = try await foreground.value
        if case .exited(let code, let output) = outcome {
            try c.equal(code, 0, "Foreground exit code")
            try c.equal(output, "done", "Foreground exit output")
        } else { try c.expect(false, "Foreground should exit without promotion") }
        try c.equal(await registry.listBackground(sessionID: session).count, 0, "Foreground never listed as background")
        try c.equal(await registry.drainPending(sessionID: session).count, 0, "Consumed foreground not pending")
        let promoted = Task { try await registry.runForeground(sessionID: session, command: "promoted", argv: ["fake"], cwd: "/unused") }
        try await eventually("Promotable command inserted") { runtime.count == 4 }
        try await eventually("Watchdog sleep registered") { await clock.count(1_000_000_000) >= 2 }
        runtime.advance(301)
        await clock.advance(1_000_000_000)
        let promotion = try await promoted.value
        guard case .promoted(let handle, let partial) = promotion else {
            throw CoverageContext.Failure(description: "Wall clock must promote foreground")
        }
        try c.equal(partial, "", "Promotion partial output")
        try c.equal(await registry.listBackground(sessionID: session).map(\.handle), [handle], "Promoted foreground listed")
        runtime.process(3).finish(2)
        try await eventually("Promoted exit delivered") { await registry.info(handle)?.exitCode == 2 }
        try c.equal(await registry.drainPending(sessionID: session).count, 1, "Promoted result queued")
        let overflow = try await registry.runBackground(sessionID: nil, command: "overflow", argv: ["fake"], cwd: "/unused")
        runtime.buffer(4).append(Data(repeating: 65, count: 129))
        try await eventually("Overflow monitor installed") { await clock.count(500_000_000) >= 5 }
        await clock.advance(500_000_000)
        try await eventually("Overflow force-kills fake") { runtime.process(4).killCount == 1 }
        runtime.process(4).finish(9)
        try await eventually("Overflow exit delivered") { await registry.info(overflow.handle)?.exitCode == 9 }
        try c.equal(await registry.info(overflow.handle)?.endedReason, "outputOverflow", "Overflow reason retained")
        try c.equal(await registry.drainPending(sessionID: nil).count, 1, "Nil-session pending isolated")
        let cancelled = Task { try await registry.runForeground(sessionID: session, command: "cancelled", argv: ["fake"], cwd: "/unused") }
        try await eventually("Cancelable foreground inserted") { runtime.count == 6 && runtime.process(5).ready }
        runtime.buffer(5).append(Data("partial".utf8))
        cancelled.cancel()
        guard case .promoted(let cancelledHandle, let cancelledOutput) = try await cancelled.value else {
            throw CoverageContext.Failure(description: "Cancellation must promote, not kill")
        }
        try c.equal(cancelledOutput, "partial", "Cancellation retains partial output")
        try c.equal(runtime.process(5).terminationCount, 0, "Cancellation does not terminate process")
        runtime.process(5).finish(0)
        try await eventually("Cancelled command eventually exits") { await registry.info(cancelledHandle)?.exitCode == 0 }
        try c.equal(await registry.drainPending(sessionID: session).count, 1, "Cancellation promotion queues eventual exit")
        let swept = Task { try await registry.runForeground(sessionID: session, command: "sweep", argv: ["fake"], cwd: "/unused") }
        try await eventually("Sweep foreground inserted") { runtime.count == 7 }
        await registry.sweep()
        if case .exited(let code, _) = try await swept.value {
            try c.equal(code, -1, "Sweep resumes foreground with sentinel exit")
        } else { try c.expect(false, "Sweep must resume foreground") }
        try c.equal(runtime.process(6).terminationCount, 1, "Sweep gracefully terminates fake")
        try c.equal(runtime.process(6).killCount, 1, "Sweep force-kills fake")
        try c.equal(await registry.listBackground(sessionID: session).count, 0, "Sweep clears registry")
        try c.equal(await registry.drainPending(sessionID: session).count, 0, "Sweep clears pending")
        await clock.finish()
    }

    private static func registryInactivity(_ c: CoverageContext) async throws {
        let runtime = CommandRuntimeDouble()
        let clock = CommandSleepDouble()
        let registry = BackgroundCommandRegistry(inactivity: 120, wallClock: 300, spawn: { try runtime.spawn($0, $1) }, now: { runtime.now() }, sleep: { await clock.sleep($0) })
        let foreground = Task { try await registry.runForeground(sessionID: nil, command: "idle", argv: ["fake"], cwd: c.root.path) }
        try await eventually("Idle command inserted") { runtime.count == 1 && runtime.process(0).ready }
        try await eventually("Idle watchdog installed") { await clock.count(1_000_000_000) >= 1 }
        runtime.advance(120)
        await clock.advance(1_000_000_000)
        try await eventually("Watchdog remains active at exact inactivity boundary") { await clock.count(1_000_000_000) >= 2 }
        try c.equal(await registry.listBackground(sessionID: nil).count, 0, "Exact inactivity threshold does not promote")
        runtime.advance(1)
        await clock.advance(1_000_000_000)
        guard case .promoted(let handle, _) = try await foreground.value else {
            throw CoverageContext.Failure(description: "Inactivity must promote below wall-clock limit")
        }
        try c.equal(runtime.process(0).killCount, 0, "Inactivity never kills")
        await registry.pruneExited(olderThan: 0)
        try c.equal(await registry.info(handle)?.running, true, "Prune retains running promoted process")
        runtime.process(0).finish(0)
        try await eventually("Idle exit delivered") { await registry.info(handle)?.exitCode == 0 }
        await registry.pruneExited(olderThan: 0)
        try c.equal(await registry.info(handle)?.exitCode, 0, "Exact retention cutoff retains exited process")
        let stopped = try await registry.runBackground(sessionID: nil, command: "quick stop", argv: ["fake"], cwd: c.root.path)
        let accepted = await registry.stop(stopped.handle)
        try c.expect(accepted, "Quick stop accepted")
        try await eventually("Quick stop grace period installed") { await clock.count(3_000_000_000) >= 1 }
        runtime.process(1).finish(0)
        try await eventually("Quick stop exits before escalation") { await registry.info(stopped.handle)?.exitCode == 0 }
        await clock.advance(3_000_000_000)
        await registry.pruneExited(olderThan: 0)
        try c.equal(runtime.process(1).killCount, 0, "Exited process is not force-killed after grace period")
        await registry.sweep()
        await clock.finish()
    }

    private static func registryImmediateExitAndHealthyOutput(_ c: CoverageContext) async throws {
        let instantRuntime = CommandRuntimeDouble(immediateExit: 23)
        let instantClock = CommandSleepDouble()
        let instantRegistry = BackgroundCommandRegistry(spawn: { try instantRuntime.spawn($0, $1) }, now: { instantRuntime.now() }, sleep: { await instantClock.sleep($0) })
        let immediate = try await instantRegistry.runForeground(sessionID: nil, command: "already exited", argv: ["fake"], cwd: c.root.path)
        if case .exited(let code, let output) = immediate {
            try c.equal(code, 23, "Exit during termination-handler installation is not lost")
            try c.equal(output, "", "Immediate exit without output returns empty capture")
        } else {
            try c.expect(false, "Immediate exit must not promote")
        }
        try c.equal(await instantRegistry.drainPending(sessionID: nil).count, 0, "Immediate foreground exit is consumed, not queued")
        await instantRegistry.sweep()
        await instantClock.finish()

        let runtime = CommandRuntimeDouble()
        let clock = CommandSleepDouble()
        let registry = BackgroundCommandRegistry(spawn: { try runtime.spawn($0, $1) }, now: { runtime.now() }, sleep: { await clock.sleep($0) })
        let handle = try await registry.runBackground(sessionID: nil, command: "healthy producer", argv: ["fake"], cwd: c.root.path)
        runtime.buffer(0).append(Data("healthy".utf8))
        try await eventually("Healthy producer monitor installed") { await clock.count(500_000_000) >= 1 }
        await clock.advance(500_000_000)
        try await eventually("Healthy producer monitor schedules next check") { await clock.count(500_000_000) >= 2 }
        try c.equal(await registry.info(handle.handle)?.running, true, "Below-ceiling producer stays running across monitor ticks")
        try c.equal(runtime.process(0).killCount, 0, "Healthy output does not force-kill")
        try c.equal(await registry.output(handle.handle), "healthy", "Healthy monitoring preserves captured output")
        await registry.sweep()
        await clock.finish()
    }
}
