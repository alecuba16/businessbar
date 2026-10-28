import Darwin
import Foundation
import os.log

// MARK: - MLXServerManager

/// Owns the mlx-lm server child process on 127.0.0.1. The server is the
/// resolved venv python run with `-m mlx_lm.server`, a single child so one
/// SIGTERM fully unloads the model, KV cache, and MLX buffer pool.
///
/// Models download only through the explicit flow in MLXModelStore. This
/// manager always spawns with HF_HUB_OFFLINE=1: a missing model fails fast
/// instead of silently pulling weights from the network.
@MainActor
public final class MLXServerManager: ObservableObject {
    public enum State: Equatable {
        case stopped
        case starting
        case running(modelID: String)
        case stopping
        case failed(reason: String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        public var label: String {
            switch self {
            case .stopped:
                return "Stopped"
            case .starting:
                return "Starting (loading model)..."
            case .running(let modelID):
                let name = MLXModelCatalog.entry(id: modelID)?.displayName ?? modelID
                return "Running · \(name)"
            case .stopping:
                return "Stopping..."
            case .failed(let reason):
                return "Failed: \(reason)"
            }
        }
    }

    /// Shared instance. The app owns exactly one server.
    public static let shared = MLXServerManager()

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var residentBytes: Int64 = 0

    /// Notification posted when the state changes, so windows that do not
    /// observe the object directly can refresh.
    public static let stateDidChangeNotification =
        Notification.Name("com.businessbar.companion.mlxServerStateDidChange")

    private var process: Process?
    private var healthPollTask: Task<Void, Never>?
    private var rssPollTask: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var lastRequestAt = Date()
    private var startContinuations: [CheckedContinuation<Void, Error>] = []
    private static let log = Logger(subsystem: "com.businessbar.app", category: "MLXServer")

    private init() {
        installResourceGuards()
    }

    deinit {
        healthPollTask?.cancel()
        rssPollTask?.cancel()
        idleTimer?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the server for the given model. Refuses when the model is not
    /// downloaded, uv is missing, or the port is taken.
    public func start(modelID: String) async throws {
        guard !state.isRunning, state != .starting else { return }

        guard let entry = MLXModelCatalog.entry(id: modelID) else {
            throw ServerError.modelNotDownloaded(modelID)
        }
        guard MLXModelCatalog.isDownloaded(modelID: modelID) else {
            throw ServerError.modelNotDownloaded(modelID)
        }
        let port = MLXServerConfig.port()
        guard MLXEnvironment.portIsAvailable(port) else {
            throw ServerError.portInUse(port)
        }

        state = .starting
        refreshPeers()

        do {
            let python = try await Task.detached(priority: .userInitiated) {
                try MLXEnvironment.resolveServerPython(for: entry.kind)
            }.value

            let serverModule = entry.kind == .textAndImages
                ? "mlx_vlm.server"
                : "mlx_lm.server"
            let child = Process()
            child.executableURL = URL(fileURLWithPath: python)
            child.arguments = [
                "-m", serverModule,
                "--model", modelID,
                "--host", "127.0.0.1",
                "--port", String(port),
                "--log-level", "INFO",
            ]
            var env = ProcessInfo.processInfo.environment
            // Hard rule: the server never downloads weights on its own.
            // A missing model must fail, not fetch.
            env["HF_HUB_OFFLINE"] = "1"
            child.environment = env
            child.standardOutput = Pipe()
            child.standardError = Pipe()
            MLXServerManager.registerForQuitKill(child)
            child.terminationHandler = { [weak self] process in
                let exitCode = process.terminationStatus
                Task { @MainActor in
                    self?.childExited(exitCode: exitCode)
                }
            }

            try child.run()
            process = child
            Self.log.info("mlx server spawned for \(modelID, privacy: .public)")
            try await waitForHealth(port: port, modelID: modelID)
            state = .running(modelID: modelID)
            lastRequestAt = Date()
            startPolling(port: port, pid: child.processIdentifier)
            scheduleIdleTimer()
            resolveStartContinuations()
            refreshPeers()
        } catch {
            killChild()
            state = .failed(reason: error.localizedDescription)
            resolveStartContinuations(with: error)
            refreshPeers()
            throw error
        }
    }

    /// Stops the server. Killing the process is the only complete unload:
    /// weights, KV cache, and wired pages all release at once.
    public func stop() {
        guard state.isRunning || state == .starting || state == .stopping else { return }
        cancelPolling()
        killChild()
        state = .stopped
        residentBytes = 0
        refreshPeers()
        Self.log.info("mlx server stopped")
    }

    /// Ensures the server is running for the given model, starting or
    /// restarting it as needed. What chat requests call before streaming.
    public func ensureRunning(modelID: String) async throws {
        markActivity()
        switch state {
        case .running(let current):
            if current == modelID { return }
            // Model switch: restart the child with the new weights.
            stop()
            try await start(modelID: modelID)
        case .starting:
            try await pendingStart()
            // The observed start may have loaded a different model or
            // failed; decide again against the new state.
            try await ensureRunning(modelID: modelID)
        default:
            try await start(modelID: modelID)
        }
    }

    /// Resets the idle countdown. Called on every request the app sends.
    public func markActivity() {
        lastRequestAt = Date()
    }

    // MARK: - Health wait

    private func waitForHealth(port: Int, modelID: String) async throws {
        let deadline = Date().addingTimeInterval(90)
        let url = URL(string: "http://127.0.0.1:\(port)/health")!

        while Date() < deadline {
            guard process?.isRunning == true else {
                throw ServerError.exitedDuringStart(modelID: modelID)
            }
            do {
                let (_, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return
                }
            } catch {
                // Not up yet; keep polling.
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ServerError.startTimedOut(modelID: modelID)
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    // MARK: - Polling

    private func startPolling(port: Int, pid: pid_t) {
        healthPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.state.isRunning else { return }
                guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
                do {
                    let (_, response) = try await self.session.data(from: url)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        Self.log.warning("mlx health check returned \(http.statusCode)")
                    }
                } catch {
                    // The terminationHandler owns the dead-child path; a
                    // transient poll failure is not a state change.
                }
            }
        }

        rssPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.state.isRunning else { return }
                self.residentBytes = MLXServerManager.rssBytes(pid: pid)
            }
        }
    }

