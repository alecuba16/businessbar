import Foundation
@testable import BusinessBarCore

private final class MLXCoverageProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var response: (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.badURL) }
    static var customResponse: ((URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.response
            let custom = Self.customResponse
            Self.lock.unlock()
            let response: URLResponse
            let data: Data
            if let custom {
                (response, data) = try custom(request)
            } else {
                let result = try handler(request)
                response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!
                data = result.1
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func serve(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock()
        response = handler
        customResponse = nil
        lock.unlock()
    }

    static func serveResponse(_ handler: @escaping (URLRequest) throws -> (URLResponse, Data)) {
        lock.lock()
        customResponse = handler
        lock.unlock()
    }
}

private final class MLXCoverageRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        paths.append(request.url!.path)
        return paths.count
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }
}

@MainActor
private final class MLXCoverageGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        entered = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func open(error: Error? = nil) {
        let waiting = continuation
        continuation = nil
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
}

@MainActor
private final class MLXCoverageChild {
    var running = false
    var runs = 0
    var terminations = 0
    var forceKills = 0
    var registrations = 0
    var failRun = false
    var ignoreTermination = false
    var statusReads = 0
    var child: Process?

    var driver: MLXProcessDriver {
        MLXProcessDriver(run: { process in
            self.child = process
            if self.failRun { throw URLError(.cannotOpenFile) }
            self.runs += 1
            self.running = true
        }, isRunning: { _ in self.running }, terminate: { _ in
            self.terminations += 1
            if !self.ignoreTermination { self.running = false }
        }, forceKill: { _ in
            self.forceKills += 1
            self.running = false
        }, identifier: { _ in 123_456 }, registerForQuit: { _ in self.registrations += 1 }, terminationStatus: { _ in
            self.statusReads += 1
            return 17
        })
    }
}

@MainActor
private final class MLXCoverageClock {
    var date = Date(timeIntervalSince1970: 1_000)
    var pollingTicks = 0
    var idleTicks = 0
    var advanceHealth = false
    var advanceIdle = false
    var storeTick: (() -> Void)?

    func sleep(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        if nanoseconds == 500_000_000 && advanceHealth {
            date.addTimeInterval(100)
            return
        }
        if nanoseconds == 1_000_000_000, let tick = storeTick {
            storeTick = nil
            tick()
            return
        }
        if nanoseconds == 5_000_000_000 && pollingTicks == 0 {
            pollingTicks += 1
            return
        }
        if nanoseconds >= 60_000_000_000 && advanceIdle && idleTicks == 0 {
            idleTicks += 1
            date.addTimeInterval(Double(nanoseconds) / 1_000_000_000)
            return
        }
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

@MainActor
enum CoreMLXScenarios {
    static func run(_ context: CoverageContext) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MLXCoverageProtocol.self]
        let session = URLSession(configuration: configuration)
        let repoSession = MLXRepoInspector.session
        let directorySession = MLXModelDirectory.session
        MLXRepoInspector.session = session
        MLXModelDirectory.session = session
        defer {
            MLXRepoInspector.session = repoSession
            MLXModelDirectory.session = directorySession
            session.invalidateAndCancel()
            MLXCoverageProtocol.serve { _ in throw URLError(.badURL) }
        }
        try validators(context)
        try environment(context)
        try reasoning(context)
        try catalogAndSnapshots(context)
        try await networking(context)
        try await lifecycle(context, session: session)
        try await measuredNetworkGaps(context)
        try await measuredLifecycleGaps(context, session: session)
        try liveDefaultsAndQuitKill(context)
    }

    /// rssBytes and killAtQuit are the launch-and-quit surface of the
    /// manager the app wires up: /bin/ps answers resident size for a live
    /// pid, and the quit-kill reap is the no-op the app hits when no
    /// server ever spawned. The convenience init that wires the .live
    /// driver stays private to the module, so its coverage belongs to the
    /// app's own launch path, not this harness.
    private static func liveDefaultsAndQuitKill(_ c: CoverageContext) throws {
        // rssBytes against the scenario's own process: /bin/ps answers for
        // a live pid, and 0 for a dead one.
        let own = MLXServerManager.rssBytes(pid: ProcessInfo.processInfo.processIdentifier)
        try c.expect(own >= 0, "rssBytes returns KB-precision bytes for a live pid")
        try c.equal(MLXServerManager.rssBytes(pid: -1), 0, "rssBytes returns zero for a dead pid")

        // Quit-kill with an empty table is the quit-time no-op the app
        // hits when no server ever spawned. The registration path itself
        // only runs from the .live driver on a real spawn, which the
        // harness never performs.
        MLXServerManager.killAtQuit()
        try c.expect(true, "Quit-kill with an empty table is a safe no-op")
    }

