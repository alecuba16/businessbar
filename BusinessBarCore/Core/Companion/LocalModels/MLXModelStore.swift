import Darwin
import Foundation

// MARK: - MLXModelStore

/// Downloads and deletes model weights. Every network fetch goes through
/// here and only ever runs from an explicit button press in preferences.
@MainActor
public final class MLXModelStore: ObservableObject {
    public struct DownloadState: Equatable {
        public let modelID: String
        /// Bytes observed in the HF cache so far.
        public var bytesDone: Int64
        /// Catalog size estimate; progress is approximate by design.
        public var totalBytes: Int64
        public var isFinished: Bool
        public var failureReason: String?

        public var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(bytesDone) / Double(totalBytes))
        }
    }

    @Published public private(set) var download: DownloadState?

    /// Shared instance; one download at a time.
    public static let shared = MLXModelStore()

    /// Test seam: overrides the uv path startDownload spawns (defaults to
    /// locateUV()). Harnesses point this at a fake downloader.
    public static var uvPathOverride: String?

    private var process: Process?
    private var progressTask: Task<Void, Never>?

    private init() {}

    /// Starts an explicit download of the model. Throws when uv is
    /// missing or another download is in flight.
    public func startDownload(modelID: String) throws {
        guard download == nil else {
            throw StoreError.downloadAlreadyRunning
        }
        guard let uv = Self.uvPathOverride ?? MLXEnvironment.locateUV() else {
            throw MLXEnvironment.EnvironmentError.uvNotFound
        }
        guard let entry = MLXModelCatalog.entry(id: modelID) else {
            throw StoreError.unknownModel(modelID)
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: uv)
        child.arguments = [
            "tool", "run", "--from", "mlx-lm", "python", "-c",
            "from huggingface_hub import snapshot_download; "
                + "snapshot_download('\(modelID)')",
        ]
        child.environment = ProcessInfo.processInfo.environment
        child.standardOutput = Pipe()
        child.standardError = Pipe()
        MLXModelStore.registerForQuitKill(child)

        do {
            try child.run()
        } catch {
            throw StoreError.spawnFailed(error.localizedDescription)
        }
        process = child
        download = DownloadState(
            modelID: modelID,
            bytesDone: 0,
            totalBytes: entry.sizeBytes,
            isFinished: false,
            failureReason: nil
        )

        let pid = child.processIdentifier
        progressTask = Task { [weak self] in
            var lastBytes: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard let state = self.download, !state.isFinished else { return }

                if !self.isProcessAlive(pid: pid) {
                    let finished = MLXModelCatalog.isDownloaded(modelID: modelID)
                    var newState = state
                    newState.bytesDone = MLXModelCatalog.downloadedBytes(modelID: modelID)
                    if finished {
                        newState.isFinished = true
                        self.download = newState
                        self.finish()
                        return
                    }
                    newState.isFinished = true
                    newState.failureReason = "download interrupted"
                    self.download = newState
                    self.finish()
                    return
                }

                let bytes = MLXModelCatalog.downloadedBytes(modelID: modelID)
                if bytes != lastBytes {
                    lastBytes = bytes
                    var newState = state
                    newState.bytesDone = bytes
                    self.download = newState
                }
            }
        }
    }

    /// Cancels the active download. The partial cache stays; HF resumes
    /// from existing files on the next explicit download.
    public func cancelDownload() {
        progressTask?.cancel()
        progressTask = nil
        if let child = process, child.isRunning {
            child.terminate()
        }
        process = nil
        if download != nil {
            download = nil
        }
    }

    /// Removes the model from the HF cache. Returns the bytes freed.
    @discardableResult
    public func delete(modelID: String) throws -> Int64 {
        if let state = download, state.modelID == modelID, !state.isFinished {
            throw StoreError.downloadInFlight
        }
        let dir = MLXModelCatalog.cacheDirectory(modelID: modelID)
        let bytes = MLXModelCatalog.downloadedBytes(modelID: modelID)
        guard bytes > 0 else {
            throw StoreError.nothingDownloaded(modelID)
        }
        try FileManager.default.removeItem(at: dir)
        return bytes
    }

    private func isProcessAlive(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func finish() {
        progressTask?.cancel()
        progressTask = nil
        process = nil
        // Keep the finished state visible until the UI clears it.
    }

    // MARK: - Quit-kill table

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

    public enum StoreError: Error, Sendable, Equatable, LocalizedError {
        case downloadAlreadyRunning
        case unknownModel(String)
        case spawnFailed(String)
        case downloadInFlight
        case nothingDownloaded(String)

        public var errorDescription: String? {
            switch self {
            case .downloadAlreadyRunning:
                return "Another download is already running."
            case .unknownModel(let id):
                return "Unknown model \(id)."
            case .spawnFailed(let reason):
                return "Could not start the download: \(reason)"
            case .downloadInFlight:
                return "This model is downloading. Cancel it first."
            case .nothingDownloaded(let id):
                return "Nothing downloaded for \(id)."
            }
        }
    }
}
