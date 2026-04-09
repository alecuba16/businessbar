// businessbar/BusinessBar/Utilities/AppLogger.swift

import Foundation
import os.log

// MARK: - LogLevel

/// Log levels ordered by severity. Used to route messages to the appropriate
/// OSLog type and to decide whether they should be persisted to disk.
enum LogLevel: Int, Comparable, CustomStringConvertible, CaseIterable, Identifiable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case fatal = 4

    /// Conformance to `Identifiable` — uses `rawValue` as the stable identity
    /// so `LogLevel` can be used directly in SwiftUI's `ForEach`.
    var id: Int { rawValue }

    var description: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARNING"
        case .error:   return "ERROR"
        case .fatal:   return "FATAL"
        }
    }

    /// User-facing description for the Preferences UI, including a hint
    /// about the verbosity / energy impact of each level.
    var userDescription: String {
        switch self {
        case .debug:   return "Debug (verbose)"
        case .info:    return "Info"
        case .warning: return "Warning"
        case .error:   return "Error"
        case .fatal:   return "Fatal only"
        }
    }

    /// Maps to the corresponding `OSLogType` for Apple's unified logging.
    var osLogType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        case .fatal:   return .fault
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AppLoggerConstants

/// Constants for `AppLogger` extracted to file scope so they are not implicitly
/// `@MainActor`-isolated.  All are `Sendable` immutable values (String,
/// Int, Int64) that are safe to reference from any isolation domain.
private enum AppLoggerConstants {
    static let subsystem = "com.businessbar.app"
    static let logDirectoryName = "BusinessBar"
    static let logFileBaseName = "BusinessBar"
    static let logFileExtension = "log"
    static let maxLogFiles = 5
    static let maxFileSizeBytes: Int64 = 1_048_576

    // UserDefaults keys
    static let loggingEnabledKey = "loggingEnabled"
    static let fileLoggingEnabledKey = "fileLoggingEnabled"
    static let logLevelRawKey = "logLevelRaw"
}

// MARK: - AppLogger

/// A structured logging system that combines Apple's unified logging (`OSLog`)
/// with a rotating file-based log for fatal and error messages.
///
/// - **OSLog**: All levels are sent to Apple's unified logging via `Logger`.
/// - **File log**: Only `error` and `fatal` levels are written to rotating
///   log files in `~/Library/Logs/BusinessBar/`, ensuring critical information
///   survives app crashes.
///
/// The API surface is `@MainActor` for call-site convenience, but all file I/O
/// is dispatched to a serial `DispatchQueue` and never blocks the main thread.
@MainActor
final class AppLogger {

    // MARK: - Singleton

    static let shared = AppLogger()

    // MARK: - UserDefaults Helpers

    /// Returns `true` if logging is enabled according to UserDefaults.
    ///
    /// Uses `object(forKey:)` to distinguish between "not set" (default `true`)
    /// and "explicitly set to false". Thread-safe for reads.
    nonisolated private static func shouldLog(level: LogLevel) -> Bool {
        guard UserDefaults.standard.object(forKey: AppLoggerConstants.loggingEnabledKey) as? Bool ?? true else {
            return false
        }
        let storedRaw = UserDefaults.standard.integer(forKey: AppLoggerConstants.logLevelRawKey)
        let minLevel = LogLevel(rawValue: storedRaw) ?? .warning
        return level.rawValue >= minLevel.rawValue
    }

    /// Returns `true` if file logging is enabled according to UserDefaults.
    ///
    /// Uses `object(forKey:)` to distinguish between "not set" (default `true`)
    /// and "explicitly set to false". Thread-safe for reads.
    nonisolated static func isFileLoggingEnabled() -> Bool {
        UserDefaults.standard.object(forKey: AppLoggerConstants.fileLoggingEnabledKey) as? Bool ?? true
    }

    // MARK: - Properties

    /// Serial queue that serialises all file I/O so writes are thread-safe
    /// and never happen on the main queue.
    private let fileQueue = DispatchQueue(
        label: "com.businessbar.app.logger.file",
        qos: .utility
    )

    /// The directory URL where log files are stored.
    private let logDirectoryURL: URL

    // MARK: - Initialisation