    private static func validators(_ c: CoverageContext) throws {
        for value in ["owner/Model-4bit", "mlx-community/Qwen3_0.6B"] {
            try c.expect(MLXRepoInspector.isValidRepoID(value), "valid repository identifier \(value)")
        }
        for value in ["", "owner", " owner/model", "owner/model ", "a/b/c", "/a/b", "a/b/", "a//b", "https://huggingface.co/a/b", "a/b?x", "a/💥"] {
            try c.expect(!MLXRepoInspector.isValidRepoID(value), "reject invalid identifier \(value)")
        }
        for suffix in ["-Instruct-4bit", "-Instruct-8bit", "-MLX-4bit", "-MLX", "-4bit", "-8bit"] {
            try c.equal(MLXRepoInspector.displayName(fromRepoID: "owner/Test-Model" + suffix), "Test Model", "strip known model suffix")
        }
        try c.equal(MLXRepoInspector.estimateRAM(sizeBytes: 100), 150, "RAM includes half-size headroom")
        try c.equal(MLXRepoInspector.estimateRAM(sizeBytes: 0), 0, "zero storage has zero estimate")
        try c.expect(MLXRepoInspector.isMLXFormat(siblings: [["rfilename": "weights.safetensors"]]), "safetensors accepted")
        for name in ["weights.bin", "weights.pt"] {
            try c.expect(!MLXRepoInspector.isMLXFormat(siblings: [["rfilename": "weights.safetensors"], ["rfilename": name]]), "mixed PyTorch format rejected")
        }
        try c.expect(!MLXRepoInspector.isMLXFormat(siblings: [["ignored": 1]]), "missing weights rejected")
        try c.equal(MLXRepoInspector.kind(architecture: "Qwen3VLForConditionalGeneration"), .textAndImages, "vision architecture")
        try c.equal(MLXRepoInspector.kind(architecture: "unknown"), .text, "unknown architecture defaults to text")
        for error in [MLXRepoInspector.ValidationError.badRepoID, .repoNotFound, .notMLXFormat, .noWeightFiles, .requestFailed("offline")] {
            try c.expect(error.errorDescription?.isEmpty == false, "repo errors explain failure")
        }
        for error in [MLXModelStore.StoreError.downloadAlreadyRunning, .unknownModel("x"), .spawnFailed("x"), .downloadInFlight, .nothingDownloaded("x")] {
            try c.expect(error.errorDescription?.isEmpty == false, "store errors explain failure")
        }
        let knownModel = MLXModelCatalog.entries[0]
        for error in [MLXServerManager.ServerError.modelNotDownloaded(knownModel.id), .portInUse(123), .startTimedOut(modelID: knownModel.id), .exitedDuringStart(modelID: knownModel.id)] {
            try c.expect(error.errorDescription?.contains(knownModel.displayName) == true || error.errorDescription?.contains("123") == true, "server error includes resource")
        }
    }

    private static func environment(_ c: CoverageContext) throws {
        let root = try c.temporaryDirectory("mlx-resolver")
        let python = root.appendingPathComponent("python")
        try put("fixture only", at: python)
        let oldPaths = MLXEnvironment.uvSearchPathsOverride
        let oldCache = MLXEnvironment.cachedPythons
        defer {
            MLXEnvironment.uvSearchPathsOverride = oldPaths
            MLXEnvironment.cachedPythons = oldCache
        }
        MLXEnvironment.cachedPythons = [:]
        MLXEnvironment.uvSearchPathsOverride = [root.path, root.appendingPathComponent("missing").path]
        try c.expect(MLXEnvironment.locateUV() == nil, "uv skips directories and missing files")
        MLXEnvironment.uvSearchPathsOverride = [root.path, python.path]
        try c.equal(MLXEnvironment.locateUV(), python.path, "uv finds first regular candidate")
        var output = Data("bootstrap log\n\(python.path)\n".utf8)
        var status: Int32 = 0
        var running = false
        var runs = 0
        var terminated = 0
        var arguments: [String]?
        var instant = Date(timeIntervalSince1970: 2_000)
        let driver = MLXProcessDriver(run: { process in
            runs += 1
            arguments = process.arguments
            let pipe = process.standardOutput as! Pipe
            pipe.fileHandleForWriting.write(output)
            try pipe.fileHandleForWriting.close()
        }, isRunning: { _ in running }, terminate: { _ in
            terminated += 1
            running = false
        },
        forceKill: { _ in running = false }, identifier: { _ in 123_456 },
        registerForQuit: { _ in }, terminationStatus: { _ in status })
        try c.expectThrows("resolver missing uv rejected") {
            _ = try MLXEnvironment.resolveServerPython(driver: driver, uvPath: { nil })
        }
        let resolved = try MLXEnvironment.resolveServerPython(driver: driver, uvPath: { python.path })
        try c.equal(resolved, python.path, "resolver reads final output line")
        try c.equal(arguments?.prefix(4).map { $0 }, ["tool", "run", "--from", "mlx-lm"], "text resolver selects mlx-lm")
        let cached = try MLXEnvironment.resolveServerPython(driver: driver, uvPath: { nil })
        try c.equal(cached, python.path, "cached python bypasses setup")
        try c.equal(runs, 1, "cached resolution never runs child")
        _ = try MLXEnvironment.resolveServerPython(for: .textAndImages, driver: driver, uvPath: { python.path })
        try c.equal(arguments?.prefix(4).map { $0 }, ["tool", "run", "--from", "mlx-vlm"], "vision resolver selects mlx-vlm")
        MLXEnvironment.cachedPythons = [:]
        status = 17
        do {
            _ = try MLXEnvironment.resolveServerPython(driver: driver, uvPath: { python.path })
            try c.expect(false, "failed setup must throw")
        } catch let error as MLXEnvironment.EnvironmentError {
            try c.equal(error, .resolveFailed("mlx-lm setup failed (exit 17)"), "setup exit code preserved")
        }
        status = 0
        output = Data("\(root.appendingPathComponent("missing-python").path)\n".utf8)
        try c.expectThrows("nonexistent resolved path rejected") {
            _ = try MLXEnvironment.resolveServerPython(driver: driver, uvPath: { python.path })
        }
        output = Data([0xff])
        try c.expectThrows("invalid UTF8 resolver output rejected") {
            _ = try MLXEnvironment.resolveServerPython(driver: driver, uvPath: { python.path })
        }
        running = true
        do {
            _ = try MLXEnvironment.resolveServerPython(timeout: 1, driver: driver, uvPath: { python.path },
                now: { instant }, wait: { instant.addTimeInterval($0 + 1) })
            try c.expect(false, "setup deadline must throw")
        } catch let error as MLXEnvironment.EnvironmentError {
            try c.equal(error, .resolveFailed("mlx-lm setup timed out"), "setup timeout surfaced")
        }
        try c.equal(terminated, 1, "timeout terminates only fake resolver child")
    }

