import Foundation

// MARK: - OutputRingBuffer

/// Bounded output capture: first bytes and last bytes, with a hard ceiling
/// on what the producer may write before it is killed. Compiler errors put
/// the useful part at the tail while file headers sit at the head.
public final class OutputRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var total = 0
    private var lastActivity = Date()

    public let headCap: Int
    public let tailCap: Int
    /// Accumulated-output ceiling; producers that pass it get killed so a
    /// `yes` flood cannot wedge the app.
    public let killCeiling: Int

    public init(headCap: Int = 2_048, tailCap: Int = 30_720, killCeiling: Int = 5_242_880) {
        self.headCap = headCap
        self.tailCap = tailCap
        self.killCeiling = killCeiling
    }

    public func append(_ data: Data) {
        lock.lock()
        total += data.count
        lastActivity = Date()
        if head.count < headCap {
            head.append(data.subdata(in: 0..<min(data.count, headCap - head.count)))
        }
        tail.append(data)
        if tail.count > tailCap {
            tail.removeFirst(tail.count - tailCap)
        }
        lock.unlock()
    }

    public var exceededKillCeiling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return total > killCeiling
    }

    /// Seconds since the last output byte arrived.
    public var idleInterval: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    /// Captured text: head, an elision marker when bytes were dropped, tail.
    public var snapshot: String {
        lock.lock()
        defer { lock.unlock() }
        if total <= headCap {
            return String(decoding: head, as: UTF8.self)
        }
        if total <= headCap + tailCap {
            // Full output retained: head covers the first headCap bytes,
            // the tail's last (total - headCap) bytes cover the rest,
            // so the two never overlap.
            let headText = String(decoding: head, as: UTF8.self)
            let tailText = String(decoding: tail.suffix(total - headCap), as: UTF8.self)
            return headText + tailText
        }
        let dropped = total - head.count - tail.count
        let headText = String(decoding: head, as: UTF8.self)
        let tailText = String(decoding: tail, as: UTF8.self)
        return headText
            + "\n[… \(dropped) bytes dropped …]\n"
            + tailText
    }

    /// Last n lines of the tail, for read_background_output.
    public func lastLines(_ n: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        var text = String(decoding: tail, as: UTF8.self)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline {
            text.removeLast()
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > n else {
            return text + (endsWithNewline ? "\n" : "")
        }
        let suffix = lines.suffix(n).joined(separator: "\n")
        return suffix + (endsWithNewline ? "\n" : "")
    }
}

// MARK: - ShellExecutor

/// Spawn helpers. Reaping lives in BackgroundCommandRegistry: every
/// command, foreground or background, is an entry there first, so the
/// terminationHandler pattern is the only reaping path in the app.
public enum ShellExecutor: Sendable {
    /// Foreground inactivity window; resets on every output event. On
    /// expiry the command is promoted to background instead of killed.
    public static let foregroundInactivity: TimeInterval = 120
    /// Hard wall-clock cap for foreground commands before promotion.
    public static let foregroundWallClock: TimeInterval = 300

    public enum ExecutionError: Error, Sendable {
        case spawnFailed(String)
        case emptyArgv
    }

    /// Builds the argv for a permission decision. Tier 0 argv runs as-is
    /// with no shell; everything else runs through zsh -c.
    public static func argv(
        for permission: CommandPermission,
        command: String
    ) -> [String] {
        switch permission {
        case .autoApproved(let argv):
            return argv
        case .sessionApproved, .needsConfirmation:
            return ["/bin/zsh", "-c", command]
        }
    }

    /// Spawns a process with both pipes feeding one ring buffer. The
    /// caller owns reaping via the returned process's terminationHandler.
    static func spawn(
        argv: [String],
        cwd: String
    ) throws -> (process: Process, buffer: OutputRingBuffer) {
        guard let executable = argv.first else {
            throw ExecutionError.emptyArgv
        }

        let process = Process()
        // Parser argv keeps bare binary names; Process needs an absolute
        // path, so resolve through PATH at spawn time.
        process.executableURL = URL(
            fileURLWithPath: executable.contains("/")
                ? executable
                : (CommandPermissionParser.resolveBinary(executable) ?? executable)
        )
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = ProcessInfo.processInfo.environment
        // API keys never flow into child processes.
        env.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let buffer = OutputRingBuffer()
        let attach = { (pipe: Pipe) in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                buffer.append(data)
            }
        }
        attach(stdoutPipe)
        attach(stderrPipe)

        do {
            try process.run()
        } catch {
            throw ExecutionError.spawnFailed(error.localizedDescription)
        }

        return (process, buffer)
    }
}