    private init() {
        let logDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppLoggerConstants.logDirectoryName, isDirectory: true)

        self.logDirectoryURL = logDir

        // Ensure the log directory exists before any logging can occur.
        // Using sync so the directory is guaranteed to exist after init.
        fileQueue.sync {
            Self.ensureLogDirectoryExists(at: logDir)
        }
    }

    // MARK: - Public Logging API

    /// Log a debug-level message.
    func debug(_ message: String, category: String) {
        log(message, category: category, level: .debug)
    }

    /// Log an info-level message.
    func info(_ message: String, category: String) {
        log(message, category: category, level: .info)
    }

    /// Log a warning-level message.
    func warning(_ message: String, category: String) {
        log(message, category: category, level: .warning)
    }

    /// Log an error-level message. Error messages are persisted to the
    /// rotating file log so they survive crashes.
    func error(_ message: String, category: String) {
        log(message, category: category, level: .error)
    }

    /// Log a fatal-level message. Fatal messages are persisted to the
    /// rotating file log **synchronously** so the write is guaranteed to
    /// have reached disk before the call returns.
    ///
    /// - Note: This method does *not* crash the app. For unrecoverable
    ///   states where you want to log and then terminate, use
    ///   ``logFatalAndCrash(_:category:file:function:line:)`` instead.
    func fatal(_ message: String, category: String) {
        log(message, category: category, level: .fatal)
    }

    /// Core logging method that routes to both OSLog and (for error/fatal)
    /// the rotating file log.
    func log(_ message: String, category: String, level: LogLevel) {
        guard Self.shouldLog(level: level) else { return }

        logToOSLog(category: category, message: message, level: level)

        // Only persist error and fatal levels to the file log.
        if level >= .error {
            persistToFile(
                message: message,
                category: category,
                level: level,
                context: nil,
                sync: level == .fatal
            )
        }
    }

    /// Log an unexpected `Error` with full source context for debugging.
    ///
    /// This is the convenience method to reach for whenever a `catch` block
    /// encounters an error you didn't anticipate. It captures the file,
    /// function, and line automatically via default parameter values.
    func logUnexpectedError(
        _ error: Error,
        category: String,
        message: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let context = "\(Self.shortFilePath(file)):\(line) \(function)"
        let fullMessage = message ?? "Unexpected error: \(error.localizedDescription)"
        logToOSLog(category: category, message: "\(fullMessage) — \(error)", level: .error)
        persistToFile(
            message: fullMessage,
            category: category,
            level: .error,
            context: context,
            sync: false
        )
    }

    /// Log a fatal error and then intentionally crash the app.
    ///
    /// Use this only for truly unrecoverable states where continuing would
    /// cause data corruption or worse. The fatal message is written to disk
    /// **synchronously** before `fatalError()` is called, guaranteeing the
    /// log entry survives the crash.
    ///
    /// - Returns: `Never` — this method never returns.
    func logFatalAndCrash(
        _ message: String,
        category: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) -> Never {
        let context = "\(Self.shortFilePath(file)):\(line) \(function)"
        logToOSLog(category: category, message: message, level: .fatal)
        persistToFile(
            message: message,
            category: category,
            level: .fatal,
            context: context,
            sync: true
        )
        fatalError(message)
    }

    /// Returns the URLs of existing log files, ordered from newest (index 0)
    /// to oldest.
    func logFileURLs() -> [URL] {
        let directory = logDirectoryURL
        var urls: [URL] = []
        fileQueue.sync {
            for i in 0..<AppLoggerConstants.maxLogFiles {
                let url = Self.logFileURL(index: i, in: directory)
                if FileManager.default.fileExists(atPath: url.path) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    // MARK: - OSLog

    /// Sends a message to Apple's unified logging at the appropriate level.
    /// Delegates to the nonisolated static ``osLog(message:category:level:)``
    /// which creates its own `Logger` internally — no actor hop needed.
    private func logToOSLog(category: String, message: String, level: LogLevel) {
        Self.osLog(message: message, category: category, level: level)
    }

    /// Writes directly to Apple's unified logging without requiring MainActor.
    /// This is the power-efficient path: `Logger` is `Sendable` and `os_log`
    /// is thread-safe, so no actor hop or `Task` allocation is needed.
    nonisolated private static func osLog(message: String, category: String, level: LogLevel) {
        let logger = Logger(subsystem: AppLoggerConstants.subsystem, category: category)
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        case .fatal:
            logger.fault("\(message, privacy: .public)")
        }
    }

    // MARK: - File Persistence (dispatches to fileQueue)

    /// Prepares data on the `@MainActor` and dispatches the actual file I/O
    /// to the serial ``fileQueue``.
    ///
    /// - Parameter sync: When `true`, the write is performed synchronously
    ///   so the caller can be certain data has reached disk (used for fatal
    ///   messages). When `false`, the write is asynchronous.
    private func persistToFile(
        message: String,
        category: String,
        level: LogLevel,
        context: String?,
        sync: Bool
    ) {
        guard Self.isFileLoggingEnabled() else { return }

        let directory = logDirectoryURL
        let work: @Sendable () -> Void = {
            Self.performFileWrite(
                message: message,
                category: category,
                level: level,
                context: context,
                directory: directory
            )
        }
        if sync {
            fileQueue.sync(execute: work)
        } else {
            fileQueue.async(execute: work)
        }
    }

    // MARK: - File Operations (nonisolated, executed on fileQueue)

    /// Ensures the log directory exists, creating it if necessary.
    /// Must be called on the ``fileQueue``.
    nonisolated private static func ensureLogDirectoryExists(at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            fputs(
                "AppLogger: Failed to create log directory at \(url.path): \(error)\n",
                stderr
            )
        }
    }

    /// Returns the URL for a log file at the given rotation index.
    nonisolated private static func logFileURL(index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(AppLoggerConstants.logFileBaseName)_\(index).\(AppLoggerConstants.logFileExtension)"
        )
    }

    /// Formats a single log line for file output.
    ///
    /// Format: `[LEVEL] [timestamp] [category] message\n  → context\n`
    nonisolated private static func formatLogLine(
        level: LogLevel,
        timestamp: String,
        category: String,
        message: String,
        context: String?
    ) -> String {
        var line = "[\(level.description)] [\(timestamp)] [\(category)] \(message)"
        if let ctx = context, !ctx.isEmpty {
            line += "\n  → \(ctx)"
        }
        return line + "\n"
    }

    /// Returns a formatted timestamp string for log file entries.
    nonisolated private static func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// Reduces a full file path to just the file name for compact context lines.
    nonisolated private static func shortFilePath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Performs the actual file write, including rotation if the current file
    /// has exceeded the size limit. Must be called on the ``fileQueue``.
    nonisolated private static func performFileWrite(
        message: String,
        category: String,
        level: LogLevel,
        context: String?,
        directory: URL
    ) {
        let fileManager = FileManager.default
        let currentFileURL = logFileURL(index: 0, in: directory)

        // Rotate if the current file exceeds the size limit.
        if fileManager.fileExists(atPath: currentFileURL.path) {
            let attrs = try? fileManager.attributesOfItem(
                atPath: currentFileURL.path
            )
            let fileSize = (attrs?[.size] as? Int64) ?? 0
            if fileSize >= AppLoggerConstants.maxFileSizeBytes {
                rotateLogFiles(in: directory)
            }
        }

        // Format the log line.
        let timestamp = formattedTimestamp()
        let line = formatLogLine(
            level: level,
            timestamp: timestamp,
            category: category,
            message: message,
            context: context
        )

        // Append to the current file, or create it if it doesn't exist.
        if fileManager.fileExists(atPath: currentFileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: currentFileURL) else {
                fputs(
                    "AppLogger: Failed to open file handle for writing: \(currentFileURL.path)\n",
                    stderr
                )
                return
            }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.synchronize()  // Ensure data is flushed to disk.
            try? handle.close()
        } else {
            guard let data = line.data(using: .utf8) else { return }
            let created = fileManager.createFile(
                atPath: currentFileURL.path,
                contents: data
            )
            if !created {
                fputs(
                    "AppLogger: Failed to create log file: \(currentFileURL.path)\n",
                    stderr
                )
            }
        }
    }

    /// Rotates log files: deletes the oldest, then shifts remaining files
    /// up by one index (e.g. `_3` → `_4`, `_2` → `_3`, …, `_0` → `_1`).
    ///
    /// After rotation, `BusinessBar_0.log` no longer exists and the next
    /// write will create it fresh. Must be called on the ``fileQueue``.
    nonisolated private static func rotateLogFiles(in directory: URL) {
        let fileManager = FileManager.default

        // Delete the oldest file (index maxLogFiles - 1).
        let oldestURL = logFileURL(index: AppLoggerConstants.maxLogFiles - 1, in: directory)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try? fileManager.removeItem(at: oldestURL)
        }

        // Shift files: n-1 → n, n-2 → n-1, …, 1 → 2, 0 → 1
        for i in stride(from: AppLoggerConstants.maxLogFiles - 2, through: 0, by: -1) {
            let sourceURL = logFileURL(index: i, in: directory)
            let destURL = logFileURL(index: i + 1, in: directory)

            if fileManager.fileExists(atPath: sourceURL.path) {
                // Remove destination if it unexpectedly exists.
                if fileManager.fileExists(atPath: destURL.path) {
                    try? fileManager.removeItem(at: destURL)
                }
                try? fileManager.moveItem(at: sourceURL, to: destURL)
            }
        }

        // BusinessBar_0.log is now absent; the next write will create it.
    }
}