    private static func reasoning(_ c: CoverageContext) throws {
        try c.expect(MLXReasoningCapability.none.requestKwargs(reasoningEnabled: true, effort: "high") == nil, "unsupported reasoning sends no kwargs")
        let toggle = MLXReasoningInspector.capability(chatTemplate: "enable_thinking", configJSON: nil, architecture: "unknown")
        try c.equal(toggle.shape, .thinkingToggle, "toggle template detected")
        try c.expect(toggle.requestKwargs(reasoningEnabled: true, effort: "high") == nil, "enabled thinking keeps template default")
        for effort in ["none", "minimal", "off"] {
            try c.equal(toggle.requestKwargs(reasoningEnabled: true, effort: effort)?["enable_thinking"] as? Bool, false, "off effort disables thinking")
        }
        try c.equal(toggle.requestKwargs(reasoningEnabled: false, effort: nil)?["enable_thinking"] as? Bool, false, "toggle disables thinking")
        for marker in ["<think>", "<|thinking|>", "begin_of_think", "begin▁of▁think"] {
            try c.equal(MLXReasoningInspector.capability(chatTemplate: marker, configJSON: nil, architecture: "x"), toggle, "thinking marker detected")
        }
        for key in ["reasoning", "thinking", "enable_thinking"] {
            try c.equal(MLXReasoningInspector.capability(chatTemplate: nil, configJSON: [key: false], architecture: "x"), toggle, "boolean config indicates capability even when default disabled")
        }
        let effort = MLXReasoningInspector.capability(chatTemplate: "enable_thinking reasoning_effort", configJSON: nil, architecture: "x")
        try c.equal(effort.shape, .effortLevels, "effort marker takes precedence")
        try c.equal(effort.effortOptions, ["low", "medium", "high"], "harmony levels")
        for architecture in ["GptOssForCausalLM", "GPTOssForCausalLM"] {
            try c.equal(MLXReasoningInspector.capability(chatTemplate: nil, configJSON: nil, architecture: architecture), effort, "architecture fallback")
        }
        for pick in [nil, "unknown", "high"] as [String?] {
            try c.equal(effort.requestKwargs(reasoningEnabled: true, effort: pick)?["reasoning_effort"] as? String, pick == "high" ? "high" : "medium", "effort fallback")
        }
        try c.equal(effort.requestKwargs(reasoningEnabled: false, effort: "high")?["reasoning_effort"] as? String, "low", "disabled effort clamps low")
        try c.equal(MLXReasoningInspector.capability(chatTemplate: "hello", configJSON: ["thinking": "yes"], architecture: "x"), .none, "nonboolean config is not capability")
        try c.equal(try JSONDecoder().decode(MLXReasoningCapability.self, from: JSONEncoder().encode(effort)), effort, "capability Codable roundtrip")
    }

