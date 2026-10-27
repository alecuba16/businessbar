import Foundation

// MARK: - Transport protocol

/// Byte transport between the client and an ACP agent, line-delimited JSON-RPC.
/// Abstract so tests can drive the client with an in-memory fake and the
/// decoding logic stays testable without spawning processes.
public protocol ACPTransport: Sendable {
    /// Starts the transport. Called once per connection.
    func start(onMessage: @escaping @Sendable (ACPWireMessage) -> Void, onClose: @escaping @Sendable () -> Void) async throws
    /// Sends one JSON-RPC line to the agent.
    func send(_ line: String) async throws
    /// Stops the transport and releases any underlying resources.
    func stop() async
}

// MARK: - Stdio transport

/// Line-delimited JSON-RPC over a subprocess stdin/stdout.
/// A single reader task consumes stdout; stderr lines feed a ring buffer the
/// owning client exposes for diagnostics.
public final class ACPStdioTransport: ACPTransport, @unchecked Sendable {

    private let configuration: ACPAgentConfiguration
    private let process = Process()
    private let lock = NSLock()
    private var started = false
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var onMessage: (@Sendable (ACPWireMessage) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var stderrLines: [String] = []
    private let stderrCapacity = 50

    /// Ring buffer with the last 50 stderr lines from the agent process.
    public var recentStderr: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines
    }

    /// The pid once started, nil before.
    public var processIdentifier: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return started ? process.processIdentifier : nil
    }

    public init(configuration: ACPAgentConfiguration) {
        self.configuration = configuration
    }

    public func start(
        onMessage: @escaping @Sendable (ACPWireMessage) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        process.executableURL = URL(fileURLWithPath: configuration.command)
        process.arguments = configuration.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in configuration.environment {
            environment[key] = value
        }
        process.environment = environment
        if let workingDirectory = configuration.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let writeHandle = stdinPipe.fileHandleForWriting
        self.onMessage = onMessage
        self.onClose = onClose

        try process.run()

        // Single reader task: responses are dispatched to pending continuations
        // by the caller's router, notifications to the event stream.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let messageHandler = onMessage
        let closeHandler = onClose
        readerTask = Task {
            do {
                for try await line in stdoutHandle.bytes.lines {
                    guard !Task.isCancelled else { return }
                    if let message = ACPJSONRPC.decodeLine(line) {
                        messageHandler(message)
                    }
                }
            } catch {
                // Reader errors surface as connection loss below.
            }
            // Stdout closed: the agent is gone.
            lock.lock()
            let wasRunning = process.isRunning
            lock.unlock()
            if wasRunning {
                process.waitUntilExit()
            }
            closeHandler()
        }

        stderrTask = Task {
            let stderrHandle = stderrPipe.fileHandleForReading
            do {
                for try await line in stderrHandle.bytes.lines {
                    guard !Task.isCancelled else { return }
                    let text = String(line)
                    lock.lock()
                    stderrLines.append(text)
                    if stderrLines.count > stderrCapacity {
                        stderrLines.removeFirst(stderrLines.count - stderrCapacity)
                    }
                    lock.unlock()
                }
            } catch {
                // Stderr is diagnostics only; losing it is not fatal.
            }
        }

        lock.lock()
        self.writeHandle = writeHandle
        lock.unlock()

        process.terminationHandler = { [weak self] _ in
            self?.closeWriteHandle()
            closeHandler()
        }
    }

    private var writeHandle: FileHandle?

    private func closeWriteHandle() {
        lock.lock()
        let handle = writeHandle
        writeHandle = nil
        lock.unlock()
        try? handle?.close()
    }

    public func send(_ line: String) async throws {
        lock.lock()
        let handle = writeHandle
        lock.unlock()
        guard let handle else {
            throw ACPTransportError.notRunning
        }
        guard let data = (line + "\n").data(using: .utf8) else {
            throw ACPJSONRPCError.encodingFailed
        }
        try handle.write(contentsOf: data)
    }

    public func stop() async {
        readerTask?.cancel()
        stderrTask?.cancel()
        readerTask = nil
        stderrTask = nil
        closeWriteHandle()
        lock.lock()
        let isRunning = process.isRunning
        lock.unlock()
        if isRunning {
            process.terminate()
        }
    }

    /// Synchronous termination for application quit: the async `stop()` may
    /// never get scheduled before the host process exits, so this kills the
    /// agent inline. Reader tasks notice the closed pipe on their own.
    public func terminateNow() {
        lock.lock()
        let isRunning = process.isRunning
        lock.unlock()
        if isRunning {
            process.terminate()
        }
        closeWriteHandle()
    }
}

/// Transport-level failure states surfaced to the event stream.
public enum ACPTransportError: Error {
    case notRunning
}