// MARK: - Static Convenience Methods

extension AppLogger {

    /// Log a debug message via the shared logger instance.
    ///
    /// **Power-efficient path**: writes directly to OSLog without creating
    /// a `Task` or dispatching to `@MainActor`.  `Logger` is `Sendable`
    /// and `os_log` is thread-safe, so no actor hop is needed.
    /// Debug-level messages are never persisted to the file log.
    nonisolated static func debug(
        _ message: @autoclosure @escaping () -> String,
        category: String
    ) {
        guard shouldLog(level: .debug) else { return }
        osLog(message: message(), category: category, level: .debug)
    }

    /// Log an info message via the shared logger instance.
    ///
    /// **Power-efficient path**: writes directly to OSLog without creating
    /// a `Task` or dispatching to `@MainActor`.  Info-level messages are
    /// never persisted to the file log.
    nonisolated static func info(
        _ message: @autoclosure @escaping () -> String,
        category: String
    ) {
        guard shouldLog(level: .info) else { return }
        osLog(message: message(), category: category, level: .info)
    }

    /// Log a warning message via the shared logger instance.
    ///
    /// **Power-efficient path**: writes directly to OSLog without creating
    /// a `Task` or dispatching to `@MainActor`.  Warning-level messages
    /// are never persisted to the file log.
    nonisolated static func warning(
        _ message: @autoclosure @escaping () -> String,
        category: String
    ) {
        guard shouldLog(level: .warning) else { return }
        osLog(message: message(), category: category, level: .warning)
    }