    private static func snapshot(_ c: CoverageContext, model: String, home: String) throws -> URL {
        let snapshot = MLXModelCatalog.cacheDirectory(modelID: model, home: home).appendingPathComponent("snapshots/revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        return snapshot
    }

    private static func put(_ value: String, at url: URL) throws {
        try Data(value.utf8).write(to: url)
    }

    private static func settle(until condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func catalogAndSnapshots(_ c: CoverageContext) throws {
        let defaults = try c.defaults("mlx-catalog")
        let home = try c.temporaryDirectory("mlx-home").path
        try c.equal(MLXServerConfig.port(defaults: defaults), 8790, "unset port default")
        for port in [0, -1, 65_536] {
            MLXServerConfig.setPort(port, defaults: defaults)
            try c.equal(MLXServerConfig.port(defaults: defaults), 8790, "invalid port replaced")
        }
        for port in [1, 65_535] {
            MLXServerConfig.setPort(port, defaults: defaults)
            try c.equal(MLXServerConfig.port(defaults: defaults), port, "port bounds accepted")
        }
        try c.equal(MLXServerConfig.baseURLString(defaults: defaults), "http://127.0.0.1:65535/v1", "base URL uses configured port")
        try c.equal(MLXServerConfig.idleMinutes(defaults: defaults), 5, "idle default")
        MLXServerConfig.setIdleMinutes(0, defaults: defaults)
        try c.equal(MLXServerConfig.idleMinutes(defaults: defaults), 1, "idle lower bound")
        MLXServerConfig.setKeepLoaded(true, defaults: defaults)
        try c.expect(MLXServerConfig.keepLoaded(defaults: defaults), "keep-loaded preference")
        try c.equal(MLXModelCatalog.fit(ramBytes: 100, installedRAM: 300), .fits, "threefold fit boundary")
        try c.equal(MLXModelCatalog.fit(ramBytes: 100, installedRAM: 299), .mayBeSlow, "below fit boundary")
        try c.equal(MLXModelCatalog.fit(ramBytes: 100, installedRAM: 199), .wontFit, "below slow boundary")
        try c.equal(MLXModelCatalog.Kind.text.label, "Text", "text kind label")
        try c.equal(MLXModelCatalog.Kind.textAndImages.label, "Text + Images", "vision kind label")
        try c.equal(MLXModelCatalog.Fit.fits.label, "Fits", "fits label")
        try c.equal(MLXModelCatalog.Fit.mayBeSlow.label, "May be slow", "slow label")
        try c.equal(MLXModelCatalog.Fit.wontFit.label, "Won't fit", "no fit label")
        let legacy = Data(#"{"id":"owner/legacy","displayName":"Legacy","sizeBytes":12,"ramBytes":18}"#.utf8)
        let entry = try JSONDecoder().decode(MLXModelCatalog.Entry.self, from: legacy)
        try c.equal(entry.kind, .text, "legacy entry defaults to text")
        try c.expect(entry.reasoning == nil, "legacy reasoning remains unknown")
        try c.equal(MLXModelCatalog.addCustomEntry(entry, defaults: defaults), [entry], "custom entry persisted")
        try c.equal(MLXModelCatalog.addCustomEntry(entry, defaults: defaults), [entry], "custom duplicate ignored")
        try c.equal(MLXModelCatalog.entry(id: entry.id, defaults: defaults), entry, "custom lookup")
        try c.expect(MLXModelCatalog.isCurated(id: MLXModelCatalog.entries[0].id), "curated lookup")
        try c.expect(!MLXModelCatalog.isCurated(id: entry.id), "custom not curated")
        let toggle = MLXReasoningInspector.capability(chatTemplate: "enable_thinking", configJSON: nil, architecture: "x")
        MLXModelCatalog.setReasoningCapability(id: entry.id, toggle, defaults: defaults)
        try c.equal(MLXModelCatalog.reasoningCapability(id: entry.id, defaults: defaults, home: home), toggle, "custom reasoning persisted")
        let model = MLXModelCatalog.entries[0].id
        try c.expect(!MLXModelCatalog.isDownloaded(modelID: model, home: home), "absent snapshot not downloaded")
        try c.equal(MLXModelCatalog.downloadedBytes(modelID: model, home: home), 0, "absent size zero")
        try c.equal(MLXReasoningInspector.capabilityFromSnapshot(modelID: model, home: home), .none, "absent snapshot reasoning none")
        let directory = try snapshot(c, model: model, home: home)
        try put("{}", at: directory.appendingPathComponent("config.json"))
        try c.expect(!MLXModelCatalog.isDownloaded(modelID: model, home: home), "partial snapshot not complete")
        try put(#"{"chat_template":"enable_thinking"}"#, at: directory.appendingPathComponent("tokenizer_config.json"))
        try c.expect(MLXModelCatalog.isDownloaded(modelID: model, home: home), "required snapshot files complete")
        try c.equal(MLXModelCatalog.reasoningCapability(id: model, defaults: defaults, home: home), toggle, "snapshot reasoning discovered")
        try put("reasoning_effort", at: directory.appendingPathComponent("chat_template.jinja"))
        try c.equal(MLXModelCatalog.reasoningCapability(id: model, defaults: defaults, home: home), toggle, "discovered capability cached")
        let effort = MLXReasoningInspector.capabilityFromSnapshot(modelID: model, home: home)
        try c.equal(effort.shape, .effortLevels, "standalone jinja wins")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("chat_template.jinja"))
        try put(#"{"chat_template_jinja":"reasoning_effort"}"#, at: directory.appendingPathComponent("chat_template.json"))
        try c.equal(MLXReasoningInspector.capabilityFromSnapshot(modelID: model, home: home), effort, "standalone JSON wins over tokenizer")
        try put("not json", at: directory.appendingPathComponent("chat_template.json"))
        try c.equal(MLXReasoningInspector.capabilityFromSnapshot(modelID: model, home: home), toggle, "malformed standalone falls back to tokenizer")
        let bytes = MLXModelCatalog.downloadedBytes(modelID: model, home: home)
        try put("hidden", at: directory.appendingPathComponent(".hidden"))
        try c.equal(MLXModelCatalog.downloadedBytes(modelID: model, home: home), bytes, "hidden cache metadata excluded")
        MLXServerConfig.setActiveModelID(entry.id, defaults: defaults)
        MLXModelCatalog.removeCustomEntry(id: entry.id, defaults: defaults)
        try c.expect(MLXModelCatalog.customEntries(defaults: defaults).isEmpty, "custom removal persisted")
        try c.expect(MLXServerConfig.activeModelID(defaults: defaults) == nil, "active removed model cleared")
        defaults.set(Data("invalid".utf8), forKey: "companionMLXCustomEntries")
        try c.expect(MLXModelCatalog.customEntries(defaults: defaults).isEmpty, "corrupt custom catalog tolerated")
    }

    private static func networking(_ c: CoverageContext) async throws {
        MLXCoverageProtocol.serve { request in
            let path = request.url!.path
            if path.hasPrefix("/api/models/") {
                return (200, Data(#"{"usedStorage":100,"siblings":[{"rfilename":"model.safetensors"}],"config":{"architectures":["Qwen3VLForConditionalGeneration"]}}"#.utf8))
            }
            if path.hasSuffix("config.json") {
                return (200, Data(#"{"max_position_embeddings":4096,"quantization":{"bits":4,"group_size":64}}"#.utf8))
            }
            return (200, Data("enable_thinking".utf8))
        }
        let report = try await MLXRepoInspector.check(repoID: " owner/Test-Instruct-4bit ")
        try c.equal(report.repoID, "owner/Test-Instruct-4bit", "check trims input")
        try c.equal(report.displayName, "Test", "report display name")
        try c.equal(report.kind, .textAndImages, "report modality")
        try c.equal(report.sizeBytes, 100, "reported disk bytes")
        try c.equal(report.ramBytes, 150, "reported memory estimate")
        try c.equal(report.contextLength, 4096, "config context window")
        try c.equal(report.quantization, "4-bit, group 64", "quantization details")
        try c.equal(report.reasoning.shape, .thinkingToggle, "repo template reasoning")
        try await c.expectThrowsAsync("bad repo rejected before network") { _ = try await MLXRepoInspector.check(repoID: "invalid") }
        for (status, payload, expected) in [
            (404, "{}", MLXRepoInspector.ValidationError.repoNotFound),
            (503, "{}", .requestFailed("HTTP 503")),
            (200, "invalid", .requestFailed("unexpected repo payload")),
            (200, #"{"siblings":[{"rfilename":"model.bin"}]}"#, .notMLXFormat),
        ] {
            MLXCoverageProtocol.serve { _ in (status, Data(payload.utf8)) }
            do {
                _ = try await MLXRepoInspector.check(repoID: "owner/Test")
                try c.expect(false, "repo failure expected")
            } catch let error as MLXRepoInspector.ValidationError {
                try c.equal(error, expected, "typed repo failure")
            }
        }
        MLXCoverageProtocol.serve { _ in throw URLError(.notConnectedToInternet) }
        try await c.expectThrowsAsync("transport failure surfaced") { _ = try await MLXRepoInspector.check(repoID: "owner/Test") }
        MLXCoverageProtocol.serve { request in
            if request.url!.path == "/api/models" {
                return (200, Data(#"[{"id":"owner/text","pipeline_tag":"text-generation","downloads":12},{"id":"owner/vision","pipeline_tag":"image-text-to-text"},{"id":"owner/audio","pipeline_tag":"automatic-speech-recognition"},{"pipeline_tag":"text-generation"}]"#.utf8))
            }
            return request.url!.path.hasSuffix("text") ? (200, Data(#"{"usedStorage":42}"#.utf8)) : (503, Data())
        }
        let items = try await MLXModelDirectory.fetch()
        try c.equal(items.map(\.id), ["owner/text", "owner/vision"], "directory filters nonchat and missing IDs")
        try c.equal(items[0].sizeBytes, 42, "directory resolves size")
        try c.equal(items[0].downloads, 12, "download popularity retained")
        try c.equal(items[1].kind, .textAndImages, "directory vision kind")
        try c.expect(items[1].sizeBytes == nil, "failed detail retains unknown size")
        try c.equal(items[1].downloads, 0, "missing popularity defaults zero")
        for (status, payload) in [(500, "[]"), (200, "invalid"), (200, "[]")] {
            MLXCoverageProtocol.serve { _ in (status, Data(payload.utf8)) }
            try await c.expectThrowsAsync("directory rejects invalid list") { _ = try await MLXModelDirectory.fetch() }
        }
        MLXCoverageProtocol.serve { _ in (200, Data(#"{"usedStorage":0}"#.utf8)) }
        let zeroSize = await MLXModelDirectory.repoSizeBytes(repoID: "owner/Test")
        try c.expect(zeroSize == nil, "zero storage remains unknown")
        try c.equal(MLXModelDirectory.DirectoryError.requestFailed("offline").errorDescription, "Browse failed: offline", "directory error detail")
    }

    private static func lifecycle(_ c: CoverageContext, session: URLSession) async throws {
        let defaults = try c.defaults("mlx-lifecycle")
        let home = try c.temporaryDirectory("mlx-lifecycle").path
        let model = MLXModelCatalog.entries[0].id
        let child = MLXCoverageChild()
        let clock = MLXCoverageClock()
        var portAvailable = true
        let manager = MLXServerManager(defaults: defaults, home: home, driver: child.driver, session: session,
            resolvePython: { _ in "/isolated/python" }, portAvailable: { _ in portAvailable },
            now: { clock.date }, sleep: { try await clock.sleep($0) }, residentSize: { _ in 8192 }, observeResources: { _ in })
        defer { manager.stop() }
        try c.equal(manager.state, .stopped, "new manager stopped")
        try c.equal(manager.state.label, "Stopped", "stopped label")
        try await c.expectThrowsAsync("unknown model never spawns") { try await manager.start(modelID: "missing/model") }
        try await c.expectThrowsAsync("missing snapshot never spawns") { try await manager.start(modelID: model) }
        try c.equal(child.runs, 0, "preflight failures do not run child")
        let directory = try snapshot(c, model: model, home: home)
        try put("{}", at: directory.appendingPathComponent("config.json"))
        try put("{}", at: directory.appendingPathComponent("tokenizer_config.json"))
        portAvailable = false
        do {
            try await manager.start(modelID: model)
            try c.expect(false, "occupied port should fail")
        } catch let error as MLXServerManager.ServerError {
            try c.equal(error, .portInUse(8790), "port collision reported")
        }
        portAvailable = true
        MLXServerConfig.setKeepLoaded(true, defaults: defaults)
        MLXCoverageProtocol.serve { _ in (200, Data()) }
        try await manager.start(modelID: model)
        try c.equal(manager.state, .running(modelID: model), "health response marks manager running")
        try c.expect(manager.state.isRunning, "running state predicate")
        try c.expect(manager.state.label.hasPrefix("Running ·"), "running state label")
        try c.equal(child.child?.arguments, ["-m", "mlx_lm.server", "--model", model, "--host", "127.0.0.1", "--port", "8790", "--log-level", "INFO"], "server invocation")
        try c.equal(child.child?.environment?["HF_HUB_OFFLINE"], "1", "server cannot download models")
        try c.equal(child.child?.executableURL?.path, "/isolated/python", "resolved python used")
        try await manager.ensureRunning(modelID: model)
        try await manager.start(modelID: model)
        try c.equal(child.runs, 1, "same-model requests reuse child")
        try await settle { manager.residentBytes == 8192 }
        try c.equal(manager.residentBytes, 8192, "resident polling uses boundary")
        manager.markActivity()
        manager.stop()
        try c.equal(manager.state, .stopped, "stop state")
        try c.equal(manager.residentBytes, 0, "stop clears resident bytes")
        try c.equal(child.terminations, 1, "only owned fake child terminated")
        manager.stop()
        try c.equal(child.terminations, 1, "stop idempotent")
        try await manager.start(modelID: model)
        child.running = false
        if let process = child.child { process.terminationHandler?(process) }
        try await settle { manager.state == .failed(reason: "server exited (code 17)") }
        try c.equal(manager.state, .failed(reason: "server exited (code 17)"), "unexpected child exit reports status")
        try c.equal(manager.residentBytes, 0, "crash clears resident bytes")
        let visionModel = MLXModelCatalog.entries.first { $0.kind == .textAndImages }!.id
        let visionSnapshot = try snapshot(c, model: visionModel, home: home)
        try put("{}", at: visionSnapshot.appendingPathComponent("config.json"))
        try put("{}", at: visionSnapshot.appendingPathComponent("tokenizer_config.json"))
        try await manager.ensureRunning(modelID: visionModel)
        try c.equal(child.child?.arguments?.prefix(2).map { $0 }, ["-m", "mlx_vlm.server"], "vision selects vlm module")
        let runsBeforeSwitch = child.runs
        try await manager.ensureRunning(modelID: model)
        try c.equal(child.runs, runsBeforeSwitch + 1, "different model restarts child")
        try c.equal(manager.state, .running(modelID: model), "model switch serves requested model")
        manager.stop()
        child.failRun = true
        try await c.expectThrowsAsync("spawn failure surfaced") { try await manager.start(modelID: model) }
        if case .failed = manager.state {} else { try c.expect(false, "spawn failure sets failed state") }
        child.failRun = false
        clock.advanceHealth = true
        MLXCoverageProtocol.serve { _ in (503, Data()) }
        do {
            try await manager.start(modelID: model)
            try c.expect(false, "unhealthy start should time out")
        } catch let error as MLXServerManager.ServerError {
            try c.equal(error, .startTimedOut(modelID: model), "health deadline honored")
        }
        try c.expect(!child.running, "failed health kills fake child")
        clock.advanceHealth = false
        MLXCoverageProtocol.serve { _ in (200, Data()) }
        MLXServerConfig.setKeepLoaded(false, defaults: defaults)
        clock.advanceIdle = true
        try await manager.start(modelID: model)
        try await settle { manager.state == .stopped }
        try c.equal(manager.state, .stopped, "idle deadline unloads child")
        try c.equal(MLXServerManager.State.starting.label, "Starting (loading model)...", "starting label")
        try c.equal(MLXServerManager.State.stopping.label, "Stopping...", "stopping label")
        try c.equal(MLXServerManager.State.failed(reason: "offline").label, "Failed: offline", "failure label")

        let downloader = MLXCoverageChild()
        let downloadClock = MLXCoverageClock()
        var uv: String? = nil
        let store = MLXModelStore(defaults: defaults, home: home, driver: downloader.driver,
            locateUV: { uv }, sleep: { try await downloadClock.sleep($0) })
        defer { store.cancelDownload() }
        try c.expect(store.download == nil, "new store has no download")
        try c.expectThrows("missing uv rejected") { try store.startDownload(modelID: model) }
        uv = "/isolated/uv"
        try c.expectThrows("unknown model rejected") { try store.startDownload(modelID: "missing/model") }
        downloader.failRun = true
        try c.expectThrows("download spawn failure") { try store.startDownload(modelID: model) }
        try c.expect(store.download == nil, "failed spawn leaves no download")
        downloader.failRun = false
        try store.startDownload(modelID: model)
        try c.equal(store.download?.totalBytes, MLXModelCatalog.entries[0].sizeBytes, "download uses catalog size")
        try c.expectThrows("concurrent download rejected") { try store.startDownload(modelID: model) }
        try c.expectThrows("in-flight delete rejected") { try store.delete(modelID: model) }
        store.cancelDownload()
        try c.expect(store.download == nil, "cancel clears state")
        try c.equal(downloader.terminations, 1, "cancel terminates only fake downloader")
        downloadClock.storeTick = { downloader.running = false }
        try store.startDownload(modelID: model)
        try await settle { store.download?.isFinished == true }
        try c.equal(store.download?.isFinished, true, "complete snapshot finishes download")
        try c.expect(store.download?.failureReason == nil, "complete download no failure")
        try c.equal(store.download?.bytesDone, MLXModelCatalog.downloadedBytes(modelID: model, home: home), "completion measures owned cache")
        let measured = MLXModelCatalog.downloadedBytes(modelID: model, home: home)
        let freed = try store.delete(modelID: model)
        try c.equal(freed, measured, "delete returns freed owned-cache bytes")
        try c.expect(!MLXModelCatalog.isDownloaded(modelID: model, home: home), "delete removes snapshot")
        try c.expectThrows("empty deletion rejected") { try store.delete(modelID: model) }
        store.cancelDownload()
        downloadClock.storeTick = { downloader.running = false }
        try store.startDownload(modelID: model)
        try await settle { store.download?.isFinished == true }
        try c.equal(store.download?.failureReason, "download interrupted", "absent snapshot reports interrupted download")
        try c.equal(store.download?.isFinished, true, "interrupted download finishes with failure")
        let unknown = MLXModelStore.DownloadState(modelID: "x", bytesDone: 12, totalBytes: 0, isFinished: false, failureReason: nil)
        try c.equal(unknown.fraction, 0, "unknown size progress zero")
        let over = MLXModelStore.DownloadState(modelID: "x", bytesDone: 12, totalBytes: 10, isFinished: false, failureReason: nil)
        try c.equal(over.fraction, 1, "progress clamps to complete")
    }

    private static func measuredNetworkGaps(_ c: CoverageContext) async throws {
        MLXCoverageProtocol.serveResponse { request in
            (URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: 2, textEncodingName: "utf-8"), Data("{}".utf8))
        }
        do {
            _ = try await MLXRepoInspector.check(repoID: "owner/Fixture")
            try c.expect(false, "non-HTTP metadata response must fail")
        } catch let error as MLXRepoInspector.ValidationError {
            try c.equal(error, .requestFailed("unexpected response"), "non-HTTP response classified")
        }
        for (templateFile, templateJSON, shape) in [
            ("chat_template.json", #"{"chat_template":"reasoning_effort"}"#, MLXReasoningCapability.Shape.effortLevels),
            ("tokenizer_config.json", #"{"chat_template_jinja":"enable_thinking"}"#, .thinkingToggle),
        ] {
            MLXCoverageProtocol.serve { request in
                let path = request.url!.path
                if path.hasPrefix("/api/models/") {
                    return (200, Data(#"{"size":64,"siblings":[{"rfilename":"weights.safetensors"}]}"#.utf8))
                }
                if path.hasSuffix("/" + templateFile) { return (200, Data(templateJSON.utf8)) }
                if path.hasSuffix("/config.json") { return (200, Data(#"{"quantization":{"bits":8}}"#.utf8)) }
                return (404, Data())
            }
            let report = try await MLXRepoInspector.check(repoID: "owner/Fixture")
            try c.equal(report.reasoning.shape, shape, "repository reasoning falls back to \(templateFile)")
            try c.expect(report.reasoning.supported, "fallback template enables reasoning")
            try c.equal(report.sizeBytes, 64, "legacy metadata size used")
            try c.equal(report.architecture, "unknown", "missing architecture remains unknown")
            try c.equal(report.kind, .text, "missing architecture defaults text")
            try c.equal(report.quantization, "8-bit", "quantization without group remains useful")
        }
        MLXCoverageProtocol.serve { request in
            if request.url!.path.hasPrefix("/api/models/") {
                return (200, Data(#"{"siblings":[{"rfilename":"weights.safetensors"}]}"#.utf8))
            }
            return (404, Data())
        }
        let optionalMissing = try await MLXRepoInspector.check(repoID: "owner/Fixture")
        try c.equal(optionalMissing.reasoning, .none, "missing optional templates mean no reasoning")
        try c.expect(optionalMissing.contextLength == nil && optionalMissing.quantization == nil, "missing optional config does not invent metadata")
        try c.equal(optionalMissing.sizeBytes, 0, "missing storage estimate defaults zero")

        MLXCoverageProtocol.serve { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await MLXModelDirectory.fetch()
            try c.expect(false, "directory transport failure must throw")
        } catch let error as MLXModelDirectory.DirectoryError {
            try c.expect(error.errorDescription?.hasPrefix("Browse failed:") == true, "directory wraps transport failure")
        }
        let list: [[String: Any]] = (0..<62).map {
            ["id": "owner/Fixture\($0)", "pipeline_tag": "text-generation", "downloads": 62 - $0]
        }
        let payload = try JSONSerialization.data(withJSONObject: list)
        let requests = MLXCoverageRequests()
        MLXCoverageProtocol.serve { request in
            _ = requests.record(request)
            if request.url!.path == "/api/models" { return (200, payload) }
            return (200, Data(#"{"usedStorage":99}"#.utf8))
        }
        let bounded = try await MLXModelDirectory.fetch()
        try c.equal(bounded.count, 62, "detail cap never drops listed models")
        try c.equal(requests.count, 1 + MLXModelDirectory.detailFetchLimit, "directory performs one list and bounded detail requests")
        try c.expect(bounded.prefix(60).allSatisfy { $0.sizeBytes == 99 }, "bounded targets receive sizes")
        try c.expect(bounded.suffix(2).allSatisfy { $0.sizeBytes == nil }, "models beyond detail cap keep unknown size")
        try c.equal(bounded.map(\.downloads), Array((1...62).reversed()), "directory preserves popularity order")
    }

    private static func measuredLifecycleGaps(_ c: CoverageContext, session: URLSession) async throws {
        let defaults = try c.defaults("mlx-measured")
        MLXServerConfig.setKeepLoaded(true, defaults: defaults)
        let home = try c.temporaryDirectory("mlx-measured").path
        let model = MLXModelCatalog.entries[0].id
        let directory = try snapshot(c, model: model, home: home)
        try put("{}", at: directory.appendingPathComponent("config.json"))
        try put("{}", at: directory.appendingPathComponent("tokenizer_config.json"))
        MLXCoverageProtocol.serve { _ in (200, Data()) }
        for failResolution in [false, true] {
            let child = MLXCoverageChild()
            let clock = MLXCoverageClock()
            let gate = MLXCoverageGate()
            let manager = MLXServerManager(defaults: defaults, home: home, driver: child.driver, session: session,
                resolvePython: { _ in try await gate.wait(); return "/isolated/python" },
                portAvailable: { _ in true }, now: { clock.date }, sleep: { try await clock.sleep($0) },
                residentSize: { _ in 0 }, observeResources: { _ in })
            defer { gate.open(error: CancellationError()); manager.stop() }
            let starting = Task { try await manager.start(modelID: model) }
            try await settle { gate.entered }
            try c.equal(manager.state, .starting, "resolution exposes starting state")
            var waiterEntered = false
            let waiting = Task {
                waiterEntered = true
                try await manager.ensureRunning(modelID: model)
            }
            try await settle { waiterEntered }
            gate.open(error: failResolution ? URLError(.cannotOpenFile) : nil)
            if failResolution {
                do { try await starting.value; try c.expect(false, "resolution failure must reach starter") }
                catch { try c.expect(error is URLError, "starter receives resolution error") }
                do { try await waiting.value; try c.expect(false, "resolution failure must reach waiter") }
                catch { try c.expect(error is URLError, "waiting ensureRunning receives start error") }
                try c.equal(child.runs, 0, "failed resolution never runs child")
            } else {
                try await starting.value
                try await waiting.value
                try c.equal(child.runs, 1, "concurrent ensureRunning shares pending start")
                try c.equal(manager.state, .running(modelID: model), "waiter rechecks successful state")
            }
        }

        for cancellation in [false, true] {
            let child = MLXCoverageChild()
            let clock = MLXCoverageClock()
            let manager = MLXServerManager(defaults: defaults, home: home, driver: child.driver, session: session,
                resolvePython: { _ in "/isolated/python" }, portAvailable: { _ in true }, now: { clock.date },
                sleep: { delay in
                    if delay == 500_000_000 {
                        if cancellation { throw CancellationError() }
                        child.running = false
                        if let process = child.child { process.terminationHandler?(process) }
                        try await settle { child.statusReads > 0 }
                        return
                    }
                    try await clock.sleep(delay)
                }, residentSize: { _ in 0 }, observeResources: { _ in })
            defer { manager.stop() }
            MLXCoverageProtocol.serve { _ in throw URLError(.cannotConnectToHost) }
            do {
                try await manager.start(modelID: model)
                try c.expect(false, "failed startup must throw")
            } catch {
                if cancellation {
                    try c.expect(error is CancellationError, "health sleep cancellation surfaced")
                    try c.equal(child.terminations, 1, "cancelled startup terminates fake child")
                } else {
                    try c.equal(error as? MLXServerManager.ServerError, .exitedDuringStart(modelID: model), "startup child death classified")
                    try c.equal(child.statusReads, 1, "starting exit callback consumed fake status")
                }
            }
            try c.expect(!child.running, "failed startup leaves no fake child running")
        }
        try await measuredPollingAndIdle(c, defaults: defaults, home: home, model: model, session: session)
        try await measuredDownloadProgress(c, defaults: defaults, home: home, model: model, directory: directory)
    }

    private static func measuredPollingAndIdle(_ c: CoverageContext, defaults: UserDefaults, home: String,
                                              model: String, session: URLSession) async throws {
        let child = MLXCoverageChild()
        let clock = MLXCoverageClock()
        let requests = MLXCoverageRequests()
        var pollTicks = 0
        MLXCoverageProtocol.serve { request in
            let ordinal = requests.record(request)
            if ordinal == 1 { return (200, Data()) }
            if ordinal == 2 { return (503, Data()) }
            throw URLError(.networkConnectionLost)
        }
        var advanceStopClock = false
        let manager = MLXServerManager(defaults: defaults, home: home, driver: child.driver, session: session,
            resolvePython: { _ in "/isolated/python" }, portAvailable: { _ in true }, now: {
                if advanceStopClock { clock.date.addTimeInterval(2) }
                return clock.date
            }, sleep: { delay in
                if delay == 2_000_000_000 && pollTicks < 2 { pollTicks += 1; return }
                try await clock.sleep(delay)
            }, residentSize: { _ in 0 }, observeResources: { _ in })
        defer { manager.stop() }
        try await manager.start(modelID: model)
        try await settle { requests.count >= 3 }
        try c.equal(requests.count, 3, "health polling performs HTTP and transport negative controls")
        try c.equal(manager.state, .running(modelID: model), "transient health errors do not mark owned child dead")
        child.ignoreTermination = true
        advanceStopClock = true
        manager.stop()
        try c.equal(child.terminations, 1, "stop first requests graceful fake termination")
        try c.equal(child.forceKills, 1, "stop escalates only fake child after grace deadline")
        try c.expect(!child.running && manager.state == .stopped, "forced fake shutdown fully stops manager")

        let idleChild = MLXCoverageChild()
        let idleClock = MLXCoverageClock()
        var idleWakes = 0
        weak var activeManager: MLXServerManager?
        MLXServerConfig.setKeepLoaded(false, defaults: defaults)
        MLXCoverageProtocol.serve { _ in (200, Data()) }
        let idleManager = MLXServerManager(defaults: defaults, home: home, driver: idleChild.driver, session: session,
            resolvePython: { _ in "/isolated/python" }, portAvailable: { _ in true }, now: { idleClock.date }, sleep: { delay in
                if delay == 300_000_000_000 {
                    idleWakes += 1
                    idleClock.date.addTimeInterval(300)
                    if idleWakes == 1 {
                        activeManager?.markActivity()
                        idleClock.date.addTimeInterval(1)
                    }
                    return
                }
                try await idleClock.sleep(delay)
            }, residentSize: { _ in 0 }, observeResources: { _ in })
        activeManager = idleManager
        defer { idleManager.stop() }
        try await idleManager.start(modelID: model)
        try await settle { idleManager.state == .stopped }
        try c.equal(idleWakes, 2, "recent request reschedules idle timeout once")
        try c.equal(idleChild.terminations, 1, "rescheduled timeout unloads child once inactivity elapses")
    }

    private static func measuredDownloadProgress(_ c: CoverageContext, defaults: UserDefaults, home: String,
                                                 model: String, directory: URL) async throws {
        let child = MLXCoverageChild()
        let gate = MLXCoverageGate()
        var ticks = 0
        try put("partial downloaded bytes", at: directory.appendingPathComponent("weights.safetensors.incomplete"))
        let measuredBytes = MLXModelCatalog.downloadedBytes(modelID: model, home: home)
        let store = MLXModelStore(defaults: defaults, home: home, driver: child.driver,
            locateUV: { "/isolated/uv" }, sleep: { _ in
                ticks += 1
                if ticks == 1 { return }
                try await gate.wait()
            })
        defer { store.cancelDownload(); gate.open(error: CancellationError()) }
        try store.startDownload(modelID: model)
        try await settle { store.download?.bytesDone == measuredBytes && gate.entered }
        try c.equal(store.download?.bytesDone, measuredBytes, "live downloader publishes observed cache growth")
        try c.equal(store.download?.isFinished, false, "live process does not finish from cache files alone")
        try c.expect((store.download?.fraction ?? 0) > 0 && (store.download?.fraction ?? 1) < 1, "live progress is a bounded partial fraction")
        store.cancelDownload()
        gate.open(error: CancellationError())
        try c.expect(store.download == nil, "cancel clears live progress")
        try c.equal(child.terminations, 1, "cancelled progress terminates only fake downloader")
    }
}
