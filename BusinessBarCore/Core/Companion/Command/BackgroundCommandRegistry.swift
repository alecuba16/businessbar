import Darwin
import Foundation

/// App-wide registry of executed commands. Every command the tool layer
/// runs, foreground or background, becomes an entry here first; the
/// terminationHandler is the only reaping path. Sessions filter by their
/// own ID, so handles never leak across conversations.
public actor BackgroundCommandRegistry {
    /// Final result queued for the chat drain: the next request folds
    /// these into the conversation before the model runs.
    public struct CompletedResult: Sendable {
        public let handle: UUID
        public let sessionID: UUID?
        public let command: String
        public let exitCode: Int32
        public let endedReason: String
        public let output: String
    }

    public struct HandleInfo: Sendable {
        public let handle: UUID
        public let command: String
        public let running: Bool
        public let exitCode: Int32?
        public let endedReason: String?
    }

    public enum ForegroundOutcome: Sendable {
        case exited(code: Int32, output: String)
        /// Inactivity or wall-clock expiry: the process keeps running,
        /// now as a background handle.
        case promoted(handle: UUID, partialOutput: String)
    }

    enum EndReason: String, Sendable {
        case normal
        case stoppedByUser
        case outputOverflow
        case killedAtQuit
    }

    enum Origin { case foreground, background }

    final class Entry {
        let handle = UUID()
        let sessionID: UUID?
        let command: String
        let process: Process
        let buffer: OutputRingBuffer
        let origin: Origin
        let startedAt = Date()

        var continuation: CheckedContinuation<ForegroundOutcome, Never>?
        var watchdog: Task<Void, Never>?
        var monitor: Task<Void, Never>?
        var exitCode: Int32?
        var endReason: EndReason?
        var exitedAt: Date?
        var promoted = false

        init(
            sessionID: UUID?,
            command: String,
            process: Process,
            buffer: OutputRingBuffer,
            origin: Origin
        ) {
            self.sessionID = sessionID
            self.command = command
            self.process = process
            self.buffer = buffer
            self.origin = origin
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var pending: [CompletedResult] = []
    private let onExitHook: (@Sendable (CompletedResult) -> Void)?
    private let inactivity: TimeInterval
    private let wallClock: TimeInterval

    public init(
        onExit: (@Sendable (CompletedResult) -> Void)? = nil,
        inactivity: TimeInterval = ShellExecutor.foregroundInactivity,
        wallClock: TimeInterval = ShellExecutor.foregroundWallClock
    ) {
        self.onExitHook = onExit
        self.inactivity = inactivity
        self.wallClock = wallClock
    }

    // MARK: - Foreground

    /// Runs a command and awaits its exit. Inactivity or wall-clock expiry
    /// promotes it to a background handle instead of killing it.
    public func runForeground(
        sessionID: UUID?,
        command: String,
        argv: [String],
        cwd: String
    ) async throws -> ForegroundOutcome {
        let entry = try insert(
            sessionID: sessionID,
            command: command,
            argv: argv,
            cwd: cwd,
            origin: .foreground
        )
        startWatchdog(entry)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // A fast command may have exited between spawn and this
                // point: handleExited found no continuation, so resume
                // from the stored state instead of hanging forever.
                if let code = entry.exitCode {
                    continuation.resume(
                        returning: .exited(code: code, output: entry.buffer.snapshot)
                    )
                } else {
                    entry.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.promoteIfRunning(entry.handle) }
        }
    }

    // MARK: - Background

    /// Spawns a command that runs detached from the request: returns a
    /// handle at once, output accumulates in the ring buffer.
    public func runBackground(
        sessionID: UUID?,
        command: String,
        argv: [String],
        cwd: String
    ) throws -> HandleInfo {
        let entry = try insert(
            sessionID: sessionID,
            command: command,
            argv: argv,
            cwd: cwd,
            origin: .background
        )
        return Self.info(entry)
    }

    // MARK: - Queries

    public func info(_ handle: UUID) -> HandleInfo? {
        guard let entry = entries[handle] else { return nil }
        return Self.info(entry)
    }

    public func listBackground(sessionID: UUID?) -> [HandleInfo] {
        entries.values
            .filter {
                $0.sessionID == sessionID
                    && ($0.origin == .background || $0.promoted)
            }
            .map { Self.info($0) }
    }

    /// Tail of the captured output, or the whole snapshot for an exited
    /// process. Nil means the handle does not exist (dead or restored
    /// from a previous run), which the tool layer reports to the model.
    public func output(_ handle: UUID, lines: Int? = nil) -> String? {
        guard let entry = entries[handle] else { return nil }
        if let lines, entry.exitCode == nil {
            return entry.buffer.lastLines(lines)
        }
        return entry.buffer.snapshot
    }

    // MARK: - Control

    /// User or model stop. SIGTERM first, SIGKILL after a grace period.
    public func stop(_ handle: UUID) -> Bool {
        guard let entry = entries[handle], entry.exitCode == nil else {
            return false
        }
        entry.endReason = .stoppedByUser
        entry.process.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.escalateStop(handle)
        }
        return true
    }

    /// App quit: nothing survives the app, background included.
    public func sweep() {
        for entry in entries.values {
            if entry.exitCode == nil {
                entry.endReason = .killedAtQuit
                entry.process.terminate()
                kill(entry.process.processIdentifier, SIGKILL)
            }
            // Foreground awaits must not outlive the sweep.
            if let continuation = entry.continuation {
                entry.continuation = nil
                continuation.resume(
                    returning: .exited(
                        code: entry.exitCode ?? -1,
                        output: entry.buffer.snapshot
                    )
                )
            }
        }
        entries.removeAll()
        pending.removeAll()
    }

    /// Takes and clears the queue of finished background results. The
    /// chat layer drains this before every new request.
    public func drainPending() -> [CompletedResult] {
        let drained = pending
        pending.removeAll()
        return drained
    }

    // MARK: - Internals

    private func insert(
        sessionID: UUID?,
        command: String,
        argv: [String],
        cwd: String,
        origin: Origin
    ) throws -> Entry {
        let (process, buffer) = try ShellExecutor.spawn(argv: argv, cwd: cwd)
        let entry = Entry(
            sessionID: sessionID,
            command: command,
            process: process,
            buffer: buffer,
            origin: origin
        )
        entries[entry.handle] = entry
        installTerminationHandler(entry)
        startOverflowMonitor(entry)
        return entry
    }

    private func installTerminationHandler(_ entry: Entry) {
        entry.process.terminationHandler = { [weak self] process in
            let handle = entry.handle
            let code = process.terminationStatus
            Task { await self?.handleExited(handle, code: code) }
        }
    }

    private func handleExited(_ handle: UUID, code: Int32) {
        guard let entry = entries[handle], entry.exitCode == nil else { return }
        entry.exitCode = code
        entry.exitedAt = Date()
        if entry.endReason == nil {
            entry.endReason = .normal
        }
        entry.watchdog?.cancel()
        entry.monitor?.cancel()

        if let continuation = entry.continuation {
            // Foreground, not promoted: the awaiting tool call consumes
            // the output directly, no pending result needed.
            entry.continuation = nil
            continuation.resume(
                returning: .exited(code: code, output: entry.buffer.snapshot)
            )
            // Foreground entries are done once consumed; background and
            // promoted ones stay queryable for output until pruned.
            if entry.origin == .foreground && !entry.promoted {
                entries[handle] = nil
            }
            return
        }
        if entry.promoted || entry.origin == .background {
            let result = Self.result(entry, code: code)
            pending.append(result)
            onExitHook?(result)
        }
    }

    /// Drops exited background entries older than the retention window
    /// so long sessions do not accumulate ring buffers. Handles referenced
    /// only by chat history fall out naturally.
    public func pruneExited(olderThan age: TimeInterval = 3_600) {
        let cutoff = Date().addingTimeInterval(-age)
        entries = entries.filter { (_, entry) in
            guard let exitDate = entry.exitedAt else { return true }
            return exitDate >= cutoff
        }
    }

    /// Inactivity or wall-clock expiry, or task cancellation. Only the
    /// first caller wins: the continuation is cleared under actor
    /// isolation, so a late terminationHandler cannot double-resume.
    private func promoteIfRunning(_ handle: UUID) -> Bool {
        guard let entry = entries[handle],
            entry.exitCode == nil,
            let continuation = entry.continuation
        else { return false }
        entry.continuation = nil
        entry.promoted = true
        entry.watchdog?.cancel()
        continuation.resume(
            returning: .promoted(
                handle: handle,
                partialOutput: entry.buffer.snapshot
            )
        )
        return true
    }

    private func startWatchdog(_ entry: Entry) {
        entry.watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let alive = await self.watchdogTick(entry.handle)
                if !alive { return }
            }
        }
    }

    /// Returns false once the entry exited or was promoted (loop stops).
    private func watchdogTick(_ handle: UUID) -> Bool {
        guard let entry = entries[handle], entry.exitCode == nil else {
            return false
        }
        let wall = Date().timeIntervalSince(entry.startedAt)
        if wall > wallClock || entry.buffer.idleInterval > inactivity {
            _ = promoteIfRunning(handle)
            return false
        }
        return true
    }

    private func startOverflowMonitor(_ entry: Entry) {
        entry.monitor = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let alive = await self.overflowTick(entry.handle)
                if !alive { return }
            }
        }
    }

    /// A producer that floods past the kill ceiling gets SIGKILLed so a
    /// runaway `yes` cannot wedge the session.
    private func overflowTick(_ handle: UUID) -> Bool {
        guard let entry = entries[handle], entry.exitCode == nil else {
            return false
        }
        if entry.buffer.exceededKillCeiling {
            entry.endReason = .outputOverflow
            kill(entry.process.processIdentifier, SIGKILL)
            return false
        }
        return true
    }

    private func escalateStop(_ handle: UUID) {
        guard let entry = entries[handle], entry.exitCode == nil else { return }
        kill(entry.process.processIdentifier, SIGKILL)
    }

    private static func info(_ entry: Entry) -> HandleInfo {
        HandleInfo(
            handle: entry.handle,
            command: entry.command,
            running: entry.exitCode == nil,
            exitCode: entry.exitCode,
            endedReason: entry.endReason?.rawValue
        )
    }

    private static func result(_ entry: Entry, code: Int32) -> CompletedResult {
        CompletedResult(
            handle: entry.handle,
            sessionID: entry.sessionID,
            command: entry.command,
            exitCode: code,
            endedReason: entry.endReason?.rawValue ?? EndReason.normal.rawValue,
            output: entry.buffer.snapshot
        )
    }
}