    private func cancelPolling() {
        healthPollTask?.cancel()
        healthPollTask = nil
        rssPollTask?.cancel()
        rssPollTask = nil
        idleTimer?.cancel()
        idleTimer = nil
    }

    // MARK: - Idle auto-stop

    private func scheduleIdleTimer() {
        idleTimer?.cancel()
        guard !MLXServerConfig.keepLoaded() else { return }
        let minutes = MLXServerConfig.idleMinutes()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard let self, self.state.isRunning, !Task.isCancelled else { return }
            // The timer sleeps from the moment activity was stamped, so the
            // window has fully elapsed by wake; a small tolerance covers the
            // sleep starting a beat after the stamp.
            guard Date().timeIntervalSince(self.lastRequestAt) >= TimeInterval(minutes * 60 - 1) else {
                self.scheduleIdleTimer()
                return
            }
            Self.log.info("mlx server idle for \(minutes) min, stopping")
            self.stop()
        }
    }

    // MARK: - Crash and quit paths

    private func childExited(exitCode: Int32) {
        guard state.isRunning || state == .starting else { return }
        cancelPolling()
        process = nil
        residentBytes = 0
        if case .starting = state {
            // The health-wait loop observes the dead child and throws; this
            // path only marks the visible state.
            return
        }
        state = .failed(reason: "server exited (code \(exitCode))")
        refreshPeers()
        Self.log.error("mlx server died unexpectedly, exit \(exitCode)")
    }

    private func killChild() {
        if let child = process {
            if child.isRunning {
                child.terminate()
                // Grace, then hard kill; both sync so stop() is deterministic.
                let deadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < deadline {
                    usleep(100_000)
                }
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                }
            }
            child.terminationHandler = nil
            process = nil
        }
    }

    // Quit-time kill table: applicationWillTerminate runs too late for async
    // work, so children are killed synchronously from there.
    private static let quitLock = NSLock()
    private static var quitKillTable: [Process] = []

    private static func registerForQuitKill(_ process: Process) {
        quitLock.lock()
        quitKillTable.removeAll { !$0.isRunning }
        quitKillTable.append(process)
        quitLock.unlock()
    }

    /// Synchronous kill for applicationWillTerminate.
    public static func killAtQuit() {
        quitLock.lock()
        let processes = quitKillTable
        quitKillTable.removeAll()
        quitLock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Start continuations

    /// Waits for the start currently in flight and surfaces its outcome.
    private func pendingStart() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    private func resolveStartContinuations(with error: Error? = nil) {
        let pending = startContinuations
        startContinuations.removeAll()
        for continuation in pending {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    // MARK: - Resource guards

    private func installResourceGuards() {
        // Critical memory pressure or serious thermal load stops the idle
        // server early. Wired model pages are exactly what the machine
        // needs back under pressure.
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.critical],
            queue: .main
        )
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self, self.state.isRunning else { return }
            guard Date().timeIntervalSince(self.lastRequestAt) > 10 else { return }
            Self.log.warning("memory pressure critical, stopping idle mlx server")
            self.stop()
        }
        memoryPressureSource?.resume()

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.state.isRunning else { return }
            guard ProcessInfo.processInfo.thermalState == .serious,
                  Date().timeIntervalSince(self.lastRequestAt) > 10 else { return }
            Self.log.warning("thermal state serious, stopping idle mlx server")
            self.stop()
        }
    }

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?

    // MARK: - Helpers

    private func refreshPeers() {
        NotificationCenter.default.post(
            name: MLXServerManager.stateDidChangeNotification,
            object: nil
        )
    }

    /// Resident size of the child, KB precision via ps. Cheap enough to
    /// poll every few seconds and matches Activity Monitor.
    static func rssBytes(pid: pid_t) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return 0 }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            guard let kb = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return 0
            }
            return kb * 1024
        } catch {
            return 0
        }
    }

    public enum ServerError: Error, Sendable, Equatable, LocalizedError {
        case modelNotDownloaded(String)
        case portInUse(Int)
        case startTimedOut(modelID: String)
        case exitedDuringStart(modelID: String)

        public var errorDescription: String? {
            switch self {
            case .modelNotDownloaded(let id):
                let name = MLXModelCatalog.entry(id: id)?.displayName ?? id
                return "\(name) is not downloaded. Download it from Companion settings first."
            case .portInUse(let port):
                return "Port \(port) is already in use. Pick another port in Companion settings."
            case .startTimedOut(let id):
                let name = MLXModelCatalog.entry(id: id)?.displayName ?? id
                return "\(name) took too long to start and was stopped."
            case .exitedDuringStart(let id):
                let name = MLXModelCatalog.entry(id: id)?.displayName ?? id
                return "The server exited while starting. \(name) may not fit in memory."
            }
        }
    }
}