    /// Log an error message via the shared logger instance.
    ///
    /// Writes to OSLog immediately (power-efficient, no Task).  Then
    /// dispatches to `@MainActor` for file persistence if file logging
    /// is enabled — this is the only path that needs actor isolation.
    nonisolated static func error(
        _ message: @autoclosure @escaping () -> String,
        category: String
    ) {
        guard shouldLog(level: .error) else { return }
        let msg = message()
        osLog(message: msg, category: category, level: .error)
        guard isFileLoggingEnabled() else { return }
        Task { @MainActor in
            shared.persistToFile(message: msg, category: category, level: .error, context: nil, sync: false)
        }
    }

    /// Log a fatal message via the shared logger instance.
    ///
    /// Writes to OSLog immediately (power-efficient, no Task).  Then
    /// dispatches to `@MainActor` for **synchronous** file persistence
    /// if file logging is enabled, guaranteeing the write reaches disk.
    ///
    /// - Note: This method does *not* crash the app. For that, call
    ///   `AppLogger.shared.logFatalAndCrash(…)` directly.
    nonisolated static func fatal(
        _ message: @autoclosure @escaping () -> String,
        category: String
    ) {
        guard shouldLog(level: .fatal) else { return }
        let msg = message()
        osLog(message: msg, category: category, level: .fatal)
        guard isFileLoggingEnabled() else { return }
        Task { @MainActor in
            shared.persistToFile(message: msg, category: category, level: .fatal, context: nil, sync: true)
        }
    }
}