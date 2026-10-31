import Darwin
import Foundation

public struct MLXProcessDriver {
    public var run: (Process) throws -> Void
    public var isRunning: (Process) -> Bool
    public var terminate: (Process) -> Void
    public var forceKill: (Process) -> Void
    public var identifier: (Process) -> pid_t
    public var registerForQuit: (Process) -> Void
    public var terminationStatus: (Process) -> Int32

    public init(
        run: @escaping (Process) throws -> Void,
        isRunning: @escaping (Process) -> Bool,
        terminate: @escaping (Process) -> Void,
        forceKill: @escaping (Process) -> Void,
        identifier: @escaping (Process) -> pid_t,
        registerForQuit: @escaping (Process) -> Void,
        terminationStatus: @escaping (Process) -> Int32
    ) {
        self.run = run
        self.isRunning = isRunning
        self.terminate = terminate
        self.forceKill = forceKill
        self.identifier = identifier
        self.registerForQuit = registerForQuit
        self.terminationStatus = terminationStatus
    }

    static func live(registerForQuit: @escaping (Process) -> Void) -> Self {
        Self(
            run: { try $0.run() },
            isRunning: { $0.isRunning },
            terminate: { $0.terminate() },
            forceKill: { kill($0.processIdentifier, SIGKILL) },
            identifier: { $0.processIdentifier },
            registerForQuit: registerForQuit,
            terminationStatus: { $0.terminationStatus }
        )
    }
}

// MARK: - MLXEnvironment

/// Locates uv/uvx and resolves the python that runs `mlx_lm.server`.
/// The uvx wrapper spawns a process tree whose grandchildren survive the
/// parent's death, so the server is always spawned as the resolved venv
/// python directly: one child, one SIGTERM, no orphans.
public enum MLXEnvironment {
    public enum EnvironmentError: Error, Sendable, Equatable {
        case uvNotFound
        case resolveFailed(String)
        case serverNotAvailable(String)
    }

    /// Candidate uv binary locations in priority order.
    public static let uvSearchPaths = [
        "/opt/homebrew/bin/uv",
        "/usr/local/bin/uv",
        "/opt/homebrew/bin/uvx",
        "/usr/local/bin/uvx",
    ]

    /// Test seam: overrides the candidate list so a harness can point uv
    /// resolution at a fake binary. Nil keeps the production list.
    public static var uvSearchPathsOverride: [String]?

    /// Finds the uv binary, or nil when none is installed.
    public static func locateUV() -> String? {
        for path in uvSearchPathsOverride ?? uvSearchPaths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
               !isDir.boolValue {
                return path
            }
        }
        return nil
    }

    /// Resolves the venv python that `uv tool run --from <package>` uses.
    /// Cached in process memory; the result is a stable path under ~/.cache/uv.
    /// Text models run on mlx-lm; vision models on mlx-vlm.
    public static func resolveServerPython(
        for kind: MLXModelCatalog.Kind = .text,
        timeout: TimeInterval = 120,
        driver: MLXProcessDriver? = nil,
        uvPath: (() -> String?)? = nil,
        now: () -> Date = Date.init,
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> String {
        let driver = driver ?? .live(registerForQuit: { _ in })
        let cacheKey = kind.rawValue
        if let cached = cachedPythons[cacheKey], FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        guard let uv = (uvPath ?? locateUV)() else {
            throw EnvironmentError.uvNotFound
        }
        let package = kind == .textAndImages ? "mlx-vlm" : "mlx-lm"
        let importCheck = kind == .textAndImages
            ? "import sys, mlx_vlm; print(sys.executable)"
            : "import sys, mlx_lm; print(sys.executable)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = [
            "tool", "run", "--from", package, "python", "-c",
            importCheck,
        ]
        // The resolution itself may need to install the package on a fresh
        // machine; that is the one-time bootstrap the requirement line in
        // preferences warns about, not a model download.
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try driver.run(process)
        if #available(macOS 13.0, *) {
            let deadline = now().addingTimeInterval(timeout)
            while driver.isRunning(process) && now() < deadline {
                wait(0.05)
            }
            if driver.isRunning(process) {
                driver.terminate(process)
                throw EnvironmentError.resolveFailed("\(package) setup timed out")
            }
        } else {
            process.waitUntilExit()
        }
        let exitCode = driver.terminationStatus(process)
        guard exitCode == 0 else {
            throw EnvironmentError.resolveFailed(
                "\(package) setup failed (exit \(exitCode))"
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .last.map(String.init),
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path) else {
            throw EnvironmentError.resolveFailed("could not read python path")
        }
        cachedPythons[cacheKey] = path
        return path
    }

    /// Test seam: resolution cache; harnesses can prime or clear it.
    public static var cachedPythons: [String: String] = [:]

    /// True when a quick localhost bind test says the port is free. Ports
    /// get grabbed by unrelated apps (seen with Okta Verify), so this check
    /// runs right before every spawn.
    public static func portIsAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var yes: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                bind(sock, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
